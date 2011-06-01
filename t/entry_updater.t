#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 229;
#use Test::More 'no_plan';
use Test::More::UTF8;
use Test::NoWarnings;
use Test::MockModule;
use Test::MockTime;
use Test::MockObject::Extends;
use HTTP::Status qw(HTTP_NOT_MODIFIED HTTP_INTERNAL_SERVER_ERROR);
use LWP::Protocol::file; # Turn on local fetches.
use Test::Output;
use File::Path;

BEGIN {
    use_ok 'App::FeedScene::DBA' or die;
    use_ok 'App::FeedScene::EntryUpdater' or die;
}

END { File::Path::remove_tree 'cache/foo' };

# Set an absolute time.
my $time = '2010-06-05T17:29:41Z';
Test::MockTime::set_fixed_time($time);

my $uri = 'file://localhost' . File::Spec->rel2abs('t/data');

*_uuid = \&App::FeedScene::EntryUpdater::_uuid;

# Build a database for us to use.
ok my $dba = App::FeedScene::DBA->new( app => 'foo' ),
    'Create a DBA object';
ok $dba->upgrade, 'Initialize and upgrade the database';
END {
    App::FeedScene->new->conn->disconnect;
    $dba->drop;
}
my $conn = App::FeedScene->new->conn;

# Load some feed data.
$conn->txn(sub {
    my $sth = shift->prepare(q{
        INSERT INTO feeds (portal, id, title, url, updated_at)
        VALUES(?, ?, ?, ?, ?)
    });
    for my $spec (
        [ 0, 'simple.atom',         'Simple Atom Feed'     ],
        [ 0, 'simple.rss',          'Simple RSS Feed'      ],
        [ 0, 'summaries.rss',       'Summaries RSS Feed'   ],
        [ 0, 'latin-1.atom',        'Latin-1 Atom “Feed”'  ],
        [ 0, 'latin-1.rss',         'Latin-1 RSS Feed'     ],
        [ 0, 'dates.rss',           'Simple RSS Dates'     ],
        [ 0, 'conflict.rss',        'Simple RSS Feed'      ],
        [ 0, 'entities.rss',        'Whatever Blog'        ],
        [ 0, 'bogus.rss',           'Broken Encoding'      ],
        [ 1, 'enclosures.atom',     'Enclosures Atom Feed' ],
        [ 1, 'enclosures.rss',      'Enclosures RSS Feed'  ],
        [ 1, 'more_summaries.atom', 'More Summaries Feed'  ],
        [ 1, 'nerbles.rss',         'Yahoo Pipes Feed'     ],
    ) {
        $sth->execute(
            @{ $spec },
            URI->new("$uri/$spec->[1]")->canonical,
            '2010-06-08T14:13:38'
        );
    }
});

is $conn->run(sub {
    (shift->selectrow_array('SELECT COUNT(*) FROM feeds'))[0]
}), 13, 'Should have 13 feeds in the database';
test_counts(0, 'Should have no entries');

# Construct a entry updater.
ok my $eup = App::FeedScene::EntryUpdater->new(
    app    => 'foo',
    portal => 0,
), 'Create a EntryUpdater object';

isa_ok $eup, 'App::FeedScene::EntryUpdater', 'It';
is $eup->app, 'foo', 'The app attribute should be set';

$eup = Test::MockObject::Extends->new( $eup );

my @urls = map { URI->new($_)->canonical } (
    "$uri/simple.atom",
    "$uri/simple.rss",
    "$uri/summaries.rss",
    "$uri/latin-1.atom",
    "$uri/latin-1.rss",
    "$uri/dates.rss",
    "$uri/conflict.rss",
    "$uri/entities.rss",
    "$uri/bogus.rss",
);

$eup->mock(process => sub {
    my ($self, $url) = @_;
    ok +(grep { $_ eq $url } @urls), 'Should have feed URL $url';
});

ok $eup->run, 'Run the update again -- should have feeds in previous two tests';
$eup->unmock('process');

##############################################################################
# Test request failure.
my $res_mock = Test::MockModule->new('HTTP::Response');
$res_mock->mock( is_success => 0 );
$res_mock->mock( code => HTTP_INTERNAL_SERVER_ERROR );
$res_mock->mock( message => 'OMGWTF' );
test_fails(0, "$uri/simple.atom", 'Should start with no failures');
ok $eup->process("$uri/simple.atom"), 'Process a feed';
test_counts(0, 'Should still have no entries');
test_fails(1, "$uri/simple.atom", 'Should have a fail count of one');

# Go again.
ok $eup->process("$uri/simple.atom"), 'Process a feed again';
test_counts(0, 'Should still have no entries');
test_fails(2, "$uri/simple.atom", 'Should now have fail count two');

# Test non-XML.
my $parser_mock = Test::MockModule->new('App::FeedScene::Parser');
$parser_mock->mock('isa_feed' => 0);
$res_mock->unmock('code');
$res_mock->unmock('is_success');
ok $eup->process("$uri/simple.atom"), 'Process a non-feed';
test_counts(0, 'Should still have no entries');
test_fails(3, "$uri/simple.atom", 'Should now have fail count three');
$parser_mock->unmock_all;

# Test HTTP_NOT_MODIFIED.
$res_mock->mock( is_success => 0 );
$res_mock->mock( code => HTTP_NOT_MODIFIED );
ok $eup->process("$uri/simple.atom"), 'Process an unmodified feed';
test_counts(0, 'Should still have no entries');
test_fails(0, "$uri/simple.atom", 'fail count should be back to 0');

# Let's trigger a warning.
my $threshold =
    App::FeedScene::EntryUpdater::ERR_THRESHOLD < App::FeedScene::EntryUpdater::ERR_INTERVAL
    ? App::FeedScene::EntryUpdater::ERR_INTERVAL
    : App::FeedScene::EntryUpdater::ERR_THRESHOLD + App::FeedScene::EntryUpdater::ERR_INTERVAL;

my $feed = URI->new("$uri/simple.atom")->canonical;
$res_mock->mock( code => HTTP_INTERNAL_SERVER_ERROR );
$conn->run(sub {
    $_->do(
        'UPDATE feeds SET fail_count = ? WHERE url = ?',
        undef, $threshold - 1, $feed
    );
});
stderr_like { $eup->process("$uri/simple.atom") }
    qr{Error #$threshold retrieving \Q$feed\E -- 000 Unknown code},
    'Should get exception request failure';
test_fails($threshold, $feed, 'fail count should be at threshold');
stderr_is { $eup->process($feed) }
    '', 'But should get nothing on the next request failure';
test_fails($threshold + 1, $feed, 'fail count should be incremented');

# Test success.
$res_mock->unmock_all;

##############################################################################
# Okay, now let's test the processing.
ok $eup->process("$uri/simple.atom"), 'Process simple Atom feed';
test_counts(3, 'Should now have three entries');
test_fails(0, $feed, 'fail count should be back to 0');

# Check the feed data.
is_deeply $conn->run(sub{ shift->selectrow_arrayref(
    'SELECT title, subtitle, site_url, icon_url, updated_at, rights
       FROM feeds WHERE url = ?',
    undef, $feed,
)}), [
    'Simple Atom Feed',
    'Witty & clever',
    'http://example.com/',
    'http://getfavicon.appspot.com/http://example.com/?defaulticon=none',
    '2009-12-13 18:30:02+00',
    '© 2010 Big Fat Example',
], 'Atom feed should be updated';

# Check the entry data.
is_deeply test_data('urn:uuid:e287d28b-5a4b-575c-b9da-d3dc894b9aa2'), {
    id             => 'urn:uuid:e287d28b-5a4b-575c-b9da-d3dc894b9aa2',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
    url            => 'http://example.com/story.html',
    via_url        => '',
    title          => 'This is the title',
    published_at   => '2009-12-13 12:29:29+00',
    updated_at     => '2009-12-13 18:30:02+00',
    summary        => 'Summary of the story',
    author         => 'Ira Glass',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for first entry should be correct';

is_deeply test_data('urn:uuid:82e57dc3-0fdf-5a44-be61-7dfaeaa842ad'), {
    id             => 'urn:uuid:82e57dc3-0fdf-5a44-be61-7dfaeaa842ad',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
    url            => 'http://example.com/1234',
    via_url        => 'http://example.com/another-story.html',
    title          => 'This is another title™',
    published_at   => '2009-12-12 12:29:29+00',
    updated_at     => '2009-12-13 18:30:03+00',
    summary        => 'Summary of the second story',
    author         => '',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for second entry should be correct';

is_deeply test_data('urn:uuid:0df1d4a7-6b9f-532c-9a94-52cafade78a2'), {
    id             => 'urn:uuid:0df1d4a7-6b9f-532c-9a94-52cafade78a2',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
    url            => 'http://example.com/story-three.html',
    via_url        => '',
    title          => 'Title Three',
    published_at   => '2009-12-11 12:29:29+00',
    updated_at     => '2009-12-13 18:30:03+00',
    summary        => 'Summary of the third story',
    author         => '',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for second entry should be correct';

##############################################################################
# Run it again, with updates.
ok $eup->process("$uri/simple-updated.atom"), 'Process updated simple Atom feed';
test_counts(3, 'Should still have three entries');

is_deeply test_data('urn:uuid:e287d28b-5a4b-575c-b9da-d3dc894b9aa2'), {
    id             => 'urn:uuid:e287d28b-5a4b-575c-b9da-d3dc894b9aa2',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
    url            => 'http://example.com/story.html',
    via_url        => '',
    title          => 'This is the new title',
    published_at   => '2009-12-13 12:29:29+00',
    updated_at     => '2009-12-14 18:30:02+00',
    summary        => 'Summary of the story',
    author         => 'Ira Glass',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'First entry should be updated';

is_deeply test_data('urn:uuid:4386a769-775f-5b78-a6f0-02e3ac8a457d'), {
    id             => 'urn:uuid:4386a769-775f-5b78-a6f0-02e3ac8a457d',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
    url            => 'http://example.com/another-story.html',
    via_url        => '',
    title          => 'Updated without updated element',
    published_at   => '2009-12-12 12:29:29+00',
    updated_at     => '2009-12-12 12:29:29+00',
    summary        => 'Summary of the second story',
    author         => '',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Second entry, with no updated element, should be updated';

is_deeply test_data('urn:uuid:0df1d4a7-6b9f-532c-9a94-52cafade78a2'), {
    id             => 'urn:uuid:0df1d4a7-6b9f-532c-9a94-52cafade78a2',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
    url            => 'http://example.com/story-three.html',
    via_url        => '',
    title          => 'Title Three',
    published_at   => '2009-12-11 12:29:29+00',
    updated_at     => '2009-12-13 18:30:03+00',
    summary        => 'Summary of the third story',
    author         => '',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Third entry should not be updated, because updated element not updated';

##############################################################################
# Let's try a simple RSS feed.
ok $eup->process("$uri/simple.rss"), 'Process simple RSS feed';
test_counts(5, 'Should now have five entries');

# Check the feed data.
$feed = URI->new("$uri/simple.rss")->canonical;
is_deeply $conn->run(sub{ shift->selectrow_arrayref(
    'SELECT title, site_url FROM feeds WHERE url = ?',
    undef, $feed
)}), ['Simple RSS Feed', 'http://example.net/f%C3%B8%C3%B8'], 'RSS feed should be updated';

# Check the entry data.
is_deeply test_data('urn:uuid:3577008b-ee22-5b79-9ca9-ac87e42ee601'), {
    id             => 'urn:uuid:3577008b-ee22-5b79-9ca9-ac87e42ee601',
    feed_id        => $feed,
    url            => 'http://example.net/2010/05/17/long-goodbye/',
    via_url        => '',
    title          => 'The Long Goodbye',
    published_at   => '2010-05-17 14:58:50+00',
    updated_at     => '2010-05-17 14:58:50+00',
    summary        => 'Wherein Marlowe finds himeslf in trouble again.',
    author         => 'Raymond Chandler & Friends',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for first RSS entry, including unformatted summary';

is_deeply test_data('urn:uuid:5e125dfa-0b69-504c-96a0-83f552645c6b'), {
    id             => 'urn:uuid:5e125dfa-0b69-504c-96a0-83f552645c6b',
    feed_id        => $feed,
    url            => 'http://example.net/2010/05/16/little-sister/',
    via_url        => '',
    title          => '',
    published_at   => '2010-05-16 14:58:50+00',
    updated_at     => '2010-05-16 14:58:50+00',
    summary        => 'Hollywood babes. A killer with an ice pick. What could be better?',
    author         => 'Raymond Chandler & Friends',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for second RSS entry with no title and summary extracted from content';

##############################################################################
# Test a non-utf8 Atom feed.
ok $eup->process("$uri/latin-1.atom"), 'Process Latin-2 Atom feed';
test_counts(7, 'Should now have seven entries');

# Check that the title was converted to UTF-8.
$feed = URI->new("$uri/latin-1.atom")->canonical;
is $conn->run(sub{ shift->selectrow_array(
    'SELECT title FROM feeds WHERE url = ?',
    undef, $feed,
)}), 'Latin-1 Atom “Feed”', 'Atom Feed title CP1252 Entities should be UTF-8';

my ($title, $summary) = $conn->dbh->selectrow_array(
    'SELECT title, summary FROM entries WHERE id = ?',
    undef, 'urn:uuid:acda412e-967c-572c-a175-89441b378638'
);

is $title, 'Title: æåø', 'Latin-1 Title should be UTF-8';
is $summary, 'Latin-1: æåø', 'Latin-1 Summary should be UTF-8';

($title, $summary) = $conn->dbh->selectrow_array(
    'SELECT title, summary FROM entries WHERE id = ?',
    undef, 'urn:uuid:3da0bf84-a718-5180-9b89-f244c079080a',
);

is $title, 'Blah blah—blah',
    'Latin-1 Title with CP1252 entity should be UTF-8';
is $summary, 'This description has nasty—dashes—.',
    'Latin-1 Summary with ampersand entitis escaping CP1252 entities should be UTF-8';

##############################################################################
# Test a non-utf8 RSS feed.
ok $eup->process("$uri/latin-1.rss"), 'Process Latin-1 RSS feed';
test_counts(9, 'Should now have nine entries');

# Check that the rights were converted to UTF-8.
$feed = URI->new("$uri/latin-1.rss")->canonical;
is $conn->run(sub{ shift->selectrow_array(
    'SELECT rights FROM feeds WHERE url = ?',
    undef, $feed,
)}), 'David “Theory” Wheeler', 'RSS Feed rights CP1252 Entities should be UTF-8';

($title, $summary) = $conn->dbh->selectrow_array(
    'SELECT title, summary FROM entries WHERE id = ?',
    undef, 'urn:uuid:6752bbb0-c0b6-5a4b-ac30-acc3cf427417'
);

is $title, 'Title: æåø', 'Latin-1 Title should be UTF-8';
is $summary, 'Latin-1: æåø (“CP1252”)', 'Latin-1 Summary should be UTF-8';

($title, $summary) = $conn->dbh->selectrow_array(
    'SELECT title, summary FROM entries WHERE id = ?',
    undef, 'urn:uuid:ef7ffbde-078b-5bbd-85eb-c697786180ed',
);

is $title, 'Blah blah—blah',
    'Latin-1 Title with CP1252 entity should be UTF-8';
is $summary, 'This description has nasty—dashes—.',
    'Latin-1 Summary with ampersand entitis escaping CP1252 entities should be UTF-8';

##############################################################################
# Test a variety of RSS summary formats and another icon.
$eup->icon('http://designsceneapp.com/favicon.ico');
ok $eup->process("$uri/summaries.rss"), 'Process RSS feed with various summaries';
test_counts(32, 'Should now have 32 entries');

# Check the feed data.
$feed = URI->new("$uri/summaries.rss")->canonical;
is_deeply $conn->run(sub{ shift->selectrow_arrayref(
    'SELECT title, subtitle, site_url, icon_url, updated_at, rights
       FROM feeds WHERE url = ?',
    undef, $feed
)}), [
    'Summaries RSS Feed',
    '',
    'http://foo.org/',
    'http://getfavicon.appspot.com/http://foo.org/?defaulticon=http://designsceneapp.com/favicon.ico',
    '2010-06-05 17:29:41+00',
    '',
], 'Summaries feed should be updated including current updated time';

my $dbh = $conn->dbh;
for my $spec (
    [ 1  => 'Simple summary in plain text.'],
    [ 2  => 'Simple summary in a paragraph.'],
    [ 3  => 'Paragraph summary with emphasis.' ],
    [ 4  => 'Paragraph summary with anchor.'],
    [ 5  => 'First graph. Second graph.'],
    [ 6  => 'First graph. Second graph. Third graph with a lot more stuff in it, to get us over 140 characters, if you know what I mean. And I think you do.'],
    [ 7  => 'Paragraph summary with em+attr.' ],
    [ 8  => 'The WHO was founded in 1948.'],
    [ 9  => 'Paragraph summary with anchor and child element.'],
    [ 10 => 'Paragraph summary with font.' ],
    [ 11 => 'Simple summary in plain text with emphasis.'],
    [ 12 => 'Simple summary in plain text with separate content.'],
    [ 13 => 'First graph. Second graph. Third graph with a lot more stuff in it, to get us over 140 characters, if you know what I mean. Fourth graph should be included.'],
    [ 14 => 'Summary with emphasis complementing content.' ],
    [ 15 => 'Summary with emphasis in anchor.' ],
    [ 16 => 'Summary with leading img.' ],
    [ 17 => 'Summary with trailing img.' ],
    [ 18 => 'Centered Summary paragraph' ],
    [ 19 => 'Centered Summary' ],
    [ 20 => 'Summary with no tag but a link.' ],
    [ 21 => 'Summary in the description when we also have encoded content.' ],
    [ 22 => 'Stuff inside a blockquote.' ],
    [ 23 => 'Need a summary over 400 characters long. Lorem ipsum dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat…' ],
) {
    is +($dbh->selectrow_array(
        'SELECT summary FROM entries WHERE id = ?',
        undef, _uuid('http://foo.org/', "http://foo.org/lg$spec->[0]")
    ))[0], $spec->[1], "Should have proper summary for entry $spec->[0]";
}

##############################################################################
# Try a bunch of different date combinations.
ok $eup->process("$uri/dates.rss"), 'Process RSS feed with various dates';
test_counts(38, 'Should now have 38 entries');

for my $spec (
    [ 1 => ['2010-05-17 06:58:50+00', '2010-05-17 07:45:09+00'], 'both dates' ],
    [ 2 => ['2010-05-17 06:58:50+00', '2010-05-17 06:58:50+00'], 'published only date' ],
    [ 3 => ['2010-05-17 07:45:09+00', '2010-05-17 07:45:09+00'], 'modified only date' ],
    [ 4 => ['2010-05-17 00:00:00+00', '2010-05-17 00:00:00+00'], 'floating pubDate' ],
    [ 5 => ['2010-05-17 14:58:50+00', '2010-05-17 14:58:50+00'], 'offset date'],
    [ 6 => ['2010-05-17 11:58:50+00', '2010-05-17 11:58:50+00'], 'zoned date'],
) {
    is_deeply $dbh->selectrow_arrayref(
        'SELECT published_at, updated_at FROM entries WHERE id = ?',
        undef,
        _uuid('http://baz.org/', "http://baz.org/lg$spec->[0]")
    ), $spec->[1], "Should have $spec->[2]";
}

##############################################################################
# Try a feed with a duplicate URI and no GUID.
ok $eup->process("$uri/conflict.rss"), 'Process RSS feed with a duplicate link';
test_counts(39, 'Should now have 39 entries');

# So now we should have two records with the same URL but different IDs.
is_deeply $dbh->selectall_arrayref(
    'SELECT id, feed_id FROM entries WHERE url = ? ORDER BY id',
    undef, 'http://example.net/2010/05/17/long-goodbye/'
), [
    [
        'urn:uuid:3577008b-ee22-5b79-9ca9-ac87e42ee601',
        URI->new("$uri/simple.rss")->canonical,
    ],
    [
        'urn:uuid:7ff1dcfc-42cb-52d8-aaf5-759103cc8f8c',
        URI->new("$uri/conflict.rss")->canonical,
    ]
], 'Should have two rows with the same link but different IDs and feed URLs';

##############################################################################
# Try a feed with enclosures.
# Mock enclosure audit. Will unmock and test below.
$eup->mock(_audit_enclosure => sub {
    my ($self, $url, $type) = @_;
    pass "_audit_enclosures($url)";
    return { type => $type, url => $url };
});

# Mock size check. Will unmock and test below.
$eup->mock(_check_size => sub {
    my ($self, $enc) = @_;
    pass "_check_size($enc->{url})";
    return $enc;
});

my $ua_mock = Test::MockModule->new('App::FeedScene::UA');
my %type_for = (
    unwanted          => 'text/html',
    unwantedembed     => 'text/html',
    redirimage        => 'image/jpeg',
    audiodupe         => 'text/html',
    embeddedimagedupe => 'text/html',
);

$ua_mock->mock(head => sub {
    my ($self, $url) = @_;
    (my $key = $url) =~ s{http://[^/]+/}{};
    die "No mocked data type for $url" unless $type_for{$key};

    my $r = HTTP::Response->new(200, 'OK', ['Content-Type' => $type_for{$key}]);
    (my $u = $url) =~ s{redirimage$}{realimage.jpg} if $key eq 'redirimage';
    $r->request( HTTP::Request->new(GET => $u) );
    return $r;
});

$eup->portal(1);
$eup->icon('none');
ok $eup->process("$uri/enclosures.atom"), 'Process Atom feed with enclosures';
test_counts(52, 'Should now have 52 entries');

# Check the feed data.
is_deeply $conn->run(sub{ shift->selectrow_arrayref(
    'SELECT title, subtitle, site_url, icon_url, rights FROM feeds WHERE url = ?',
    undef, URI->new("$uri/enclosures.atom")->canonical,
)}), [
    'Enclosures Atom Feed',
    '',
    'http://example.com/',
    'http://getfavicon.appspot.com/http://example.com/?defaulticon=none',
    '',
], 'Feed record should be updated';

# Disable the `pass` in _audit_enclosures now that we're sure it gets called.
$eup->mock(_audit_enclosure => sub {
    my ($self, $url, $type) = @_;
    return { type => $type, url => $url };
});

ok $eup->process("$uri/enclosures.rss"), 'Process RSS feed with enclosures';
test_counts(65, 'Should now have 65 entries');

# First one is easy, has only one enclosure.
is_deeply test_data('urn:uuid:257c8075-dc7c-5678-8de0-5bb88360dff6'), {
    author         => '',
    enclosure_type => 'image/jpeg',
    enclosure_url  => 'http://farm2.static.flickr.com/1169/4601733070_92cd987ff5_%C3%AE.jpg',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af7',
    id             => 'urn:uuid:257c8075-dc7c-5678-8de0-5bb88360dff6',
    published_at   => '2009-12-13 08:29:29+00',
    summary        => 'Caption for the encosed image.',
    title          => 'This is the title',
    updated_at     => '2009-12-13 08:29:29+00',
    url            => 'http://flickr.com/some%C3%AEmage',
    via_url        => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for first entry with enclosure should be correct';

is_deeply test_data('urn:uuid:844df0ef-fed0-54f0-ac7d-2470fa7e9a9c'), {
    author         => '',
    enclosure_type => 'image/jpeg',
    enclosure_url  => 'http://farm2.static.flickr.com/1169/4601733070_92cd987ff6_o.jpg',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af7',
    id             => 'urn:uuid:844df0ef-fed0-54f0-ac7d-2470fa7e9a9c',
    published_at   => '2009-12-12 08:19:29+00',
    summary        => 'Caption for both of the the encosed images.',
    title          => 'This is the title',
    updated_at     => '2009-12-12 08:19:29+00',
    url            => 'http://flickr.com/twoimages',
    via_url        => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for entry with two should have just the first enclosure';

# Look at the RSS versions, too.
$feed = URI->new("$uri/enclosures.rss")->canonical;
is_deeply test_data('urn:uuid:db9bd827-0d7f-5067-ad18-2c666ab1a028'), {
    author         => '',
    enclosure_type => 'image/jpeg',
    enclosure_url  => 'http://farm2.static.flickr.org/1169/4601733070_92cd987ff5_%C3%AE.jpg',
    feed_id        => $feed,
    id             => 'urn:uuid:db9bd827-0d7f-5067-ad18-2c666ab1a028',
    published_at   => '2009-12-13 08:29:29+00',
    summary        => 'Caption for the encosed image.',
    title          => 'This is the title',
    updated_at     => '2009-12-13 08:29:29+00',
    url            => 'http://flickr.org/some%C3%AEmage',
    via_url        => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for first entry with enclosure should be correct';

is_deeply test_data('urn:uuid:4aef01ff-75c3-5dcb-a53f-878e3042f3cf'), {
    author         => '',
    enclosure_type => 'image/jpeg',
    enclosure_url  => 'http://farm2.static.flickr.org/1169/4601733070_92cd987ff6_o.jpg',
    feed_id        => $feed,
    id             => 'urn:uuid:4aef01ff-75c3-5dcb-a53f-878e3042f3cf',
    published_at   => '2009-12-12 08:19:29+00',
    summary        => 'Caption for both of the the encosed images.',
    title          => 'This is the title',
    updated_at     => '2009-12-12 08:19:29+00',
    url            => 'http://flickr.org/twoimages',
    via_url        => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for entry with two should have just the first enclosure';

# Process it again.
ok $eup->process("$uri/enclosures.rss"), 'Process RSS feed with enclosures again';
test_counts(65, 'Should still have 65 entries');

is_deeply test_data('urn:uuid:257c8075-dc7c-5678-8de0-5bb88360dff6'), {
    author         => '',
    enclosure_type => 'image/jpeg',
    enclosure_url  => 'http://farm2.static.flickr.com/1169/4601733070_92cd987ff5_%C3%AE.jpg',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af7',
    id             => 'urn:uuid:257c8075-dc7c-5678-8de0-5bb88360dff6',
    published_at   => '2009-12-13 08:29:29+00',
    summary        => 'Caption for the encosed image.',
    title          => 'This is the title',
    updated_at     => '2009-12-13 08:29:29+00',
    url            => 'http://flickr.com/some%C3%AEmage',
    via_url        => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Should have same data for first enclosure';

# Now check for various enclosure configurations in both Atom and RSS.
for my $spec (
    [ 'embeddedimage' => [
        'Caption for the embedded image.',
        'image/jpeg',
        'http://flickr.com/someimage.jpg'
    ], 'embedded JPEG' ],
    [ 'embedtwo' => [
        'Caption for both of the embedded images.',
        'image/jpeg',
        'http://flickr.com/some%C3%AEmage.jpg'
    ], 'two embedded JPEGs' ],
    [ 'audio' => [
        'Caption for the enclosed audio.',
        'audio/mpeg',
        'http://flickr.com/audio.mp3'
    ], 'audio enclosure' ],
    [ 'video' => [
        'Caption for the enclosed video.',
        'video/mpeg',
        'http://flickr.com/video.mov'
    ], 'video enclosure' ],
    [ 'embedaudio' => [
        'Caption for the embedded audio.',
        'audio/mpeg',
        'http://flickr.com/anotheraudio.mp3'
    ], 'embedded audio' ],
    [ 'embedvideo' => [
        'Caption for the embedded video.',
        'video/quicktime',
        'http://flickr.com/anothervideo.mov'
    ], 'embedded video' ],
    [ 'skipunwanted' => [
        'Caption for the enclosed audio.',
        'audio/mpeg',
        'http://flickr.com/audio2.mp3'
    ], 'unwanted enclosure + audio enclosure' ],
    [ 'skipembed' => [
        'Caption for the embedded audio.',
        'audio/mpeg',
        'http://flickr.com/audio3.mp3'
    ], 'unwanted embed + embedded audio' ],
    [ 'audio4.mp3' => [
        'Caption for the audio link.',
        'audio/mpeg',
        'http://flickr.com/audio4.mp3'
    ], 'direct link' ],
    [ 'redirimage' => [
        'Caption for the image link.',
        'image/jpeg',
        'http://flickr.com/realimage.jpg'
    ], 'redirected link' ],
    [ 'doubleclick' => [
        'Caption for the embedded image.',
        'image/jpeg',
        'http://flickr.com/someimage2.jpg'
    ], 'unwanted doubleclick image + actual image' ],
) {
    is_deeply $dbh->selectrow_arrayref(
        'SELECT summary, enclosure_type, enclosure_url FROM entries WHERE id = ?',
        undef, _uuid('http://example.com/', "http://flickr.com/$spec->[0]")
    ) || ['no row'], $spec->[1], "Should have proper Atom enclosure for $spec->[2]";

    $spec->[1][2] =~ s{[.]com}{.org};

    is_deeply $dbh->selectrow_arrayref(
        'SELECT summary, enclosure_type, enclosure_url FROM entries WHERE id = ?',
        undef, _uuid('http://example.org/', "http://flickr.org/$spec->[0]")
    ) || ['no row'], $spec->[1], "Should have proper RSS enclosure for $spec->[2]";
}

##############################################################################
# Summary regressions.
ok $eup->process("$uri/more_summaries.atom"), 'Process Summary regressions';
test_counts(68, 'Should now have 68 entries');

for my $spec (
    [ 'onclick' => [
        'Index Sans was conceived as a text face, so a large x-height was combined with elliptical curves to open the counterforms and improve legibility at smaller sizes. Stroke endings utilize a subtle radius at each corner; a reference to striking a steel punch into a soft metal surface. Index Sans Typeface on the Behance Network',
        'image/jpeg',
        'http://behance.vo.llnwd.net/profiles2/146457/projects/441024/1464571267585065.jpg',
    ], 'onclick summary' ],
    [ 'broken' => [
        'first graph second graph man',
        'image/jpeg',
        'http://foo.com/hey.jpg',
    ], 'broken html' ],
    [ 'hrm' => [
        q{Jeff Koons has just unveiled the newest model in BMW's Art Car series. His vibrant design is one of the best in the series, which began in 1975. I mean, don't you totally want to grab this car and drive ridiculously fast on one of those mythical German roads with no speed limit? Of course you do! (thanks Peter )},
        'image/jpeg',
        'http://ideas.veer.com/images/assets/posts/0012/0871/Koons_Car.jpg',
    ], 'no summary hrm' ],
) {
    is_deeply $dbh->selectrow_arrayref(
        'SELECT summary, enclosure_type, enclosure_url FROM entries WHERE id = ?',
        undef, _uuid('http://more.example.com/', "http://more.example.com/$spec->[0].html")
    ) || [], $spec->[1], "Should have proper enclosure & summary for $spec->[2]";
}

##############################################################################
$eup->portal(0);
ok $eup->process("$uri/entities.rss"), 'Process CP1252 RSS feed with entities';
test_counts(72, 'Should now have 72 entries');

for my $spec (
    [ 4034, 'A space: Nice, eh?', 'nbsp' ],
    [ 8536, 'We don’t ever stop.', 'rsquo' ],
    [ 4179, 'Jakob Trollbäck explains why.', 'auml' ],
    [ 3851, 'Start thinking "out of the lightbox"—and win!', 'quot and mdash' ],
) {
    is $dbh->selectrow_arrayref(
        'SELECT summary FROM entries WHERE id = ?',
        undef,
        _uuid('http://www.foobar.com/rss.aspx', "http://www.foobar.com/article/$spec->[0]")
    )->[0], $spec->[1], "CP1252 summary should be correct with $spec->[2]";
}

##############################################################################
# Test Yahoo! Pipes feed with nerbles in it.
$eup->portal(1);
ok $eup->process("$uri/nerbles.rss"), 'Process Yahoo! Pipes nerbles feed';
test_counts(73, 'Should now have 73 entries');

is $dbh->selectrow_arrayref(
    'SELECT summary FROM entries WHERE id = ?',
    undef,
    _uuid('http://pipes.yahoo.com/pipes22', 'http://flickr.com@n22/')
)->[0], "Tomas Laurinavi\x{c4}\x{8d}ius has added a photo to the pool:",
    'Nerbles should be valid UTF-8 in summary';

##############################################################################
# Test Feed with invalid bytes in it.
$eup->portal(0);
ok $eup->process("$uri/bogus.rss"), 'Process RSS with bogus bytes';
test_counts(74, 'Should now have 74 entries');

is $dbh->selectrow_arrayref(
    'SELECT title FROM entries WHERE id = ?',
    undef,
    _uuid('http://welie.example.com/', 'http://welie.example.com/broken')
)->[0], "'\x{c3}\x{160}?\x{e2}\x{2c6}\x{2020}\x{c3}\x{bb}\x{e2}\x{2030}\x{a4}FWt+\x{c3}\x{ae}\$\x{c4}\x{b1}\x{c3}\x{17d}\x{c3}\x{bc}j\x{c3}\x{20ac}\x{ef}\x{ac},\x{c3}\x{160}9.v\x{c2}\x{ae}\x{c3}\x{8f}G\x{c2}\x{a8}\x{e2}\x{2030}\x{a0}\x{e2}\x{20ac}\x{153}\x{c2}\x{a9}",
    'Bogus characters should be removed from title';

is $dbh->selectrow_arrayref(
    'SELECT summary FROM entries WHERE id = ?',
    undef,
    _uuid('http://welie.example.com/', 'http://welie.example.com/broken')
)->[0], "\x{c3}\x{ad}Z\x{e2}\x{2030}\x{a4}F1\x{e2}\x{20ac}\x{201c}\x{c3}\x{2122}?Z\x{e2}\x{2c6},",
    'Bogus characters should be removed from summary';

##############################################################################
# Test gzip encoding.
$conn->txn(sub {
    my $sth = shift->do(
        'UPDATE feeds SET url = ? WHERE title = ?',
        undef,
        "$uri/simple.atom.gz", 'Simple Atom Feed'
    );
});

$res_mock->mock( content_is_xml => 1);
ok $eup->process("$uri/simple.atom.gz"), "Process gzip'ed simple atom feed";
$res_mock->unmock('content_is_xml');
is_deeply test_data('urn:uuid:82e57dc3-0fdf-5a44-be61-7dfaeaa842ad'), {
    id             => 'urn:uuid:82e57dc3-0fdf-5a44-be61-7dfaeaa842ad',
    feed_id        => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
    url            => 'http://example.com/1234',
    via_url        => 'http://example.com/another-story.html',
    title          => 'This is yet another title™',
    published_at   => '2009-12-12 12:29:29+00',
    updated_at     => '2009-12-13 18:30:03+00',
    summary        => 'Summary of the second story',
    author         => '',
    enclosure_url  => undef,
    enclosure_type => '',
    enclosure_id   => undef,
    enclosure_user => undef,
    enclosure_hash => undef,
}, 'Data for second entry should be updated';

##############################################################################
# Test enclosure auditing.
$eup->unmock('_audit_enclosure');

# Start with non-Flickr URL.
$uri = URI->new('http://example.com/hey/you/it.jpg');
my $type = 'image/jpeg';
is_deeply $eup->_audit_enclosure($uri, $type), { type => $type, url => $uri },
    'Non-Flickr URI should not be audited';

# Try Flickr static URL without photo ID.
$uri = URI->new('http://farm3.static.flickr.com/hey/you/it.jpg');
is_deeply $eup->_audit_enclosure($uri, $type), { type => $type, url => $uri },
    'Flickr URL without photo ID should not be audited';

# Need to mock UA response.
$res_mock->mock( code => HTTP_INTERNAL_SERVER_ERROR );
my $xml;
$ua_mock->mock( get => sub {
    my ($self, $url) = @_;
    my $r = HTTP::Response->new(200, 'OK', ['Content-Type' => $type]);
    return $r;
});

# Try URL with photo ID but let the response fail.
$res_mock->mock( is_success => 0 );
$uri = URI->new('http://farm2.static.flickr.com/1282/4661840263_019e867a6e_m.jpg');
is $eup->_audit_enclosure($uri, $type), undef,
    'Audit should return undef on request failure';

# Let the request be successful.
$res_mock->mock(is_success => 1);
my @size_xml = do {
    my $fn = 't/data/flickr-sizes.xml';
    open my $fh, '<', $fn or die "Cannot open $fn: $!\n";
    <$fh>;
};
my @info_xml = do {
    my $fn = 't/data/flickr-info.xml';
    open my $fh, '<', $fn or die "Cannot open $fn: $!\n";
    <$fh>;
};
my @fav_xml = do {
    my $fn = 't/data/flickr-favorites.xml';
    open my $fh, '<', $fn or die "Cannot open $fn: $!\n";
    <$fh>;
};
my $i;
$res_mock->mock(content => sub {
    ++$i;
    join '', $i == 1 ? @info_xml
           : $i == 2 ? @fav_xml
                     : @size_xml;
});
$eup->in_pool(1);

# Make sure we get the large image.
$i = 0;
is_deeply $eup->_audit_enclosure($uri, $type), {
    type   => $type,
    url    => URI->new('http://farm2.static.flickr.com/1282/4661840263_019e867a6e_b.jpg'),
    id     => 'flickr:4661840263',
    user   => 'flickr:72575281@N00',
    desc   => 'The hammer is animated. To tacky. So hilarious. So cool.',
    width  => 1024,
    height => 681,
}, 'Should find the large image';

# Should get undef if the image with that ID is already in the cached IDs.
$eup->eids({  'flickr:4661840263' => 1 });
$i = 0;
is $eup->_audit_enclosure($uri, $type), undef,
    'Should get undef because the image is already in the cache';

# Should get undef if the user is already in the cache.
$eup->eids({ });
$eup->eusers({ 'flickr:72575281@N00' => 1 });
$i = 0;
is $eup->_audit_enclosure($uri, $type), undef,
    'Should get undef because the username is already in the cache';

# Should get undef if the image with that ID is already in the database.
$eup->eusers({ });
$conn->run(sub { shift->do(
    'UPDATE entries SET enclosure_id = ? WHERE id = ?',
    undef,  'flickr:4661840263', 'urn:uuid:257c8075-dc7c-5678-8de0-5bb88360dff6',
)});
$i = 0;
is $eup->_audit_enclosure($uri, $type), undef,
    'Should get undef because the image is already in the database';

# Should get undef if the image with that user ID is already in the database.
$i = 0;
$conn->run(sub { shift->do(
    'UPDATE entries SET enclosure_id = ?, enclosure_user = ? WHERE id = ?',
    undef,  'flickr:whatever', 'flickr:72575281@N00',
    'urn:uuid:257c8075-dc7c-5678-8de0-5bb88360dff6',
)});
$i = 0;
is $eup->_audit_enclosure($uri, $type), undef,
    'Should get undef because the user is already in the database';

# Try for the medium image when there is no large image.
@size_xml = grep { $_ !~ /label="Large"/ } @size_xml;
$conn->run(sub {
    shift->do(
        'DELETE FROM entries WHERE id = ?',
        undef, 'urn:uuid:257c8075-dc7c-5678-8de0-5bb88360dff6');
});
$i = 0;
is_deeply $eup->_audit_enclosure($uri, $type), {
    type   => $type,
    url    => URI->new('http://farm2.static.flickr.com/1282/4661840263_019e867a6e.jpg'),
    id     => 'flickr:4661840263',
    user   => 'flickr:72575281@N00',
    desc   => 'The hammer is animated. To tacky. So hilarious. So cool.',
    width  => 500,
    height => 333,
}, 'Should find the medium image';

# Try for the original image when there is no medium.
@size_xml = grep { $_ !~ /label="Medium"/ } @size_xml;
$conn->run(sub { shift->do(
    'DELETE FROM entries WHERE enclosure_id = ?',
    undef, 'flickr:4661840263')
});
$i = 0;
is_deeply $eup->_audit_enclosure($uri, $type), {
    type   => $type,
    url    => URI->new('http://farm2.static.flickr.com/1282/4661840263_e146f57fd2_o.jpg'),
    id     => 'flickr:4661840263',
    user   => 'flickr:72575281@N00',
    desc   => 'The hammer is animated. To tacky. So hilarious. So cool.',
    width  => 1024,
    height => 681,
}, 'Should find the original image';

# Try for the passed-in URL when there is no original.
@size_xml = grep { $_ !~ /label="Original"/ } @size_xml;
$i = 0;
is_deeply $eup->_audit_enclosure($uri, $type), {
    type => $type,
    url  => $uri,
    id   => 'flickr:4661840263',
    user => 'flickr:72575281@N00',
    desc => 'The hammer is animated. To tacky. So hilarious. So cool.',
}, 'Should get the passed URI when nothing found in XML';

# Now try when there is no favorite.
@fav_xml = grep { $_ !~ /person nsid/ } @fav_xml;
$conn->run(sub { shift->do(
    'DELETE FROM entries WHERE enclosure_id = ?',
    undef, 'flickr:4661840263')
});
$i = 0;
is $eup->_audit_enclosure($uri, $type), undef,
    'Should get undef because the image has not been favorited';

# But we shouldn't care if we're not in a pool.
$eup->in_pool(0);
$res_mock->mock(content => sub { join '', $i++ % 2 ? @size_xml : @info_xml });
$i = 0;
is_deeply $eup->_audit_enclosure($uri, $type), {
    type => $type,
    url  => $uri,
    id   => 'flickr:4661840263',
    user => 'flickr:72575281@N00',
    desc => 'The hammer is animated. To tacky. So hilarious. So cool.',
}, 'Should get a result when not in a pool';

# Make sure that process() properly sets in_pool.
$eup->mock(in_pool => sub {
    ok $_[1], 'process() should identify a Flickr pool';
    die 'Short-circuit';
});

$uri = URI->new('http://api.flickr.com/services/feeds/groups_pool.gne?id=1106345@N23&lang=en-us&format=rss_200');
eval { $eup->process($uri) };

# Make sure it identifies other stuff as not a pool.
$eup->mock(in_pool => sub {
    ok !$_[1], 'process() should identify a non-Flickr pool';
    die 'Short-circuit';
});

$uri = URI->new('http://www.flourish.org/news/flickr-daily-interesting-one.xml');
eval { $eup->process($uri) };
$eup->unmock('process');

##############################################################################
# Test size check.
$ua_mock->unmock_all;
$eup->unmock('_check_size');
$uri = 'file://localhost' . File::Spec->rel2abs('t/images');
my $enc = { type => 'image/png', url => "$uri/300x300.png"};
ok my $ret = $eup->_check_size({ %$enc }), '_check_size should like a 300px image';
$uri = 'file://' . File::Spec->rel2abs('t/images');
is $ret->{type}, 'image/png', '... The content type should be image/png';
is $ret->{url},  "$uri/300x300.png", '... And the URL should be canonical';

# Make sure it populates the type (and uses the cache).
$enc = { type => 'image/gif', url => "$uri/300x300.png"};
ok $ret = $eup->_check_size({ %$enc }), 'Get 300x300 image with wrong content type';
is $ret->{type}, 'image/png', '... The content type should now be image/png';
is $ret->{url},  "$uri/300x300.png", '... And the URL should be canonical';

# Make sure it doesn't like various too-small images.
for my $img (qw(dot_clear.gif share.gif line.jpeg)) {
    $enc->{url} = "$uri/$img";
    ok !$eup->_check_size($enc), "_check_size should reject $img";
}

# Make sure it ignores non-images.
ok $eup->_check_size({type => 'audio/mpeg' }),
    '_check_size should just return non-image type';

##############################################################################
sub test_counts {
    my ($count, $descr) = @_;
    is +App::FeedScene->new->conn->run(sub {
        (shift->selectrow_array('SELECT COUNT(*) FROM entries'))[0]
    }), $count, $descr;
}

sub test_data {
    my $id = shift;
    App::FeedScene->new->conn->run(sub {
        shift->selectrow_hashref(
            'SELECT * FROM entries WHERE id = ?',
            undef, $id
        );
    });
}

sub test_fails {
    my ($count, $url, $descr) = @_;
    is +App::FeedScene->new->conn->run(sub {
        (shift->selectrow_array(
            'SELECT fail_count FROM feeds WHERE url = ?',
            undef, URI->new($url)->canonical
        ))[0]
    }), $count, $descr;
}

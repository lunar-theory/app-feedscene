#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 96;
#use Test::More 'no_plan';
use Test::NoWarnings;
use Test::MockModule;
use Test::MockObject::Extends;
use HTTP::Status qw(HTTP_NOT_MODIFIED HTTP_INTERNAL_SERVER_ERROR);
use LWP::Protocol::file; # Turn on local fetches.
use Test::Exception;
use File::Path;

BEGIN {
    use_ok 'App::FeedScene::DBA' or die;
    use_ok 'App::FeedScene::EntryUpdater' or die;
}

END { File::Path::remove_tree 'cache/foo' };

my $uri = 'file://localhost' . File::Spec->rel2abs('t/data');

*_uuid = \&App::FeedScene::EntryUpdater::_uuid;

# Build a database for us to use.
ok my $dba = App::FeedScene::DBA->new( app => 'foo' ),
    'Create a DBA object';
ok $dba->upgrade, 'Initialize and upgrade the database';
END { unlink App::FeedScene->new->db_name };
my $conn = App::FeedScene->new->conn;

# Load some data for a portal.
$conn->txn(sub {
    my $sth = shift->prepare('INSERT INTO feeds (portal, url) VALUES(?, ?)');
    for my $spec (
        [ 0, 'simple.atom' ],
        [ 0, 'simple.rss' ],
        [ 0, 'summaries.rss' ],
        [ 0, 'latin-1.atom' ],
        [ 0, 'latin-1.rss' ],
        [ 0, 'dates.rss' ],
        [ 0, 'conflict.rss' ],
        [ 1, 'enclosures.atom' ],
    ) {
        $sth->execute($spec->[0], "$uri/$spec->[1]" );
    }
});

is $conn->run(sub {
    (shift->selectrow_array('SELECT COUNT(*) FROM feeds'))[0]
}), 8, 'Should have eight feeds in the database';
test_counts(0, 'Should have no entries');

# Construct a feed updater.
ok my $eup = App::FeedScene::EntryUpdater->new(
    app    => 'foo',
    portal => 0,
), 'Create a EntryUpdater object';

isa_ok $eup, 'App::FeedScene::EntryUpdater', 'It';
is $eup->app, 'foo', 'The app attribute should be set';

# Test request failure.
my $mock = Test::MockModule->new('HTTP::Response');
$mock->mock( is_success => 0 );
$mock->mock( code => HTTP_INTERNAL_SERVER_ERROR );
$mock->mock( message => 'OMGWTF' );
throws_ok { $eup->run } qr/000 Unknown code/, 'Should get exception request failure';
test_counts(0, 'Should still have no entries');

# Test HTTP_NOT_MODIFIED.
$mock->mock( code => HTTP_NOT_MODIFIED );
ok $eup->run, 'Run the update';
test_counts(0, 'Should still have no feeds');

# Test success.
$mock->unmock('code');
$mock->unmock('is_success');

$eup = Test::MockObject::Extends->new( $eup );

my @urls = (
    "$uri/simple.atom",
    "$uri/simple.rss",
    "$uri/summaries.rss",
    "$uri/latin-1.atom",
    "$uri/latin-1.rss",
    "$uri/dates.rss",
    "$uri/conflict.rss",
);

$eup->mock(process => sub {
    my ($self, $url, $feed) = @_;
    ok +(grep { $_ eq $url } @urls), 'Should have a feed URL';
    isa_ok $feed, 'XML::Feed';
});

ok $eup->run, 'Run the update again -- should have feeds in previous two tests';
$eup->unmock('process');

##############################################################################
# Okay, now let's test the processing.
ok my $feed = XML::Feed->parse('t/data/simple.atom'),
    'Grab a simple Atom feed';
ok $eup->process("$uri/simple.atom", $feed), 'Process the Atom feed';
test_counts(2, 'Should now have two entries');

# Check the feed data.
is_deeply $conn->run(sub{ shift->selectrow_arrayref(
    'SELECT name, site_url FROM feeds WHERE url = ?',
    undef, "$uri/simple.atom",
)}), ['Simple Atom Feed', 'http://example.com/'], 'Atom feed should be updated';

# Check the entry data.
is_deeply test_data('urn:uuid:e287d28b-5a4b-575c-b9da-d3dc894b9aa2'), {
    id             => 'urn:uuid:e287d28b-5a4b-575c-b9da-d3dc894b9aa2',
    portal         => 0,
    feed_url       => "$uri/simple.atom",
    url            => 'http://example.com/story.html',
    title          => 'This is the title',
    published_at   => '2009-12-13T12:29:29Z',
    updated_at     => '2009-12-13T18:30:02Z',
    summary        => '<p>Summary of the story</p>',
    author         => 'Ira Glass',
    enclosure_url  => '',
    enclosure_type => '',
}, 'Data for first entry should be correct';

is_deeply test_data('urn:uuid:4386a769-775f-5b78-a6f0-02e3ac8a457d'), {
    id             => 'urn:uuid:4386a769-775f-5b78-a6f0-02e3ac8a457d',
    portal         => 0,
    feed_url       => "$uri/simple.atom",
    url            => 'http://example.com/another-story.html',
    title          => 'This is another title',
    published_at   => '2009-12-13T12:29:29Z',
    updated_at     => '2009-12-13T18:30:03Z',
    summary        => '<p>Summary of the second story</p>',
    author         => '',
    enclosure_url  => '',
    enclosure_type => '',
}, 'Data for second entry should be correct';

##############################################################################
# Let's try a simple RSS feed.
ok $feed = XML::Feed->parse('t/data/simple.rss'),
    'Grab a simple RSS feed';
ok $eup->process("$uri/simple.rss", $feed), 'Process the RSS feed';
test_counts(4, 'Should now have four entries');

# Check the feed data.
is_deeply $conn->run(sub{ shift->selectrow_arrayref(
    'SELECT name, site_url FROM feeds WHERE url = ?',
    undef, "$uri/simple.rss",
)}), ['Simple RSS Feed', 'http://example.net'], 'RSS feed should be updated';

# Check the entry data.
is_deeply test_data('urn:uuid:5a47d6e5-41dd-586b-ad03-c26c67425134'), {
    id             => 'urn:uuid:5a47d6e5-41dd-586b-ad03-c26c67425134',
    portal         => 0,
    feed_url       => "$uri/simple.rss",
    url            => 'http://example.net/2010/05/17/long-goodbye/',
    title          => 'The Long Goodbye',
    published_at   => '2010-05-17T14:58:50Z',
    updated_at     => '2010-05-17T14:58:50Z',
    summary        => '<p>Wherein Marlowe finds himeslf in trouble again.</p>',
    author         => 'Raymond Chandler',
    enclosure_url  => '',
    enclosure_type => '',
}, 'Data for first RSS entry, including unformatted summary';

is_deeply test_data('urn:uuid:f7d5ce8a-d0d5-56bc-99c3-05592f4dc22c'), {
    id             => 'urn:uuid:f7d5ce8a-d0d5-56bc-99c3-05592f4dc22c',
    portal         => 0,
    feed_url       => "$uri/simple.rss",
    url            => 'http://example.net/2010/05/16/little-sister/',
    title          => 'The Little Sister',
    published_at   => '2010-05-16T14:58:50Z',
    updated_at     => '2010-05-16T14:58:50Z',
    summary        => '<p>Hollywood babes.</p><p>A killer with an ice pick.</p><p>What could be better?</p>',
    author         => 'Raymond Chandler',
    enclosure_url  => '',
    enclosure_type => '',
}, 'Data for second RSS entry, including summary extracted from content';

##############################################################################
# Test a non-utf8 Atom feed.
ok $feed = XML::Feed->parse('t/data/latin-1.atom'),
    'Grab a Latin-1 feed';
ok $eup->process("$uri/latin-1.atom", $feed), 'Process the RSS feed';
test_counts(5, 'Should now have five entries');

my ($title, $summary) = $conn->dbh->selectrow_array(
    'SELECT title, summary FROM entries WHERE id = ?',
    undef, 'urn:uuid:acda412e-967c-572c-a175-89441b378638'
);

is $title, 'Title: æåø', 'Latin-1 Title should be UTF-8';
is $summary, '<p>Latin-1: æåø</p>', 'Latin-1 Summary should be UTF-8';

##############################################################################
# Test a non-utf8 RSS feed.
ok $feed = XML::Feed->parse('t/data/latin-1.rss'),
    'Grab a Latin-1 feed';
ok $eup->process("$uri/latin-1.rss", $feed), 'Process the RSS feed';
test_counts(6, 'Should now have six entries');

($title, $summary) = $conn->dbh->selectrow_array(
    'SELECT title, summary FROM entries WHERE id = ?',
    undef, 'urn:uuid:6752bbb0-c0b6-5a4b-ac30-acc3cf427417'
);

is $title, 'Title: æåø', 'Latin-1 Title should be UTF-8';
is $summary, '<p>Latin-1: æåø</p>', 'Latin-1 Summary should be UTF-8';

##############################################################################
# Test a variety of RSS summary formats.
ok $feed = XML::Feed->parse('t/data/summaries.rss'),
    'Grab RSS feed with various summaries';
ok $eup->process("$uri/summaries.rss", $feed), 'Process the RSS feed';
test_counts(21, 'Should now have 21 entries');

my $dbh = $conn->dbh;
for my $spec (
    [ 1  => '<p>Simple summary in plain text.</p>'],
    [ 2  => '<p>Simple summary in a paragraph.</p>'],
    [ 3  => '<p>Paragraph <em>summary</em> with emphasis.</p>' ],
    [ 4  => '<p>Paragraph summary with anchor.</p>'],
    [ 5  => '<p>First graph.</p><p>Second graph.</p>'],
    [ 6  => '<p>First graph.</p><p>Second graph.</p><p>Third graph with a lot more stuff in it, to get us over 140 characters, if you know what I mean.</p>'],
    [ 7  => '<p>Paragraph <em>summary</em> with em+attr.</p>' ],
    [ 8  => '<p>The <abbr title="World Health Organization">WHO</abbr> was founded in 1948.</p>'],
    [ 9  => '<p>Paragraph <i>summary</i> with anchor and child element.</p>'],
    [ 10 => '<p>Paragraph summary with font.</p>' ],
    [ 11 => '<p>Simple summary in plain text with <em>emphasis</em>.</p>'],
    [ 12 => '<p>Simple summary in plain text with separate content.</p>'],
    [ 13 => '<p>First graph.</p><p>Second graph.</p><p>Third graph with a lot more stuff in it, to get us over 140 characters, if you know what I mean.</p><p>Fourth graph should be included.</p>'],
    [ 14 => '<p>Summary with <em>emphasis</em> complementing content.</p>' ],
    [ 15 => '<p>Summary with <i>emphasis</i> in anchor.</p>' ],
) {
    is +($dbh->selectrow_array(
        'SELECT summary FROM entries WHERE id = ?',
        undef, _uuid($feed->link, "http://foo.org/lg$spec->[0]")
    ))[0], $spec->[1], "Should have proper summary for entry $spec->[0]";
}

##############################################################################
# Try a bunch of different date combinations.
ok $feed = XML::Feed->parse('t/data/dates.rss'),
    'Grab RSS feed with various dates';
ok $eup->process("$uri/dates.rss", $feed), 'Process the RSS dates feed';
test_counts(27, 'Should now have 27 entries');

for my $spec (
    [ 1 => ['2010-05-17T06:58:50Z', '2010-05-17T07:45:09Z'], 'both dates' ],
    [ 2 => ['2010-05-17T06:58:50Z', '2010-05-17T06:58:50Z'], 'published only date' ],
    [ 3 => ['2010-05-17T07:45:09Z', '2010-05-17T07:45:09Z'], 'modified only date' ],
    [ 4 => ['2010-05-17T00:00:00Z', '2010-05-17T00:00:00Z'], 'floating pubDate' ],
    [ 5 => ['2010-05-17T14:58:50Z', '2010-05-17T14:58:50Z'], 'offset date'],
    [ 6 => ['2010-05-17T11:58:50Z', '2010-05-17T11:58:50Z'], 'zoned date'],
) {
    is_deeply $dbh->selectrow_arrayref(
        'SELECT published_at, updated_at FROM entries WHERE id = ?',
        undef,
        _uuid($feed->link, "http://baz.org/lg$spec->[0]")
    ), $spec->[1], "Should have $spec->[2]";
}

##############################################################################
# Try a feed with a duplicate URI and no GUID.
ok $feed = XML::Feed->parse('t/data/conflict.rss'),
    'Grab RSS feed with a duplicate link';
ok $eup->process("$uri/conflict.rss", $feed), 'Process the conflicting RSS feed';
test_counts(28, 'Should now have 28 entries');

# So now we should have two records with the same URL but different IDs.
is_deeply $dbh->selectall_arrayref(
    'SELECT id, feed_url FROM entries WHERE url = ? ORDER BY id',
    undef, 'http://example.net/2010/05/17/long-goodbye/'
), [
    [
        'urn:uuid:5a47d6e5-41dd-586b-ad03-c26c67425134',
        'file://localhost/Users/david/dev/github/app-feedscene/t/data/simple.rss'
    ],
    [
        'urn:uuid:bd1ce00c-ab8c-50bc-81c9-60ece4baa685',
        'file://localhost/Users/david/dev/github/app-feedscene/t/data/conflict.rss'
    ]
], 'Should have two rows with the same link but different IDs  and feed URLs';

##############################################################################
# Try a feed with enclosures.
ok $feed = XML::Feed->parse('t/data/enclosures.atom'),
    'Grab Atom feed with enclosures';
$eup->portal(1);
ok $eup->process("$uri/enclosures.atom", $feed), 'Process the enclosures feed';
test_counts(39, 'Should now have 39 entries');

# First one is easy, has only one enclosure.
is_deeply test_data('urn:uuid:afac4e17-4775-55c0-9e61-30d7630ea909'), {
    author         => '',
    enclosure_type => 'image/jpeg',
    enclosure_url  => 'http://farm2.static.flickr.com/1169/4601733070_92cd987ff5_o.jpg',
    feed_url       => 'file://localhost/Users/david/dev/github/app-feedscene/t/data/enclosures.atom',
    id             => 'urn:uuid:afac4e17-4775-55c0-9e61-30d7630ea909',
    portal         => 1,
    published_at   => '2009-12-13T08:29:29Z',
    summary        => '<p>Caption for the encosed image.</p>',
    title          => 'This is the title',
    updated_at     => '2009-12-13T08:29:29Z',
    url            => 'http://flickr.com/someimage'
}, 'Data for first entry with enclosure should be correct';

is_deeply test_data('urn:uuid:844df0ef-fed0-54f0-ac7d-2470fa7e9a9c'), {
    author         => '',
    enclosure_type => 'image/jpeg',
    enclosure_url  => 'http://farm2.static.flickr.com/1169/4601733070_92cd987ff6_o.jpg',
    feed_url       => 'file://localhost/Users/david/dev/github/app-feedscene/t/data/enclosures.atom',
    id             => 'urn:uuid:844df0ef-fed0-54f0-ac7d-2470fa7e9a9c',
    portal         => 1,
    published_at   => '2009-12-13T08:19:29Z',
    summary        => '<p>Caption for both of the the encosed images.</p>',
    title          => 'This is the title',
    updated_at     => '2009-12-13T08:19:29Z',
    url            => 'http://flickr.com/twoimages'
}, 'Data for entry with two should have just the first enclosure';

# Now check those that had no enclosure but pulled it in from the content.

for my $spec (
    [ 'embeddedimage' => [
        '<p>Caption for the embedded image.</p>',
        'image/jpeg',
        'http://flickr.com/someimage.jpg'
    ], 'embedded JPEG' ],
    [ 'embedtwo' => [
        '<p>Caption for both of the embedded images.</p>',
        'image/jpeg',
        'http://flickr.com/someimage.jpg'
    ], 'two embedded JPEGs' ],
    [ 'audio' => [
        '<p>Caption for the enclosed audio.</p>',
        'audio/mpeg',
        'http://flickr.com/audio.mp3'
    ], 'audio enclosure' ],
    [ 'video' => [
        '<p>Caption for the enclosed video.</p>',
        'video/mpeg',
        'http://flickr.com/video.mov'
    ], 'video enclosure' ],
    [ 'embedaudio' => [
        '<p>Caption for the embedded audio.</p>',
        'audio/mpeg',
        'http://flickr.com/anotheraudio.mp3'
    ], 'audio enclosure' ],
    [ 'embedvideo' => [
        '<p>Caption for the embedded video.</p>',
        'video/quicktime',
        'http://flickr.com/anothervideo.mov'
    ], 'video enclosure' ],
    [ 'skipunwanted' => [
        '<p>Caption for the enclosed audio.</p>',
        'audio/mpeg',
        'http://flickr.com/audio.mp3'
    ], 'audio enclosure' ],
    [ 'skipembed' => [
        '<p>Caption for the embedded audio.</p>',
        'audio/mpeg',
        'http://flickr.com/audio.mp3'
    ], 'audio enclosure' ],
    [ 'audio.mp3' => [
        '<p>Caption for the audio link.</p>',
        'audio/mpeg',
        'http://flickr.com/audio.mp3'
    ], 'direct link' ],
) {
    is_deeply $dbh->selectrow_arrayref(
        'SELECT summary, enclosure_type, enclosure_url FROM entries WHERE id = ?',
        undef, _uuid($feed->link, "http://flickr.com/$spec->[0]")
    ), $spec->[1], "Should have proper enclosure for $spec->[0]";
}

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

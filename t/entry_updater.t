#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 47;
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

# Build a database for us to use.
ok my $dba = App::FeedScene::DBA->new( app => 'foo' ),
    'Create a DBA object';
ok $dba->upgrade, 'Initialize and upgrade the database';
END { unlink App::FeedScene->new->db_name };

# Load some data for a portal.
App::FeedScene->new('foo')->conn->txn(sub {
    my $sth = shift->prepare('INSERT INTO feeds (portal, url) VALUES(?, ?)');
    for my $spec (
        [ 0, 'simple.atom' ],
        [ 0, 'simple.rss' ],
        [ 0, 'summaries.rss' ],
        # [ 1, 'meumoleskinedigital.rss' ],
        # [ 2, 'flickr.atom' ],
        # [ 3, 'flickr.rss' ],
    ) {
        $sth->execute($spec->[0], "$uri/$spec->[1]" );
    }
});

is +App::FeedScene->new->conn->run(sub {
    (shift->selectrow_array('SELECT COUNT(*) FROM feeds'))[0]
}), 3, 'Should have three feeds in the database';
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
is_deeply +App::FeedScene->new->conn->run(sub{ shift->selectrow_arrayref(
    'SELECT name, site_url FROM feeds WHERE url = ?',
    undef, "$uri/simple.atom",
)}), ['Simple Atom Feed', 'http://example.com/'], 'Atom feed should be updated';

# Check the entry data.
is_deeply test_data('urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a'), {
    id             => 'urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a',
    portal         => 0,
    feed_url       => "$uri/simple.atom",
    url            => 'http://example.com/story.html',
    title          => 'This is the title',
    published_at   => '2009-12-13T12:29:29',
    updated_at     => '2009-12-13T18:30:02',
    summary        => '<p>Summary of the story</p>',
    author         => 'Ira Glass',
    enclosure_url  => '',
    enclosure_type => '',
}, 'Data for first entry should be correct';

is_deeply test_data('urn:uuid:1225c695-cfb8-4ebb-bbbb-80da344efa6b'), {
    id             => 'urn:uuid:1225c695-cfb8-4ebb-bbbb-80da344efa6b',
    portal         => 0,
    feed_url       => "$uri/simple.atom",
    url            => 'http://example.com/another-story.html',
    title          => 'This is another title',
    published_at   => '2009-12-13T12:29:29',
    updated_at     => '2009-12-13T18:30:03',
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
is_deeply +App::FeedScene->new->conn->run(sub{ shift->selectrow_arrayref(
    'SELECT name, site_url FROM feeds WHERE url = ?',
    undef, "$uri/simple.rss",
)}), ['Simple RSS Feed', 'http://example.net'], 'RSS feed should be updated';

# Check the entry data.
is_deeply test_data('http://example.net/2010/05/17/long-goodbye/'), {
    id             => 'http://example.net/2010/05/17/long-goodbye/',
    portal         => 0,
    feed_url       => "$uri/simple.rss",
    url            => 'http://example.net/2010/05/17/long-goodbye/',
    title          => 'The Long Goodbye',
    published_at   => '2010-05-17T06:58:50',
    updated_at     => '2010-05-17T06:58:50',
    summary        => '<p>Wherein Marlowe finds himeslf in trouble again.</p>',
    author         => 'Raymond Chandler',
    enclosure_url  => '',
    enclosure_type => '',
}, 'Data for first RSS entry, including Markdown-formatted summary';

is_deeply test_data('http://example.net/2010/05/16/little-sister/'), {
    id             => 'http://example.net/2010/05/16/little-sister/',
    portal         => 0,
    feed_url       => "$uri/simple.rss",
    url            => 'http://example.net/2010/05/16/little-sister/',
    title          => 'The Little Sister',
    published_at   => '2010-05-16T06:58:50',
    updated_at     => '2010-05-16T06:58:50',
    summary        => '<p>Hollywood babes.</p><p>A killer with an ice pick.</p><p>What could be better?</p>',
    author         => 'Raymond Chandler',
    enclosure_url  => '',
    enclosure_type => '',
}, 'Data for second RSS entry, including summary extracted from content';


##############################################################################
# Test a variety of RSS summary formats.
ok $feed = XML::Feed->parse('t/data/summaries.rss'),
    'Grab a simple RSS feed';
ok $eup->process("$uri/summaries.rss", $feed), 'Process the RSS feed';
test_counts(15, 'Should now have 15 entries');

my $dbh = +App::FeedScene->new->conn->dbh;
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
) {
    is +($dbh->selectrow_array(
        'SELECT summary FROM entries WHERE id = ?',
        undef, "http://foo.org/lg$spec->[0]")
     )[0], $spec->[1], "Should have proper summary for entry $spec->[0]";
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

#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 24;
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
    use_ok 'App::FeedScene::FeedUpdate' or die;
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
    my $sth = shift->prepare('INSERT INTO links (portal, url) VALUES(?, ?)');
    for my $spec (
        [ 0, 'simple.atom' ],
        [ 0, 'bestweb.rss' ],
        [ 1, 'qbn.rss' ],
        [ 1, 'meumoleskinedigital.rss' ],
        [ 2, 'flickr.atom' ],
        [ 3, 'flickr.rss' ],
    ) {
        $sth->execute($spec->[0], "$uri/$spec->[1]" );
    }
});

is +App::FeedScene->new->conn->run(sub {
    (shift->selectrow_array('SELECT COUNT(*) FROM links'))[0]
}), 6, 'Should have six links in the database';
test_counts(0, 'Should have no entries');

# Construct a feed updater.
ok my $fup = App::FeedScene::FeedUpdate->new(
    app    => 'foo',
    portal => 0,
), 'Create a FeedUpdate object';

isa_ok $fup, 'App::FeedScene::FeedUpdate', 'It';
is $fup->app, 'foo', 'The app attribute should be set';

# Test request failure.
my $mock = Test::MockModule->new('HTTP::Response');
$mock->mock( is_success => 0 );
$mock->mock( code => HTTP_INTERNAL_SERVER_ERROR );
$mock->mock( message => 'OMGWTF' );
throws_ok { $fup->run } qr/000 Unknown code/, 'Should get exception request failure';
test_counts(0, 'Should still have no entries');

# Test HTTP_NOT_MODIFIED.
$mock->mock( code => HTTP_NOT_MODIFIED );
ok $fup->run, 'Run the update';
test_counts(0, 'Should still have no links');

# Test success.
$mock->unmock('code');
$mock->unmock('is_success');

$fup = Test::MockObject::Extends->new( $fup );

my @urls = (
    "$uri/bestweb.rss",
    "$uri/simple.atom",
);

$fup->mock(process => sub {
    my ($self, $url, $feed) = @_;
    ok +(grep { $_ eq $url } @urls), 'Should have a feed URL';
    isa_ok $feed, 'XML::Feed';
});

ok $fup->run, 'Run the update again -- should have feeds in previous two tests';

# Okay, now let's test the processing.
$fup->unmock('process');
ok my $feed = XML::Feed->parse('t/data/simple.atom'),
    'Grab a simple feed';
ok $fup->process("$uri/simple.atom", $feed), 'Process the feed';
test_counts(2, 'Should now have two entries');

# Check the data.
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

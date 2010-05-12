#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 28;
#use Test::More 'no_plan';
use Test::NoWarnings;
use Test::MockModule;
use HTTP::Status qw(HTTP_NOT_MODIFIED HTTP_INTERNAL_SERVER_ERROR);
use LWP::Protocol::file; # Turn on local fetches.
use Test::Exception;

BEGIN {
    use_ok 'App::FeedScene::DBA' or die;
    use_ok 'App::FeedScene::LinkUpdater' or die;
}

my $uri = 'file://localhost' . File::Spec->rel2abs('t/data');

ok my $lup = App::FeedScene::LinkUpdater->new(
    app => 'foo',
    url => "$uri/feeds.csv",
), 'Create a LinkUpdater object';

isa_ok $lup, 'App::FeedScene::LinkUpdater', 'It';

is $lup->app, 'foo', 'The app attribute should be set';
is $lup->url, "$uri/feeds.csv", 'The URL attribute should be set';

# Build a database for us to use.
ok my $dba = App::FeedScene::DBA->new( app => 'foo' ),
    'Create a DBA object';
ok $dba->upgrade, 'Initialize and upgrade the database';
END { unlink App::FeedScene->new->db_name };

test_counts(0, 'Should have no links');

# Test request failure.
my $mock = Test::MockModule->new('HTTP::Response');
$mock->mock( is_success => 0 );
$mock->mock( code => HTTP_INTERNAL_SERVER_ERROR );
$mock->mock( message => 'OMGWTF' );
throws_ok { $lup->run } qr/000 Unknown code/, 'Should get exception request failure';

# Test HTTP_NOT_MODIFIED.
$mock->mock( code => HTTP_NOT_MODIFIED );
ok $lup->run, 'Run the update';
test_counts(0, 'Should still have no links');

# Test success.
$mock->unmock('code');
$mock->unmock('is_success');

ok $lup->run, 'Run the update again';
test_counts(14, 'Should now have 14 links');

# Check some links.
test_links(0, [
    'http://www.kineticode.com/feeds/rss/rss.xml',
    'http://www.strongrrl.com/rss.xml',
]);

# Check links with Unicode.
test_links(1, [
    'http://ideas.example.com/atom/skinny',
    'http://www.lunarboy.com/category/lögo-designs/feed',
]);

# Check last links.
test_links(6, [
    'http://pipes.yahoo.com/pipes/pipe.run?Size=Medium&_id=f000000&_render=rss',
    'http://www.designsceneapp.com/rss/'
]);

# Now update with the same feed file, just for the hell of it.
ok $lup->run, 'Run the update a third time';
test_counts(14, 'Should still have 14 links');

# Check some links.
test_links(0, [
    'http://www.kineticode.com/feeds/rss/rss.xml',
    'http://www.strongrrl.com/rss.xml',
]);

# Check links with Unicode.
test_links(1, [
    'http://ideas.example.com/atom/skinny',
    'http://www.lunarboy.com/category/lögo-designs/feed',
]);

# Check last links.
test_links(6, [
    'http://pipes.yahoo.com/pipes/pipe.run?Size=Medium&_id=f000000&_render=rss',
    'http://www.designsceneapp.com/rss/'
]);

# Now update from a new version.
ok $lup->url("$uri/feeds2.csv"), 'Update the URL';
ok $lup->run, 'Update with the revised feed';
test_counts(12, 'Should now have 12 links');

test_links(0, [
    'http://kineticode.com/feeds/rss/rss.xml',
    'http://strongrrl.com/rss.xml',
]);

# Check Unicode category names.
is_deeply +App::FeedScene->new->conn->run(sub {
    (shift->selectrow_array(
        'SELECT category FROM links WHERE url = ?',
        undef, 'http://justatheory.com/brandnew/atom.xml',
    ))[0]
}), 'Lögos & Branding', 'Should have utf8 category';

sub test_counts {
    my ($count, $descr) = @_;
    is +App::FeedScene->new->conn->run(sub {
        (shift->selectrow_array('SELECT COUNT(*) FROM links'))[0]
    }), $count, $descr;
}

sub test_links {
    my ($portal, $links) = @_;
    is_deeply +App::FeedScene->new->conn->run(sub { shift->selectcol_arrayref(q{
        SELECT url FROM links WHERE portal = ? ORDER BY url
    }, undef, $portal) }), $links, "Should have the proper links for portal $portal";
}

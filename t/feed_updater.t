#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 32;
#use Test::More 'no_plan';
use Test::NoWarnings;
use Test::MockModule;
use HTTP::Status qw(HTTP_NOT_MODIFIED HTTP_INTERNAL_SERVER_ERROR);
use LWP::Protocol::file; # Turn on local fetches.
use Test::Exception;
use File::Path;
use Test::MockTime;

BEGIN {
    use_ok 'App::FeedScene::DBA' or die;
    use_ok 'App::FeedScene::FeedUpdater' or die;
}

File::Path::make_path 'db';

# Set an absolute time.
my $time = '2010-06-05T17:29:41Z';
Test::MockTime::set_fixed_time($time);

my $uri = 'file://localhost' . File::Spec->rel2abs('t/data');

ok my $lup = App::FeedScene::FeedUpdater->new(
    app => 'foo',
    url => "$uri/feeds.csv",
), 'Create a FeedUpdater object';

isa_ok $lup, 'App::FeedScene::FeedUpdater', 'It';

is $lup->app, 'foo', 'The app attribute should be set';
is $lup->url, "$uri/feeds.csv", 'The URL attribute should be set';
is $lup->ua, undef, 'The ua attribute should be undefined';
is $lup->verbose, undef, 'The verbose attribute should be false';

# Build a database for us to use.
ok my $dba = App::FeedScene::DBA->new( app => 'foo' ),
    'Create a DBA object';
ok $dba->upgrade, 'Initialize and upgrade the database';
END {
    unlink App::FeedScene->new->db_name;
    File::Path::remove_tree 'cache/foo';
};

test_counts(0, 'Should have no feeds');

# Test request failure.
my $mock = Test::MockModule->new('HTTP::Response');
$mock->mock( is_success => 0 );
$mock->mock( code => HTTP_INTERNAL_SERVER_ERROR );
$mock->mock( message => 'OMGWTF' );
throws_ok { $lup->run } qr/000 Unknown code/, 'Should get exception request failure';
isa_ok $lup->ua, 'App::FeedScene::UA', 'The ua attribute should now be set';

# Test HTTP_NOT_MODIFIED.
$mock->mock( code => HTTP_NOT_MODIFIED );
ok $lup->run, 'Run the update';
test_counts(0, 'Should still have no feeds');

# Test success.
$mock->unmock_all;

my $csv = Test::MockModule->new('Text::CSV_XS');
my @feeds = qw(
    simple.atom
    simple.rss
    summaries.rss
    latin-1.atom
    latin-1.rss
    dates.rss
    conflict.rss
    enclosures.atom
    enclosures.rss
);

my @feed_fields = @feeds;
my $orig = Text::CSV_XS->can('fields');
$csv->mock(fields => sub {
    my @r = shift->$orig(@_);
    $r[1] = "$uri/" . shift @feed_fields;
    @r;
});

ok $lup->run, 'Run the update again';
test_counts(9, 'Should now have 9 feeds');

# Check some feeds.
test_initial_feeds();

# Now update with the same feed file, just for the hell of it.
@feed_fields = @feeds;
ok $lup->run, 'Run the update a third time';
test_counts(9, 'Should still have 9 feeds');

# Check some feeds.
test_initial_feeds();

@feed_fields = @feeds;
# Now update from a new version.
ok $lup->url("$uri/feeds2.csv"), 'Update the URL';
ok $lup->run, 'Update with the revised feed';
test_counts(7, 'Should now have 7 feeds');

    test_feeds(0, [
        {
            url      => "$uri/simple.atom",
            title    => 'Simple Atom Feed',
            subtitle => 'Witty & clever',
            site_url => 'http://example.com/',
            icon_url => 'http://www.google.com/s2/favicons?domain=example.com',
            updated_at => '2009-12-13T18:30:02Z',
            rights   => '© 2010 Big Fat Example',
            category => '',
            id       => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
        },
        {
            url      => "$uri/simple.rss",
            title    => 'Simple RSS Feed',
            subtitle => '',
            site_url => 'http://example.net',
            icon_url => 'http://www.google.com/s2/favicons?domain=example.net',
            updated_at => '2010-05-17T00:00:00Z',
            rights   => '',
            category => '',
            id       => "$uri/simple.rss",
        },
    ]);

sub test_counts {
    my ($count, $descr) = @_;
    is +App::FeedScene->new->conn->run(sub {
        (shift->selectrow_array('SELECT COUNT(*) FROM feeds'))[0]
    }), $count, $descr;
}

sub test_feeds {
    my ($portal, $feeds) = @_;
    is_deeply +App::FeedScene->new->conn->run(sub { shift->selectall_arrayref(q{
        SELECT id, url, title, subtitle, site_url, icon_url, updated_at, rights, category
          FROM feeds
         WHERE portal = ?
         ORDER BY url
    }, { Slice => {}}, $portal) }), $feeds, "Should have the proper feeds for portal $portal";
}

sub test_initial_feeds {
    test_feeds(0, [
        {
            url      => "$uri/simple.atom",
            title    => 'Simple Atom Feed',
            subtitle => 'Witty & clever',
            site_url => 'http://example.com/',
            icon_url => 'http://www.google.com/s2/favicons?domain=example.com',
            updated_at => '2009-12-13T18:30:02Z',
            rights   => '© 2010 Big Fat Example',
            category => '',
            id       => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6',
        },
        {
            url      => "$uri/simple.rss",
            title    => 'Simple RSS Feed',
            subtitle => '',
            site_url => 'http://example.net',
            icon_url => 'http://www.google.com/s2/favicons?domain=example.net',
            updated_at => '2010-05-17T00:00:00Z',
            rights   => '',
            category => '',
            id       => "$uri/simple.rss",
        },
    ]);

    # Check feed encodings.
    test_feeds(1, [
        {
            url      => "$uri/latin-1.atom",
            title    => 'Latin-1 Atom Feed',
            subtitle => '',
            site_url => 'http://foo.org/',
            icon_url => 'http://www.google.com/s2/favicons?domain=foo.org',
            updated_at => '2009-12-13T18:30:02Z',
            rights   => 'Copyright (c) 2010',
            category => 'Typography',
            id       => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af8',
        },
        {
            url      => "$uri/summaries.rss",
            title    => 'Summaries RSS Feed',
            subtitle => '',
            site_url => 'http://foo.org',
            icon_url => 'http://www.google.com/s2/favicons?domain=foo.org',
            updated_at => '2010-06-05T17:29:41Z',
            rights   => '',
            category => 'Lögos & Branding',
            id       => "$uri/summaries.rss",
        },
    ]);

    # Check bogus encoding.
    test_feeds(2, [
        {
            url      => "$uri/dates.rss",
            title    => 'Simple RSS Dates',
            subtitle => '',
            site_url => 'http://baz.org',
            icon_url => 'http://www.google.com/s2/favicons?domain=baz.org',
            updated_at => '2010-05-17T00:00:00Z',
            rights   => '',
            category => 'Infographics',
            id       => "$uri/dates.rss",
        },
        {
            url      => "$uri/latin-1.rss",
            title    => '"Latin-1 RSS Feed"', # Quotation marks are CP1252 in the XML.
            subtitle => '',
            site_url => 'http://foo.net/',
            icon_url => 'http://www.google.com/s2/favicons?domain=foo.net',
            updated_at => '2009-12-13T18:30:02Z',
            rights   => 'Copyright (c) 2010',
            category => 'Lögos & Branding',
            id      => "$uri/latin-1.rss",
        },
    ]);

    # Check last feeds.
    test_feeds(6, [
        {
            url      => "$uri/enclosures.atom",
            title    => 'Enclosures Atom Feed',
            subtitle => '',
            site_url => 'http://example.com/',
            icon_url => 'http://www.google.com/s2/favicons?domain=example.com',
            updated_at => '2009-12-13T18:30:02Z',
            rights   => '',
            category => 'Lögos & Branding',
            id       => 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af7',
        },
        {
            url      => "$uri/enclosures.rss",
            title    => 'Enclosures RSS Feed',
            subtitle => '',
            site_url => 'http://example.org/',
            icon_url => 'http://www.google.com/s2/favicons?domain=example.org',
            updated_at => '2010-05-17T14:58:50Z',
            rights   => '',
            category => 'Typography',
            id       => "$uri/enclosures.rss",
        },
    ]);
}

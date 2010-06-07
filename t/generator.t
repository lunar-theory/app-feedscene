#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 84;
#use Test::More 'no_plan';
use Test::XPath;
use Test::MockTime;
use Test::NoWarnings;

my $CLASS;
BEGIN {
    $CLASS = 'App::FeedScene::Generator';
    use_ok 'App::FeedScene::DBA' or die;
    use_ok $CLASS or die;
}

# Set an absolute time.
my $time = '2010-06-05T17:29:41Z';
Test::MockTime::set_absolute_time($time);
my $domain  = 'kineticode.com';
my $company = 'Lunar Theory';

# Build a database for us to use.
ok my $dba = App::FeedScene::DBA->new( app => 'foo' ),
    'Create a DBA object';
ok $dba->upgrade, 'Initialize and upgrade the database';
END { unlink App::FeedScene->new->db_name };

# Load some portal data.
my $uri = 'file://localhost' . File::Spec->rel2abs('t/data');
my $conn = App::FeedScene->new->conn;
$conn->txn(sub {
    my $sth = shift->prepare(q{
        INSERT INTO feeds (url, portal, title, rights, icon_url)
        VALUES(?, ?, ?, ?, ?)
    });
    for my $spec (
        [ 'simple.atom', 0,     'Simple Feed', 'Copyright', 'http://foo.com/fav.png' ],
        [ 'enclosures.atom', 1, 'Enclosures Feed', 'CC-SG', 'http://bar.com/fav.png' ],
    ) {
        $sth->execute("$uri/" . shift @{$spec}, @{$spec});
    }
});

ok my $gen = $CLASS->new(
    app => 'foo',
    dir => 'bar',
), 'Create generator object';
isa_ok $gen, $CLASS, 'It';
ok !$gen->strict, 'Should not be strict';
is $gen->app, 'foo', 'Its app attribute should be correct';
is $gen->dir, 'bar', 'Its dir attribute should be correct';
is $gen->filename, $gen->app . '.xml', 'Its filename should be correct';
is $gen->filepath, File::Spec->catfile($gen->dir, $gen->filename),
    'Its file path should be correct';
is $gen->id, "tag:$domain,2010:feedscene/feeds/" . $gen->filename,
    'Its id should be correct';
is $gen->link, "http://$domain/feeds/" . $gen->filename,
    'Its link should be correct';

# Try default values.
ok $gen = $CLASS->new(app => 'foo'), 'Create another with default dir';
ok !$gen->strict, 'Should not be strict';
is $gen->app, 'foo', 'Its app attribute should be correct';
is $gen->dir, File::Spec->rel2abs('feeds'),
    'The dir attribute should be the default';
is $gen->filename, $gen->app . '.xml', 'Its filename should be correct';
is $gen->filepath, File::Spec->catfile($gen->dir, $gen->filename),
    'Its file path should be correct';
is $gen->id, "tag:$domain,2010:feedscene/feeds/" . $gen->filename,
    'Its id should be correct';
is $gen->link, "http://$domain/feeds/" . $gen->filename,
    'Its link should be correct';

##############################################################################
# Test non-strict output.
#END { File::Path::remove_tree($gen->dir) if -d $gen->dir; }
ok $gen->go, 'Go!';
my $tx = Test::XPath->new(
    file  => $gen->filepath,
    xmlns => {
        'a'  => 'http://www.w3.org/2005/Atom',
        'fs' => "http://$domain/2010/FeedScene",
    },
);

test_root_metadata($tx);

# Check fs:sources element.
$tx->is('count(/a:feed/fs:sources)', 1, 'Should have 1 sources element');
$tx->ok('/a:feed/fs:sources', 'Should have sources', sub {
    $_->is('count(./fs:source)', 2, 'Should have two sources');
    $_->ok('./fs:source[1]', 'First source', sub {
        $_->is('count(./*)', 5, 'Should have five source subelements');
        $_->is('./fs:id', "$uri/simple.atom", 'ID should be correct');
        $_->is('./fs:link/@rel', 'self', 'Should have self link');
        $_->is('./fs:link/@href', "$uri/simple.atom", 'Link URL should be correct');
        $_->is('./fs:title', 'Simple Feed', 'Title should be correct');
        $_->is('./fs:rights', 'Copyright', 'Rights should be correct');
        $_->is('./fs:icon', 'http://foo.com/fav.png', 'Icon should be correct');
    });
    $_->ok('./fs:source[2]', 'Second source', sub {
        $_->is('count(./*)', 5, 'Should have five source subelements');
        $_->is('./fs:id', "$uri/enclosures.atom", 'ID should be correct');
        $_->is('./fs:link/@rel', 'self', 'Should have self link');
        $_->is('./fs:link/@href', "$uri/enclosures.atom", 'Link URL should be correct');
        $_->is('./fs:title', 'Enclosures Feed', 'Title should be correct');
        $_->is('./fs:rights', 'CC-SG', 'Rights should be correct');
        $_->is('./fs:icon', 'http://bar.com/fav.png', 'Icon should be correct');
    });
});


##############################################################################
# Test strict output.
ok $gen = $CLASS->new(app => 'foo', strict => 1), 'Create strict generator';
ok $gen->strict, 'It Should be strict';
ok $gen->go, 'Go strict!';

$tx = Test::XPath->new(
    file  => $gen->filepath,
    xmlns => {
        'a'  => 'http://www.w3.org/2005/Atom',
        'fs' => "http://$domain/2010/FeedScene",
    },
);

test_root_metadata($tx);

# Should have no fs:sources.
$tx->is('count(/a:feed/fs:sources)', 0, 'Should have no sources element');

sub test_root_metadata {
    my $tx = shift;
    $tx->is('count(/a:feed)', 1, 'Should have 1 feed element');
    # $tx->is(
    #     '/a:feed/@xmlns',
    #     'http://www.w3.org/2005/Atom',
    #     'Should have Atom namespace'
    # );

    # Check title element.
    $tx->is('count(/a:feed/a:title)', 1, 'Should have 1 title element');
    $tx->is('/a:feed/a:title', 'foo Feed', 'Title should be correct');

    # Check link element.
    $tx->is('count(/a:feed/a:link)', 1, 'Should have 1 link element');
    $tx->is(
        '/a:feed/a:link[@rel="self"]/@href',
        "http://$domain/feeds/foo.xml",
        'link rel="self" element value should be correct'
    );

    # Check updated element.
    $tx->is('count(/a:feed/a:updated)', 1, 'Should have 1 updated element');
    $tx->is('/a:feed/a:updated', $time, 'Updated value should be correct');

    # Check rights element.
    $tx->is('count(/a:feed/a:rights)', 1, 'Should have 1 rights element');
    $tx->is(
        '/a:feed/a:rights',
        "© 2010 $company and others",
        'Rights should be correct'
    );

    # Check generator element.
    $tx->is(
        'count(/a:feed/a:generator)',
        1,
        'Should have 1 generator element'
    );
    $tx->is(
        '/a:feed/a:generator',
        'FeedScene',
        'Generator value should be correct'
    );
    $tx->is(
        '/a:feed/a:generator/@uri',
        "http://$domain/feedscene/",
        'Generator URI should be correct'
    );
    $tx->is(
        '/a:feed/a:generator/@version',
        App::FeedScene->VERSION,
        'Generator version should be correct'
    );

    # Check author element.
    $tx->is('count(/a:feed/a:author)', 1, 'Should have one author element');
    $tx->is('count(/a:feed/a:author/*)', 2, 'Should have one author subelements');
    $tx->is('count(/a:feed/a:author/a:name)', 1, 'Should have one author/name element');
    $tx->is('count(/a:feed/a:author/a:uri)', 1, 'Should have one author/uri element');
    $tx->is('/a:feed/a:author/a:name', $company, 'Should have author name');
    $tx->is('/a:feed/a:author/a:uri', "http://$domain/", 'Should have author URI');
}

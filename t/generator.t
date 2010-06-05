#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 37;
#use Test::More 'no_plan';
use Test::XPath;
use Test::MockTime;

my $CLASS;
BEGIN {
    $CLASS = 'App::FeedScene::Generator';
    use_ok 'App::FeedScene::DBA' or die;
    use_ok $CLASS or die;
}

# Set an absolute time.
my $time = '2010-06-05T17:29:41Z';
Test::MockTime::set_absolute_time($time);
my $domain  = 'lunar-theory.com';
my $company = 'Lunar Theory';

ok my $gen = $CLASS->new(
    app => 'foo',
    dir => 'bar',
), 'Create generator object';
isa_ok $gen, $CLASS, 'It';
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

# Make it so!
END { File::Path::remove_tree($gen->dir) if -d $gen->dir; }
ok $gen->go, 'Go!';
my $tx = Test::XPath->new(
    file => $gen->filepath,
    xmlns => { 'a' => 'http://www.w3.org/2005/Atom' },
);
$tx->is('count(/a:feed)', 1, 'Should have 1 feed element');

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

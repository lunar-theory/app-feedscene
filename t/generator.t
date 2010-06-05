#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
#use Test::More tests => 102;
use Test::More 'no_plan';
use Test::XPath;

my $CLASS;
BEGIN {
    $CLASS = 'App::FeedScene::Generator';
    use_ok 'App::FeedScene::DBA' or die;
    use_ok $CLASS or die;
}

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

# Try default values.
ok $gen = $CLASS->new(app => 'foo'), 'Create another with default dir';
is $gen->app, 'foo', 'Its app attribute should be correct';
is $gen->dir, File::Spec->rel2abs('feeds'),
    'The dir attribute should be the default';
is $gen->filename, $gen->app . '.xml', 'Its filename should be correct';
is $gen->filepath, File::Spec->catfile($gen->dir, $gen->filename),
    'Its file path should be correct';

# Make it so!
END { File::Path::remove_tree($gen->dir) if -d $gen->dir; }
ok $gen->go, 'Go!';
my $tx = Test::XPath->new(
    file => $gen->filepath,
    xmlns => { 'atom' => 'http://www.w3.org/2005/Atom' },
);
$tx->is('count(/atom:feed)', 1, 'Should have 1 feed element');

# Check top-level elements.

$tx->is('count(/atom:feed/atom:title)', 1, 'Should have 1 title element');
$tx->is('/atom:feed/atom:title', 'foo Feed', 'Title should be correct');

# $tx->is( 'count(/html/body)', 1, 'Should have 1 body element' );

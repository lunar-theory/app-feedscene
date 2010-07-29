#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use File::Path;
use Test::More tests => 9;
#use Test::More 'no_plan';
use LWP::Protocol::file; # Turn on local fetches.

my $CLASS;
BEGIN {
    $CLASS = 'App::FeedScene::Parser';
    use_ok $CLASS or die;
    use_ok 'App::FeedScene::UA';
}

END {
    File::Path::remove_tree 'cache/foo';
}

my $uri = 'file://localhost' . File::Spec->rel2abs('t/data');

# Test Data::Feed stuff.
my $ua = App::FeedScene::UA->new('foo');
isa_ok $CLASS->parse_feed($ua->get("$uri/simple.atom")), 'Data::Feed::Atom';

# Test XML::LibXML stuff.
isa_ok $CLASS->libxml, 'XML::LibXML';
isa_ok $CLASS->parse_html_string('<p>foo</p>'), 'XML::LibXML::Document';

for my $spec (
    ['<p>foo</p>', 'foo', 'a paragraph'],
    ['<p>foo&amp;</p>', 'foo&', 'a paragraph + entity'],
    ['<p>foo<em>&amp;<strong>bar</strong></em></p>', 'foo&bar', 'nested elements + entity'],
    ['', '', 'empty string' ],
) {
    is $CLASS->strip_html($spec->[0]), $spec->[1], "Stripping $spec->[2]";
}

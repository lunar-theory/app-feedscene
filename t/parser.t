#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
#use Test::More tests => 23;
use Test::More 'no_plan';

my $CLASS;
BEGIN {
    $CLASS = 'App::FeedScene::Parser';
    use_ok $CLASS or die;
}

# Test Data::Feed stuff.
my $file = File::Spec->catfile(qw(t data simple.atom));
my $feed = do {
    open my $fh, '<', $file or die "Cannot open $file: $!\n";
    local $/;
    <$fh>;
};

isa_ok $CLASS->parse_feed($feed), 'Data::Feed::Atom';

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

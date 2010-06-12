#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 20;
#use Test::More 'no_plan';

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

# Test parse_encoding().
for my $encoding qw(
    utf-8
    UTF-8
    iso-8859-1
    euc-jp
) {
    for my $spec (
        ['<?xml version="1.0" encoding="%s"?><foo />', '1.0 decl'],
        ['<?xml version="1.1" encoding="%s"?><foo />', '1.1 decl'],
        [qq{<?xml\nversion="1.0"\nencoding="%s"\n?>\n<foo />}, 'multiline decl'],
   ) {
        is $CLASS->parse_encoding(sprintf($spec->[0], $encoding)),
            $encoding, "Should parse $encoding ecoding from $spec->[1]";
    }
}

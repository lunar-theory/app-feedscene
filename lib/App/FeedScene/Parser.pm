package App::FeedScene::Parser;

use 5.12.0;
use utf8;
use Data::Feed;
use Data::Feed::Parser::Atom;
use Data::Feed::Parser::RSS;
use XML::Liberal;
use XML::LibXML qw(XML_TEXT_NODE XML_ELEMENT_NODE);
use XML::LibXML::ErrNo;
use namespace::autoclean;
use HTML::Entities;

$XML::Atom::ForceUnicode = 1;
$Data::Feed::Parser::RSS::PARSER_CLASS = 'App::FeedScene::Parser::RSS';
XML::Liberal->globally_override('LibXML');

my $parser = XML::Liberal->new(LibXML => (
    recover    => 0,
    no_network => 1,
    no_blanks  => 1,
    no_cdata   => 1,
));
# Inconsistency in the params means that some params are ignored. Grrr.
$parser->recover(0);

RSSPARSER: {
    package App::FeedScene::Parser::RSS;
    use parent 'XML::RSS::LibXML';
    sub create_libxml { $parser }
}

sub libxml { $parser }

# Remove the XML entities, we don't want to decode them.
for my $entity (qw( amp gt lt quot apos)) {
    delete $HTML::Entities::entity2char{$entity};
}

sub isa_feed {
    my ($self, $res) = @_;
    # Assume content type is correct if it says it's XML.
    return 1 if $res->content_is_xml;

    # Ask Data::Feed.
    return !!Data::Feed->guess_format($res->decoded_content(ref => 1, charset => 'none'));
}

sub parse_feed {
    my ($self, $res) = @_;

    # XML is always binary, so don't use decoded_content.
    # http://juerd.nl/site.plp/perluniadvice
    local $@;

    # Yikes. This line replaced so that we can get proper decoding of
    # compressed content, but still need to pass the raw data to the parser.
    # So we have to re-encode it, because HTTP::Message's decoded_content()
    # both decompresses *and* decodes. Reported here:
    # https://github.com/gisle/libwww-perl/issues/17.
    my $feed = eval { Data::Feed->parse($res->decoded_content(ref => 1, charset => 'none')) };
    if (my $err = $@) {
        say STDERR "Error parsing ", eval { $res->request->uri }, eval {
            ' (libxml2 error code ' . $err->code . "):\n\n" . $err->as_string
        } || ":\n\n$err";
        say STDERR "Response Status: ", $res->status_line;
        say STDERR "Headers: ", $res->headers_as_string;
    }
    return $feed;
}

sub parse_html_string {
    my $self = shift;
    $self->libxml->parse_html_string(shift, {
        suppress_warnings => 1,
        suppress_errors   => 1,
        recover           => 2,
        @_
    });
}

sub strip_html {
    my $self = shift;
    return shift unless $_[0];
    my $doc = $self->parse_html_string(@_);
    _strip($doc->childNodes);
}

sub _strip {
    my $ret = '';
    for my $elem (@_) {
        $ret .= $elem->nodeType == XML_TEXT_NODE ? $elem->data
              : $elem->nodeType == XML_ELEMENT_NODE && $elem->nodeName eq 'br' ? ' '
              : _strip($elem->childNodes);
    }
    $ret =~ s/\s{2,}/ /g;
    return $ret;
}

1;

=head1 Name

App::FeedScene::Parser - FeedScene feed parser tools

=head1 Author

David E. Wheeler <david@lunar-theory.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

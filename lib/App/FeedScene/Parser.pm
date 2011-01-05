package App::FeedScene::Parser;

use 5.12.0;
use utf8;
use Data::Feed;
use Data::Feed::Parser::Atom;
use Data::Feed::Parser::RSS;
use XML::LibXML qw(XML_TEXT_NODE XML_ELEMENT_NODE);
use XML::LibXML::ErrNo;
use Encode;
use namespace::autoclean;
use HTML::Entities;

$XML::Atom::ForceUnicode = 1;
$Data::Feed::Parser::RSS::PARSER_CLASS = 'App::FeedScene::Parser::RSS';

my $parser = XML::LibXML->new({
    recover    => 2,
    no_network => 1,
    no_blanks  => 1,
    no_cdata   => 1,
});
# Inconsistency in the params means that some params are ignored. Grrr.
$parser->recover(2);

RSSPARSER: {
    package App::FeedScene::Parser::RSS;
    use parent 'XML::RSS::LibXML';
    sub create_libxml { $parser }
}

sub libxml { $parser }

# Remove the XML entities, we don't want to decode them.
for my $entity qw( amp gt lt quot apos) {
    delete $HTML::Entities::entity2char{$entity};
}

sub _handle_error {
    my ($err, $res) = @_;
    use Carp; $SIG{__DIE__} = \&Carp::confess;
    say STDERR "Error parsing ", $res->request->uri, eval {
        ' (libxml2 error code ' . $err->code . "):\n\n" . $err->as_string
    } || ":\n\n$err";
    say STDERR "Response Status: ", $res->status_line;
    say STDERR "Headers: ", $res->headers_as_string;
    return;
}

sub isa_feed {
    my ($self, $res) = @_;
    # Assume content type is correct if it says it's XML.
    return 1 if $res->content_is_xml;

    # Ask Data::Feed.
    return !!Data::Feed->guess_format($res->content_ref);
}

sub parse_feed {
    my ($self, $res) = @_;

    # XML is always binary, so don't use decoded_content.
    # http://juerd.nl/site.plp/perluniadvice
    my $body_ref = $res->content_ref;
    $parser->recover(0);
    local $@;

    my $fixed_invalid_char = 0;
    my $stripped_invalid_chars = 0;
    TRY: {
        my $feed = eval { Data::Feed->parse($body_ref) };
        if (my $err = $@) {
            given (eval { $err->code }) {
                when (XML::LibXML::ErrNo::ERR_INVALID_CHAR) {
                    # See if we can clean up the mess.
                    if ($fixed_invalid_char++) {
                        return _handle_error $err, $res if $stripped_invalid_chars++;
                        # We fixed it already, but maybe there are characters
                        # disallowed by the XML standard.
                        # http://www.w3.org/TR/xml11/#charsets
                        $$body_ref =~ s/[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f-\x84\x86-\x9f]//msg;
                    } else {
                        my $charset = $res->content_charset;
                        $$body_ref = encode($charset, decode($charset, $$body_ref));
                    }
                    redo TRY;
                }
                when (XML::LibXML::ErrNo::ERR_DOCUMENT_END) {
                    return _handle_error $err, $res if $stripped_invalid_chars++;
                    # Maybe some invalid characters have brokenated it. Seen
                    # in the wild.
                    $$body_ref =~ s/[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f-\x84\x86-\x9f]//msg;
                    redo TRY;
                }
                when (XML::LibXML::ErrNo::ERR_UNDECLARED_ENTITY) {
                    # Author included invalid entities. Convert them and try again.
                    my $charset = $res->content_charset;
                    $$body_ref = encode($charset, decode_entities(decode($charset, $$body_ref)));
                    redo TRY;
                }
                when (XML::LibXML::ErrNo::ERR_NAME_REQUIRED) {
                    # A character that should be an entity but isn't. Split into lines.
                    $$body_ref =~ s/\r\n?/\n/g;
                    my @lines = split /\n/ => $$body_ref;

                    # Grab the bogus character and encode it.
                    my $line_idx = $err->line - 1;
                    my ($ent) = substr($lines[$line_idx], $err->column - 1) =~ /^(\S+)/;
                    my $encoded = encode_entities($ent, q{&<>"'});

                    # Replace with the encoded version and try again.
                    substr $lines[$line_idx], $err->column - 1, length $ent, $encoded;
                    $$body_ref = join $/ => @lines;
                    redo TRY;
                }
                default {
                    return _handle_error $err, $res;
                }
            }
        }
        $parser->recover(2);
        return $feed;
    }
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

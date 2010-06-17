package App::FeedScene::Parser;

use 5.12.0;
use utf8;
use Data::Feed;
use Data::Feed::Parser::Atom;
use Data::Feed::Parser::RSS;
use XML::LibXML qw(XML_TEXT_NODE);
use namespace::autoclean;
#use HTML::Tidy;

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

# my $tidy   = HTML::Tidy->new({
#     'drop-font-tags'   => 1,
#     'drop-empty-paras' => 1,
#     'show-body-only'   => 1,
#     'output-xhtml'     => 1,
#      # Add the HTML five tags.
#     'new-inline-tags'  => join ', ', qw(
#         audio
#         mark
#         meter
#         time
#         progress
#         rp
#         rt
#         ruby
#         source
#         video
#     ),
#     'new-blocklevel-tags'  => join ', ', qw(
#         article
#         aside
#         canvas
#         command
#         datalist
#         details
#         embed
#         figcaption
#         figure
#         footer
#         header
#         hgroup
#         keygen
#         nav
#         output
#         section
#         summary
#     ),
# });

sub libxml { $parser }

sub parse_feed {
    my ($self, $res) = @_;

    # XML is always binary, so don't use decoded_content.
    # http://juerd.nl/site.plp/perluniadvice
    my $body = $res->content;
    return Data::Feed->parse(\$body);
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

# sub parse_html_string {
#     my ($self, $string) = (shift, shift);
#     my $opts = {
#         suppress_warnings => 1,
#         suppress_errors   => 0,
#         recover           => 0,
#         @_
#     };

#     my $ret = eval { $self->libxml->parse_html_string($string, $opts) };
#     return $ret unless $@;

#     # Try tidying things up.
#     $opts->{suppress_errors} = 1;
#     $opts->{recover} = 2;
#     return $self->libxml->parse_html_string($tidy->clean($string), $opts)
# }

sub strip_html {
    my $self = shift;
    return shift unless $_[0];
    my $doc = $self->parse_html_string(@_);
    _strip($doc->childNodes);
}

sub _strip {
    my $ret = '';
    for my $elem (@_) {
        $ret .= $elem->nodeType == XML_TEXT_NODE
            ? $elem->data
            : _strip($elem->childNodes);
    }
    return $ret;
}

sub parse_encoding {
    my $self = shift;
    my ($decl) = shift =~ /^(<[?]xml[^>]+>)/ms;
    my $doc = eval {
        $self->libxml->parse_string("$decl\n<foo />")
    } or return;
    return $doc->encoding;
}

1;

=head1 Name

App::FeedScene::Parser - FeedScene feed parser tools

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

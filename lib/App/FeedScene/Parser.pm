package App::FeedScene::Parser;

use 5.12.0;
use utf8;
use Data::Feed;
use Data::Feed::Parser::Atom;
use Data::Feed::Parser::RSS;
use XML::LibXML qw(XML_TEXT_NODE);
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

sub parse_feed {
    my ($self, $res) = @_;

    # XML is always binary, so don't use decoded_content.
    # http://juerd.nl/site.plp/perluniadvice
    my $body = $res->content;
    $parser->recover(0);
    local $@;
    TRY: {
        my $feed = eval { Data::Feed->parse(\$body) };
        if (my $err = $@) {
            given ($err->code) {
                when (XML::LibXML::ErrNo::ERR_INVALID_CHAR) {
                    # See if we can clean up the mess.
                    my $charset = $res->content_charset;
                    $body = encode($charset, decode($charset, $body));
                    redo TRY;
                }
                when (XML::LibXML::ErrNo::ERR_UNDECLARED_ENTITY) {
                    # Author included invalid entities. Convert them and try again.
                    my $charset = $res->content_charset;
                    $body = encode($charset, decode_entities(decode($charset, $body)));
                    redo TRY;
                }
                default {
                    die $err;
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
        $ret .= $elem->nodeType == XML_TEXT_NODE
            ? $elem->data
            : _strip($elem->childNodes);
    }
    return $ret;
}

1;

=head1 Name

App::FeedScene::Parser - FeedScene feed parser tools

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

package App::FeedScene::Parser;

use 5.12.0;
use utf8;
use Data::Feed;
use Data::Feed::Parser::Atom;
use Data::Feed::Parser::RSS;
use XML::LibXML;
#use HTML::Tidy;

$XML::Atom::ForceUnicode = 1;
$Data::Feed::Parser::RSS::PARSER_CLASS = 'App::FeedScene::Parser::RSS';

my $libxml_options = {
    recover    => 2,
    no_network => 1,
    no_blanks  => 1,
    encoding   => 'utf8',
    no_cdata   => 1,
};

my $parser = XML::LibXML->new($libxml_options);

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
sub parse { shift; Data::Feed->parse(@_); }

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

RSSPARSER: {
    package App::FeedScene::Parser::RSS;
    use parent 'XML::RSS::LibXML';
    sub create_libxml { $parser }
}

1;

=head1 Name

App::FeedScene::Parser - FeedScene feed parser tools

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

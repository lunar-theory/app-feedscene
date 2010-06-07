package App::FeedScene::Parser;

use 5.12.0;
use utf8;
use Data::Feed;
use Data::Feed::Parser::Atom;
use Data::Feed::Parser::RSS;
use XML::LibXML;

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

sub libxml { $parser }
sub parse { shift; Data::Feed->parse(@_); }

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

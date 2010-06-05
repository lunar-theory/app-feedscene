package App::FeedScene::Generator 0.01;

use 5.12.0;
use utf8;
use XML::Builder;
use App::FeedScene;
use DateTime;
use Moose;
use File::Spec;
use File::Path;

(my $def_dir = __FILE__) =~ s{(?:blib/)?lib/App/FeedScene/Generator[.]pm$}{feeds};
has app => (is => 'rw', isa => 'Str', required => 1 );
has dir => (is => 'rw', isa => 'Str', default => $def_dir );

no Moose;

sub go {
    my $self = shift;
    my $xb   = XML::Builder->new(encoding => 'utf-8');
    my $a    = $xb->ns( 'http://www.w3.org/2005/Atom' => '' );
    my $now  = DateTime->now;
    my $app  = $self->app;
    my $path = $self->filepath;
    my $url  = 'http://lunary-theory.com/feeds/' . $self->filename;

    File::Path::make_path($self->dir);
    open my $fh, '>', $path or die qq{Cannot open "$path": $!\n};

    print {$fh} $xb->document(
        $a->feed(
            $a->title("$app Feed"),
            $a->updated( $now->iso8601 . 'Z' ),
            $a->id($url),
            $a->link({
                rel  => 'self',
                type => 'application/atom+xml',
                href => $url,
            }),
            $a->rights( '© ', $now->year, ' Lunar Theory and others' ),
            $a->generator(
                { uri => 'http://lunar-theory.com/feedscene/', version => '1.0' },
                'FeedScene'
            ),
            $a->author(
                $a->name('Lunar Theory'),
                $a->uri('http://lunar-theory.com/')
            ),
        )
    );
    close $fh or die qq{Canot close "$path": $!\n};
}

sub filename {
    shift->app . '.xml'
}

sub filepath {
    my $self = shift;
    File::Spec->catfile($self->dir, $self->filename);
}

1;

=head1 Name

App::FeedScene::Generator - FeedScene feed generator

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

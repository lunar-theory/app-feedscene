package App::FeedScene::Generator 0.01;

use 5.12.0;
use utf8;
use XML::Builder;
use App::FeedScene;
use DateTime;
use Moose;
use File::Spec;
use File::Path;

my $domain  = 'kineticode.com';
my $company = 'Lunar Theory';

(my $def_dir = __FILE__) =~ s{(?:blib/)?lib/App/FeedScene/Generator[.]pm$}{feeds};
has app => (is => 'rw', isa => 'Str',  required => 1 );
has dir => (is => 'rw', isa => 'Str',  default => $def_dir );
has strict => (is => 'rw', isa => 'Bool', default => 0 );

no Moose;

sub go {
    my $self = shift;
    my $xb   = XML::Builder->new(encoding => 'utf-8');
    my $a    = $xb->ns('http://www.w3.org/2005/Atom' => '');
    my $now  = DateTime->now;
    my $app  = $self->app;
    my $path = $self->filepath;
    my $conn = App::FeedScene->new($self->app)->conn;
    my $fs;

    File::Path::make_path($self->dir);
    open my $fh, '>', $path or die qq{Cannot open "$path": $!\n};

    # Assemble sources.
    my ($sources, @entries);
    if ($self->strict) {
        $sources = '';
    } else {
        my $fsxb = XML::Builder->new(encoding => 'utf-8');
        $fs = $fsxb->ns("http://$domain/2010/FeedScene" => '');
        my @sources;
        $conn->run(sub {
            # Get together sources.
            my $sth = shift->prepare(q{
                SELECT url, title, rights, icon_url
                  FROM feeds
                 ORDER BY portal, url
            });
            $sth->execute;
            $sth->bind_columns(\my ($url, $title, $rights, $icon_url));
            while ($sth->fetch) {
                push @sources, $fs->source(
                    $fs->id($url),
                    $fs->link({rel  => 'self', href => $url }),
                    $fs->title($title),
                    $fs->rights($rights),
                    $fs->icon($icon_url)
                );
            }
            $sources = $fsxb->root($fs->sources(@sources));
        });
    }

    print {$fh} $xb->document(
        $a->feed(
            $a->title("$app Feed"),
            $a->updated($now->iso8601 . 'Z'),
            $a->id($self->id),
            $a->link({
                rel  => 'self',
                type => 'application/atom+xml',
                href => $self->link,
            }),
            $a->rights('© ', $now->year, " $company and others"),
            $a->generator({
                uri => "http://$domain/feedscene/",
                version => App::FeedScene->VERSION,
            }, 'FeedScene' ),
            $a->author(
                $a->name($company),
                $a->uri("http://$domain/")
            ),
            $sources,
            @entries,
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

sub link {
    "http://$domain/feeds/" . shift->filename;
}

sub id {
    "tag:$domain,2010:feedscene/feeds/" . shift->filename;
}

1;

=head1 Name

App::FeedScene::Generator - FeedScene feed generator

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

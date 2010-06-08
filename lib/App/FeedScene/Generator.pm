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
    my ($sources, $feed_cols);
    if ($self->strict) {
        $sources   = '';
        $feed_cols = ', feed_url, feed_title, feed_subtitle, site_url, icon_url, rights';
    } else {
        $feed_cols = '';
        my $fsxb   = XML::Builder->new(encoding => 'utf-8');
        $fs        = $fsxb->ns("http://$domain/2010/FeedScene" => '');
        my @sources;
        $conn->run(sub {
            # Get together sources.
            my $sth = shift->prepare(q{
                SELECT id, url, title, subtitle, rights, icon_url
                  FROM feeds
                 ORDER BY portal, url
            });
            $sth->execute;
            $sth->bind_columns(\my ($id, $url, $title, $subtitle, $rights, $icon_url));
            while ($sth->fetch) {
                push @sources, $fs->source(
                    $fs->id($id),
                    $fs->link({rel => 'self', href => $url }),
                    $fs->title($title),
                    $fs->subtitle($subtitle),
                    $fs->rights($rights),
                    $fs->icon($icon_url)
                );
            }
            $sources = $fsxb->root($fs->sources(@sources));
        });
    }

    # Assemble the entries.
    my @entries;
    $conn->run(sub {
        my $sth = shift->prepare(qq{
            SELECT id, url, title, published_at, updated_at, summary, author,
                   enclosure_url, enclosure_type, feed_id, portal$feed_cols
              FROM feed_entries
             ORDER BY portal, published_at DESC
        });
        $sth->execute;
        while (my $row = $sth->fetchrow_hashref) {
            push @entries, $a->entry(
                $a->id($row->{id}),
                $a->link({rel => 'alternate', href => $row->{url} }),
                $a->title($row->{title}),
                $a->published($row->{published_at}),
                $a->updated($row->{updated_at}),
                $a->category({
                    scheme => "http://$domain/ns/portal",
                    term => $row->{portal},
                }),
                $a->summary({ type => 'html' }, $row->{summary} ),
                ($row->{author} ? ($a->author( $a->name($row->{author}) )) : ()),
                $a->source(
                    $a->id($row->{feed_id}),
                    $self->strict ? (
                        $a->link({ rel => 'self', href => $row->{feed_url} }),
                        $a->title($row->{feed_title}),
                        $a->subtitle($row->{feed_subtitle}),
                        $a->rights($row->{rights}),
                        $a->icon($row->{icon_url}),
                    ) : (),
                ),
                ($row->{enclosure_url} ? (
                    $a->link({
                        rel => 'enclosure',
                        type => $row->{enclosure_type},
                        href => $row->{enclosure_url},
                    })
                ) : ()),
            );
        }
    });

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

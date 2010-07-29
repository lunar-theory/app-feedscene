package App::FeedScene::Generator 0.06;

use 5.12.0;
use utf8;
use namespace::autoclean;
use XML::Builder;
use App::FeedScene;
use DateTime;
use Moose;
use File::Spec;
use File::Path;

my $domain  = 'kineticode.com';
my $company = 'Lunar Theory';

(my $def_dir = __FILE__) =~ s{(?:blib/)?lib/App/FeedScene/Generator[.]pm$}{feeds};
has app        => (is => 'rw', isa => 'Str',  required => 1 );
has dir        => (is => 'rw', isa => 'Str',  default => $def_dir );
has strict     => (is => 'rw', isa => 'Bool', default => 0 );
has limit      => (is => 'rw', isa => 'Int',  default => 36 );
has text_limit => (is => 'rw', isa => 'Int',  default => 256 );

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
        $feed_cols = ', feed_url, feed_title, feed_subtitle, site_url'
                   . ', icon_url, feed_updated_at, rights';
    } else {
        $feed_cols = '';
        my $fsxb   = XML::Builder->new(encoding => 'utf-8');
        $fs        = $fsxb->ns("http://$domain/2010/FeedScene" => '');
        $conn->run(sub {
            # Get together sources.
            my $sth = shift->prepare(q{
                SELECT id, url, title, subtitle, rights, updated_at, site_url,
                       icon_url, portal
                  FROM feeds
                 ORDER BY portal, url
            });
            $sth->execute;
            my @sources;
            while (my $row = $sth->fetchrow_hashref) {
                push @sources, $fs->source(
                    $fs->id($row->{id}),
                    $fs->link({rel => 'self',      href => $row->{url} }),
                    ($row->{site_url} ? ($fs->link({rel => 'alternate', href => $row->{site_url} })) : ()),
                    $fs->title($row->{title} || $row->{url}),
                    ($row->{subtitle} ? ($fs->subtitle($row->{subtitle})) : ()),
                    $fs->updated($row->{updated_at}),
                    ($row->{rights} ? ($fs->rights($row->{rights})) : ()),
                    $fs->icon($row->{icon_url}),
                    $fs->category({
                        scheme => "http://$domain/ns/portal",
                        term => $row->{portal},
                    }),
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
             WHERE portal = ?
             ORDER BY published_at DESC
             LIMIT ?
        });

        for my $portal (0..6) {
            $sth->execute($portal, $portal ? $self->limit : $self->text_limit);
            while (my $row = $sth->fetchrow_hashref) {
                push @entries, $a->entry(
                    $a->id($row->{id}),
                    $a->link({rel => 'alternate', href => $row->{url} }),
                    $a->title($row->{title} || $row->{url}),
                    $a->published($row->{published_at}),
                    $a->updated($row->{updated_at}),
                    ($row->{summary} ? ($a->summary({ type => 'html' }, $row->{summary} )) : ()),
                    ($row->{author} ? ($a->author( $a->name($row->{author}) )) : ()),
                    $a->source(
                        $a->id($row->{feed_id}),
                        $self->strict ? (
                            $a->link({ rel => 'self', href => $row->{feed_url} }),
                            ($row->{site_url} ? ($a->link({rel => 'alternate', href => $row->{site_url} })) : ()),
                            $a->title($row->{feed_title} || $row->{feed_url}),
                            ($row->{feed_subtitle} ? ($a->subtitle($row->{feed_subtitle})) : ()),
                            $a->updated($row->{feed_updated_at}),
                            ($row->{rights} ? ($a->rights($row->{rights})) : ()),
                            $a->icon($row->{icon_url}),
                            $a->category({
                                scheme => "http://$domain/ns/portal",
                                term => $row->{portal},
                            }),
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
                uri     => "http://$domain/feedscene/",
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

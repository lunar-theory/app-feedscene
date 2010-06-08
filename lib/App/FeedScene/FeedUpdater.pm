package App::FeedScene::FeedUpdater 0.01;

use 5.12.0;
use utf8;
use App::FeedScene;
use App::FeedScene::UA;
use App::FeedScene::Parser;
use Text::CSV_XS;
use HTTP::Status qw(HTTP_NOT_MODIFIED);
use Moose;

has app     => (is => 'rw', isa => 'Str');
has url     => (is => 'rw', isa => 'Str');
has ua      => (is => 'rw', isa => 'App::FeedScene::UA');
has verbose => (is => 'rw', isa => 'Bool');

no Moose;

sub run {
    my $self = shift;
    my $ua = $self->ua(App::FeedScene::UA->new($self->app));
    $ua->cache->clear;
    my $res = $ua->get($self->url);
    require Carp && Carp::croak($res->status_line)
        unless $res->is_success or $res->code == HTTP_NOT_MODIFIED;
    $self->process($res->decoded_content)
        unless $res->code == HTTP_NOT_MODIFIED;
}

sub process {
    my $self = shift;
    my @csv  = split /\r?\n/ => shift;
    my $csv  = Text::CSV_XS->new({ binary => 1 });
    my $ua   = $self->ua;
    shift @csv; # Remove headers.

    my $conn = App::FeedScene->new($self->app)->conn;
    my $sth = $conn->run(sub { use strict;
        my $upd = $_->prepare(q{
            UPDATE feeds
               SET url      = ?,
                   title    = ?,
                   subtitle = ?,
                   site_url = ?,
                   icon_url = ?,
                   rights   = ?,
                   portal   = ?,
                   category = ?
             WHERE id       = ?
        });

        my $ins = $_->prepare(q{
            INSERT INTO feeds (url, title, subtitle, site_url, icon_url,
                               rights, portal, category, id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        });

        my @ids;
        for my $line (@csv) {
            $csv->parse($line);
            my ($portal, $feed_url, $category) = $csv->fields;
            say STDERR "$portal: $feed_url" if $self->verbose;
            my $res = $ua->get($feed_url);
            require Carp && Carp::croak("Error retrieving $feed_url: " . $res->status_line)
                unless $res->is_success;

            $portal      = 0 if $portal eq 'text';
            my $feed     = App::FeedScene::Parser->parse(\$res->content);
                           # XXX Generate from URL?
            my $id       = $feed->can('id') ? $feed->id || $feed_url : $feed_url;
            my $site_url = $feed->link;
            $site_url    = $site_url->[0] if ref $site_url;
            $site_url    = $feed->base
                         ? URI->new_abs($site_url, $feed->base)
                         : URI->new($site_url);
            my $host     = $site_url ? $site_url->host : URI->new($feed_url)->host;

            my @params = (
                $feed_url,
                $feed->title,
                $feed->description || '',
                $site_url,
                "http://www.google.com/s2/favicons?domain=$host",
                $feed->copyright || '',
                $portal,
                $category || '',
                $id,
            );

            $ins->execute(@params) unless $upd->execute(@params) > 0;
            push @ids, $id;
        }

        # Remove old feeds.
        $_->do(
            'DELETE FROM feeds WHERE id NOT IN (' . join(', ', ('?') x @ids) . ')',
            undef, @ids
        ) if @ids;

    });
    return $self;
}

1;

=head1 Name

App::FeedScene::FeedUpdater - FeedScene feed updater

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

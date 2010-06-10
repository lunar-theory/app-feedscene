package App::FeedScene::FeedUpdater 0.01;

use 5.12.0;
use utf8;
use namespace::autoclean;
use App::FeedScene;
use App::FeedScene::UA;
use App::FeedScene::Parser;
use Text::CSV_XS;
use Text::Trim;
use HTTP::Status qw(HTTP_NOT_MODIFIED);
use Moose;

has app     => (is => 'rw', isa => 'Str');
has url     => (is => 'rw', isa => 'Str');
has ua      => (is => 'rw', isa => 'App::FeedScene::UA');
has verbose => (is => 'rw', isa => 'Bool');

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
    my $sth = $conn->run(sub {
        use strict;
        my $dbh = shift;
        my $sel = $dbh->prepare(q{SELECT id FROM feeds WHERE url = ?});

        my $upd = $dbh->prepare(q{
            UPDATE feeds
               SET portal   = ?,
                   category = ?
             WHERE id       = ?
        });

        my $ins = $dbh->prepare(q{
            INSERT INTO feeds (url, title, subtitle, site_url, icon_url,
                               updated_at, rights, portal, category, id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        });

        my @ids;
        for my $line (@csv) {
            $csv->parse($line);
            my ($portal, $feed_url, $category) = $csv->fields;
            $portal = 0 if $portal eq 'text';
            say STDERR "$portal: $feed_url" if $self->verbose;

            # Skip to the next entry if we've already got this URL.
            my ($id) = $dbh->selectrow_array($sel, undef, $feed_url);
            if ($id) {
                push @ids, $id;
                $upd->execute(trim $portal, $category || '', $id);
                next;
            }

            my $res = $ua->get($feed_url);
            require Carp && Carp::croak("Error retrieving $feed_url: " . $res->status_line)
                unless $res->is_success;

            my $feed     = App::FeedScene::Parser->parse_feed($res->decoded_content);
                           # XXX Generate from URL?
            $id          = $feed->can('id') ? $feed->id || $feed_url : $feed_url;
            my $site_url = $feed->link;
            $site_url    = $site_url->[0] if ref $site_url;
            $site_url    = $feed->base
                         ? URI->new_abs($site_url, $feed->base)
                         : URI->new($site_url);
            my $host     = $site_url ? $site_url->host : URI->new($feed_url)->host;

            $ins->execute(trim(
                $feed_url,
                $feed->title,
                $feed->description || '',
                $site_url,
                "http://www.google.com/s2/favicons?domain=$host",
                ($feed->modified || DateTime->now)->set_time_zone('UTC')->iso8601 . 'Z',
                $feed->copyright || '',
                $portal,
                $category || '',
                $id,
            ));

            push @ids, $id;
        }

        # Remove old feeds.
        $dbh->do(
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

package App::FeedScene::EntryUpdater 0.01;

use 5.12.0;
use utf8;
use App::FeedScene;
use App::FeedScene::UA::Robot;
use XML::Feed;
use HTTP::Status qw(HTTP_NOT_MODIFIED);
use XML::LibXML;
use Text::Markdown ();

use Class::XSAccessor constructor => 'new', accessors => { map { $_ => $_ } qw(
   app
   portal
) };

sub run {
    my $self = shift;

    my $ua  = App::FeedScene::UA::Robot->new($self->app);
    my $sth = App::FeedScene->new($self->app)->conn->run(sub {
        shift->prepare('SELECT url FROM feeds WHERE portal = ?');
    });
    $sth->execute($self->portal);
    $sth->bind_columns(\my $url);

    while ($sth->fetch) {
        my $res = $ua->get($url);
        require Carp && Carp::croak("Error retrieving $url: " . $res->status_line)
            unless $res->is_success or $res->code == HTTP_NOT_MODIFIED;
        $self->process($url, XML::Feed->parse(\$res->content))
            unless $res->code == HTTP_NOT_MODIFIED;
    }

    return $self;
}


sub process {
    my ($self, $feed_url, $feed) = @_;
    my $portal = $self->portal;

    App::FeedScene->new($self->app)->conn->txn(sub {
        my $dbh = shift;

        # Update the feed.
        $dbh->do(q{
            UPDATE feeds
               SET name     = ?,
                   site_url = ?
             WHERE url      = ?
        }, undef, $feed->title, $feed->link, $feed_url);

        # Get ready to update the entries.
        my $sth = $dbh->prepare(q{
            INSERT OR REPLACE INTO entries (
                id, portal, feed_url, url, title, published_at, updated_at,
                summary, author, enclosure_type, enclosure_url
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        });

        my @ids;
        for my $entry ($feed->entries) {
            my ($enc_type, $enc_url) = ('', '');
            if ($portal) {
                # Need some media for non-text portals.
                ($enc_type, $enc_url) = _find_enclosure($entry);
                next unless $enc_type;
            }

            $sth->execute(
                $entry->id,
                $portal,
                $feed_url,
                $entry->link,
                $entry->title,
                $entry->issued->iso8601,
                $entry->modified->iso8601,
                _find_summary($entry),
                $entry->author,
                $enc_type,
                $enc_url,
            );

            push @ids, $entry->id;
        }

        $dbh->do(
            'DELETE FROM entries WHERE id NOT IN ('. join (', ', ('?') x @ids) . ')',
            undef, @ids
        );
    });

    return $self;
}

sub _find_summary {
    my $entry = shift;
    if (my $sum = $entry->summary) {
        if (my $body = $sum->body) {
            # We got something here.
            return $body if !$sum->type || $sum->type ne 'text/plain';
            return Text::Markdown::markdown($body);
        }
    }

    # Use XML::LibXML to grab the first bit of the body, hopefully a
    # paragraph.
}

sub _find_enclosure {
    my $entry = shift;
    if (my ($enc) = $entry->enclosure) {
        return $enc->type, $enc->url;
    }

    # Try to find an image in the content.
    my $content = $entry->content;

    # Use XML::LibXML and XPath to find an img, video, or audio tag and link
    # it up.

    # Nothing to see.
    return '', '';
}

1;

=head1 Name

App::FeedScene::EntryUpdater - FeedScene entry updater

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

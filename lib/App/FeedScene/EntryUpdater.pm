package App::FeedScene::EntryUpdater 0.01;

use 5.12.0;
use utf8;
use App::FeedScene;
use App::FeedScene::UA::Robot;
use XML::Feed;
use HTTP::Status qw(HTTP_NOT_MODIFIED);
use XML::LibXML qw(XML_ELEMENT_NODE);
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
                ($entry->modified || $entry->issued)->iso8601,
                _find_summary($entry),
                $entry->author,
                $enc_type,
                $enc_url,
            );

            push @ids, $entry->id;
        }

        $dbh->do(q{
            DELETE FROM entries
             WHERE feed_url = ?
               AND id NOT IN (}. join (', ', ('?') x @ids) . ')',
            undef, $feed_url, @ids
        );
    });

    return $self;
}

# http://www.w3schools.com/tags/default.asp
# http://dev.w3.org/html5/html4-differences/#new-elements
my %allowed = map { $_ => 1 } qw(
    em
    strong
    i
    b
    abbr
    acronym
    address
    p
    br
    cite
    code
    pre
    del
    dfn
    div
    ins
    kbd
    ol
    ul
    li
    dl
    dt
    dd
    q
    s
    samp
    strike
    tt
    u
    var
    xmp
    section
    article
    figure
    figcaption
    mark
    meter
    time
    output
    details
    summary
);

sub _clean_html {
    my $top = my $elem = shift;
    while ($elem) {
        if ($elem->nodeType == XML_ELEMENT_NODE) {
            my $name = $elem->nodeName;
            if ($name eq 'html') {
                $top = $elem = $elem->lastChild;
                next;
            }

            if ($allowed{$name}) {
                # Delete all of its attributes and hang on to it.
                $elem->removeAttribute($_) for $elem->attributes;

                # Descend into children.
                if (my $next = $elem->firstChild) {
                    $elem = $next;
                    next;
                }
            } else {
                # You are not wanted, but we'll take your text.
                my $parent = $elem->parentNode or die "Expecting parent of $elem";
                $parent->replaceChild(
                    XML::LibXML::Text->new( $elem->textContent ),
                    $elem,
                );
            }
        }

        # Find the next node.
        NEXT: {
            if (my $sib = $elem->nextSibling) {
                $elem = $sib;
                last;
            }

            # No sibling, try parent's sibling
            $elem = $elem->parentNode;
            redo if $elem;
        }
    }
    return join '', map { $_->toString } $top->childNodes;
}

sub _find_summary {
    my $entry = shift;
    if (my $sum = $entry->summary) {
        if (my $body = $sum->body) {
            # We got something here. Clean it up and return it.
            return _clean_html(XML::LibXML->new->parse_html_string(
                $sum->type && $sum->type eq 'text/plain'
                    ? Text::Markdown::markdown($body)
                    : $body
            )->firstChild);
        }
    }

    # Try the body of the entry.
    my $content = $entry->content or return '';

    # Parse it.
    my $doc = XML::LibXML->new->parse_html_string(
        $content->type && $content->type eq 'text/plain'
            ? Text::Mardown::markdown($content->body)
            : $content->body
    );

    # Fetch a reasonable amount of the content to use as a summary.
    my $ret = '';
    for my $elem ($doc->childNodes) {
        if ($elem->isa('XML::LibXML::Text')) {
            # Turn it into a paragraph.
            my $p = XML::LibXML::Element->new('p');
            $p->addChild($elem);
            $ret .= $p->toString;
        } elsif ($elem->isa('XML::LibXML::Element')) {
            # Clean the HTML.
            $ret .= _clean_html($elem);
        }
        return $ret if length $ret > 140;
    }
    return $ret;
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

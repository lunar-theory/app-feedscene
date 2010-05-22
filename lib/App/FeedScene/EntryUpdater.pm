package App::FeedScene::EntryUpdater 0.01;

use 5.12.0;
use utf8;
use App::FeedScene;
use App::FeedScene::UA::Robot;
use XML::Feed;
use HTTP::Status qw(HTTP_NOT_MODIFIED);
use XML::LibXML qw(XML_ELEMENT_NODE XML_TEXT_NODE);

use Class::XSAccessor constructor => 'new', accessors => { map { $_ => $_ } qw(
   app
   portal
) };

my $parser = XML::LibXML->new({
    recover           => 2,
    no_network        => 1,
    suppress_errors   => 1,
    suppress_warnings => 1,
    no_blanks         => 1,
    encoding          => 'utf8',
});


$XML::Feed::RSS::PREFERRED_PARSER = 'XML::RSS::LibXML';
$XML::Feed::MULTIPLE_ENCLOSURES = 1;
$XML::Atom::ForceUnicode = 1;

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

            my $pub_date = $entry->issued;
            my $upd_date = $entry->modified || $pub_date or next;
            $pub_date ||= $upd_date;

            $sth->execute(
                $entry->id,
                $portal,
                $feed_url,
                $entry->link,
                $entry->title,
                $pub_date->set_time_zone('UTC')->iso8601 . 'Z',
                $upd_date->set_time_zone('UTC')->iso8601 . 'Z',
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

# List of allowed elements and attributes.
# http://www.w3schools.com/tags/default.asp
# http://www.w3schools.com/html5/html5_reference.asp
my %allowed = do {
    my $attrs = { title => 1, dir => 1, lang => 1 };
    map { $_ => $attrs } qw(
        abbr
        acronym
        address
        article
        b
        bdo
        big
        br
        caption
        cite
        code
        dd
        del
        details
        dfn
        div
        dl
        dt
        em
        figcaption
        figure
        header
        hgroup
        i
        ins
        kbd
        li
        mark
        meter
        ol
        p
        pre
        q
        rp
        rt
        ruby
        s
        samp
        section
        small
        span
        strike
        strong
        sub
        summary
        sup
        time
        tt
        u
        ul
        var
        xmp
    );
};

# Allow some elements may have other attributes.
$allowed{article} = { %{ $allowed{article} }, cite => 1, pubdate  => 1 };
$allowed{del}     = { %{ $allowed{del} },     cite => 1, datetime => 1 };
$allowed{details} = { %{ $allowed{details} }, open => 1 };
$allowed{ins}     = $allowed{del};
$allowed{li}      = { %{ $allowed{li} }, value => 1 };
$allowed{meter}   = { %{ $allowed{meter} }, map { $_ => 1 } qw(high low min max optimum value) };
$allowed{ol}      = { %{ $allowed{ol} }, revese => 1, start => 1 };
$allowed{q}       = { %{ $allowed{q} }, cite => 1 };
$allowed{section} = $allowed{q};
$allowed{time}    = { %{ $allowed{time} }, datetime => 1 };

# We delete all other elements except for these, for which we keep text.
my %keep_children = map { $_ => 1 } qw(
    a
    blink
    center
    font
);

sub _clean_html {
    my $top = my $elem = shift;
    while ($elem) {
        if ($elem->nodeType == XML_ELEMENT_NODE) {
            my $name = $elem->nodeName;
            if ($name eq 'html') {
                $top = $elem = $elem->lastChild || last;
                next;
            } elsif ($name eq 'body') {
                $elem = $elem->firstChild || last;
                next;
            }

            if (my $attrs = $allowed{$name}) {
                # Delete all of its attributes and hang on to it.
                $elem->removeAttribute($_) for grep { !$attrs->{$_} }
                    map { $_->nodeName } $elem->attributes;

                # Descend into children.
                if (my $next = $elem->firstChild) {
                    $elem = $next;
                    next;
                }
            } else {
                # You are not wanted.
                my $parent = $elem->parentNode;
                if ($keep_children{$name}) {
                    # Keep the children.
                    $parent->insertAfter($_, $elem) for reverse $elem->childNodes;
                    $parent->removeChild($elem);
                    # 
                    $elem = $elem->nextSibling;
                    next;
                }

                # Buh-bye.
                $parent->removeChild($elem);
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
    return $top;
}

sub _find_summary {
    my $entry = shift;
    if (my $sum = $entry->summary) {
        if (my $body = $sum->body) {
            # We got something here. Clean it up and return it.
            return join '', map { $_->toString } _clean_html(
                $parser->parse_html_string($body)->firstChild
            )->childNodes;
        }
    }

    # Try the content of the entry.
    my $content = $entry->content or return '';
    my $body    = $content->body  or return '';
    my $doc     = $parser->parse_html_string($body);

    # Fetch a reasonable amount of the content to use as a summary.
    my $ret = '';
    for my $elem ($doc->findnodes('/html/body')->get_node(1)->childNodes) {
        if ($elem->nodeType == XML_ELEMENT_NODE) {
            # Clean the HTML.
            $ret .= _clean_html($elem)->toString;
            return $ret if length $ret > 140;
        }
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

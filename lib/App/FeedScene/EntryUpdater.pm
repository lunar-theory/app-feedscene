package App::FeedScene::EntryUpdater 0.01;

use 5.12.0;
use utf8;
use App::FeedScene;
use App::FeedScene::UA;
use App::FeedScene::Parser;
use HTTP::Status qw(HTTP_NOT_MODIFIED);
use XML::LibXML qw(XML_ELEMENT_NODE XML_TEXT_NODE);
use OSSP::uuid;
use MIME::Types;
use URI;

use Moose;

has app     => (is => 'rw', isa => 'Str');
has portal  => (is => 'rw', isa => 'Int');
has ua      => (is => 'rw', isa => 'App::FeedScene::UA');
has verbose => (is => 'rw', isa => 'Int');

no Moose;

sub run {
    my $self = shift;
    say "Updating ", $self->app, ' portal ', $self->portal
        if $self->verbose;

    $self->ua(App::FeedScene::UA->new($self->app));
    my $sth = App::FeedScene->new($self->app)->conn->run(sub {
        shift->prepare('SELECT url FROM feeds WHERE portal = ?');
    });
    $sth->execute($self->portal);
    $sth->bind_columns(\my $url);

    while ($sth->fetch) {
        $self->process($url);
    }

    return $self;
}

sub process {
    my ($self, $feed_url) = @_;
    my $portal = $self->portal;
    say "  Processing $feed_url" if $self->verbose;

    my $res = $self->ua->get($feed_url);
    require Carp && Carp::croak("Error retrieving $feed_url: " . $res->status_line)
        unless $res->is_success or $res->code == HTTP_NOT_MODIFIED;
    return $self if $res->code == HTTP_NOT_MODIFIED;

    my $feed     = App::FeedScene::Parser->parse_feed($res->decoded_content);
    my $feed_id  = $feed->can('id') ? $feed->id || $feed_url : $feed_url;
    my $base_url = $feed->base;
    my $site_url = $feed->link;
    $site_url    = $site_url->[0] if ref $site_url;
    $site_url    = $base_url
                 ? URI->new_abs($site_url, $base_url)
                 : URI->new($site_url);
    my $host     = $site_url ? $site_url->host : URI->new($feed_url)->host;
    $base_url  ||= $site_url;

    # XXX Modify to update entries only if the update time has changed?
    App::FeedScene->new($self->app)->conn->txn(sub {
        use strict;
        my $dbh = shift;

        # Update the feed.
        $dbh->do(
            q{
                UPDATE feeds
                   SET id         = ?,
                       title      = ?,
                       subtitle   = ?,
                       site_url   = ?,
                       icon_url   = ?,
                       updated_at = ?,
                       rights     = ?
                 WHERE url        = ?
            },
            undef,
            $feed_id,
            $feed->title,
            $feed->description || '',
            $site_url,
            "http://www.google.com/s2/favicons?domain=$host",
            ($feed->modified || DateTime->now)->set_time_zone('UTC')->iso8601 . 'Z',
            $feed->copyright || '',
            $feed_url
        );

        # Get ready to update the entries.
        my $sth = $dbh->prepare(q{
            INSERT OR REPLACE INTO entries (
                id, feed_id, url, title, published_at, updated_at,
                summary, author, enclosure_type, enclosure_url
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        });

        my @ids;
        my $be_verbose = ($self->verbose || 0) > 1;
        for my $entry ($feed->entries) {
            say '    ', $entry->link if $be_verbose;
            my $entry_link = $base_url
                ? URI->new_abs($entry->link, $base_url)
                : URI->new($entry->link);
            my ($enc_type, $enc_url) = ('', '');

            if ($portal) {
                # Need some media for non-text portals.
                ($enc_type, $enc_url) = $self->_find_enclosure($entry, $entry_link);
                next unless $enc_type;
            }

            my $pub_date = $entry->issued;
            my $upd_date = $entry->modified || $pub_date or next;
            $pub_date ||= $upd_date;
            my $uuid = _uuid($site_url, $entry_link);

            $sth->execute(
                $uuid,
                $feed_id,
                $entry_link,
                $entry->title,
                $pub_date->set_time_zone('UTC')->iso8601 . 'Z',
                $upd_date->set_time_zone('UTC')->iso8601 . 'Z',
                _find_summary($entry),
                $entry->author,
                $enc_type,
                $enc_url,
            );

            push @ids, $uuid;
        }

        $dbh->do(q{
            DELETE FROM entries
             WHERE feed_id = ?
               AND id NOT IN (}. join (', ', ('?') x @ids) . ')',
            undef, $feed_id, @ids
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

# A few elements may retain other attributes.
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
                # Keep only allowed attributes.
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
                }

                # Take it out jump to the next sibling.
                my $next = $elem;
                NEXT: {
                    if (my $sib = $next->nextSibling) {
                        $next = $sib;
                        last;
                    }

                    # No sibling, try parent's sibling
                    $next = $next->parentNode;
                    redo if $next && $next ne $top;
                }
                $parent->removeChild($elem);
                $elem = $next;
                next;
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
            # XXX Add `URI => $base_url` parser option?
            return join '', map {
                $_->hasChildNodes || $_->hasAttributes ? $_->toString : ' '
            } _clean_html(
                App::FeedScene::Parser->parse_html_string($body)->firstChild
            )->childNodes;
        }
    }

    # Try the content of the entry.
    my $content = $entry->content or return '';
    my $body    = $content->body  or return '';
    my $doc     = App::FeedScene::Parser->parse_html_string($body);

    # Fetch a reasonable amount of the content to use as a summary.
    my $ret = '';
    my @nodes = map {
        # If it's an unwanted node but we want its children, keep them.
        $keep_children{$_->nodeName} ? $_->childNodes : $_
    } $doc->findnodes('/html/body')->get_node(1)->childNodes;

    while (@nodes) {
        my $elem = shift @nodes;
        if ($elem->nodeType == XML_TEXT_NODE) {
            $ret .= $elem->toString if $elem->toString =~ /\S/;
            next;
        }
        next if $elem->nodeType != XML_ELEMENT_NODE or !$allowed{$elem->nodeName};

        # Clean the HTML.
        $elem = _clean_html($elem);
        $ret .= $elem->toString if $elem->hasChildNodes || $elem->hasAttributes;
        return $ret if length $ret > 140;
    }
    return $ret;
}


sub _find_enclosure {
    my ($self, $entry, $entry_link) = @_;
    for my $enc ($entry->enclosures) {
        my $type = $enc->type or next;
        next if $type !~ m{^(?:image|audio|video)/};
        return $enc->type, $enc->url;
    }

    # Use XML::LibXML and XPath to find something and link it up.
    for my $content ($entry->content, $entry->summary) {
        next unless $content;
        my $body = $content->body or next;
        my $doc = App::FeedScene::Parser->parse_html_string($body) or next;
        for my $node ($doc->findnodes('//img/@src|//audio/@src|//video/@src')) {
            my $url = $node->nodeValue or next;
            (my($type), $url) = $self->_get_type($url) or next;
            return $type, $url if $type =~ m{^(?:image|audio|video)/};
        }
    }

    # Look at the direct link.
    my ($type, $url) = $self->_get_type($entry_link);
    return $type, $url if $type && $type =~ m{^(?:image|audio|video)/};

    # Nothing to see.
    return;
}

my $uuid_gen = OSSP::uuid->new;
my $uuid_ns  = OSSP::uuid->new;

sub _uuid {
    my ($site_url, $entry_url) = @_;
    $uuid_ns->load('ns:URL');
    $uuid_gen->make('v5', $uuid_ns, $site_url); # Make UUID for site URL.
    $uuid_gen->make('v5', $uuid_gen, $entry_url); # Make UUID for site + entry URLs.
    return 'urn:uuid:' . $uuid_gen->export('str');
}

my $mt = MIME::Types->new;
sub _get_type {
    my ($self, $url) = @_;
    if (my $type = $mt->mimeTypeOf($url)) {
        return $type, $url;
    }

    # Maybe the thing redirects? Ask it for its content type.
    my $res = $self->ua->head($url);
    return $res->is_success ? (scalar $res->content_type, $res->request->uri) : undef;
}

1;

=head1 Name

App::FeedScene::EntryUpdater - FeedScene entry updater

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

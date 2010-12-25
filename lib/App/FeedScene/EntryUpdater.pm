package App::FeedScene::EntryUpdater 0.28;

use 5.12.0;
use utf8;
use namespace::autoclean;
use App::FeedScene;
use App::FeedScene::UA;
use aliased 'App::FeedScene::Parser';
use Encode::ZapCP1252;
use HTTP::Status qw(HTTP_NOT_MODIFIED);
use XML::LibXML qw(XML_ELEMENT_NODE XML_TEXT_NODE);
use OSSP::uuid;
use MIME::Types;
use Text::Trim;
use URI;
use constant ERR_THRESHOLD => 4; # Start conservative.
use constant ERR_INTERVAL  => 5;

use Moose;

has app     => (is => 'rw', isa => 'Str');
has portal  => (is => 'rw', isa => 'Int');
has ua      => (is => 'rw', isa => 'App::FeedScene::UA');
has icon    => (is => 'rw', isa => 'Str', default => 'none');
has eurls   => (is => 'rw', isa => 'HashRef' );
has eids    => (is => 'rw', isa => 'HashRef' );
has eusers  => (is => 'rw', isa => 'HashRef' );
has verbose => (is => 'rw', isa => 'Int', default => 0);

sub _clean {
    trim map { fix_cp1252 $_ if $_; $_ } @_;
}

sub run {
    my $self = shift;
    say STDERR "Updating ", $self->app, ' portal ', $self->portal
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
    say STDERR "  Processing $feed_url" if $self->verbose;
    $feed_url = URI->new($feed_url)->canonical;

    my $conn = App::FeedScene->new($self->app)->conn;
    my $res  = $self->ua->get($feed_url);

    # Handle errors.
    if (!$res->is_success || !Parser->isa_feed($res)) {
        if ($res->code == HTTP_NOT_MODIFIED) {
            say STDERR "    No change to $feed_url" if $self->verbose > 1;
            # No error. Reset the fail count.
            $conn->run(sub {
                $_->do(q{
                    UPDATE feeds
                       SET fail_count = 0
                     WHERE url = ?
                       AND fail_count <> 0
                }, undef, $feed_url);
            });
        } else {
            say STDERR "    Error retrieving $feed_url: ", $res->status_line
                 if $self->verbose > 1;
            $conn->txn(sub {
                $_->do(q{
                    UPDATE feeds
                       SET fail_count = fail_count + 1
                     WHERE url = ?
                }, undef, $feed_url);
                my ($count) = $_->selectrow_array(q{
                    SELECT fail_count
                      FROM feeds
                     WHERE url = ?
                }, undef, $feed_url);
                if ($count >= ERR_THRESHOLD && !($count % ERR_INTERVAL)) {
                    say STDERR "Error #$count retrieving $feed_url -- ",
                        $res->is_success
                            ? "406 Not acceptable: " . $res->content_type
                            : $res->status_line;
                }
            });
        }

        # Nothing more to do.
        return $self;
    }

    my $feed     = Parser->parse_feed($res) or return $self;
    my $feed_id  = $feed->can('id') ? $feed->id || $feed_url : $feed_url;
    my $base_url = $feed->base;
    my $site_url = $feed->link;
    $site_url    = $site_url->[0] if ref $site_url;
    $site_url    = $base_url
                 ? URI->new_abs($site_url, $base_url)->canonical
                 : URI->new($site_url)->canonical;
    my $host     = $site_url ? $site_url->host : $feed_url->host;
    $base_url  ||= $site_url;
    $self->eurls({});
    $self->eids({});
    $self->eusers({});

    # Iterate over the entries;
    my (@ids, @entries);
    my $be_verbose = ($self->verbose || 0) > 1;
    $conn->run(sub {
        my $dbh = shift;

        say STDERR "    Prepare udpated_at query" if $self->verbose > 1;
        my $sth = $dbh->prepare(q{
            SELECT updated_at >= ?
              FROM entries
             WHERE id = ?
        });

        for my $entry ($feed->entries) {
            say STDERR '    ', $entry->link if $be_verbose;

            my ($entry_link, $via_link);
            my ($link) = $entry->extract_node_values('origLink', 'feedburner');
            if ($link) {
                if ($base_url) {
                    $entry_link = URI->new_abs($link, $base_url)->canonical;
                    $via_link   = URI->new_abs($entry->link, $base_url)->canonical;
                } else {
                    $entry_link = URI->new($link)->canonical;
                    $via_link   = URI->new($entry->link)->canonical;
                }
                $via_link = '' if $via_link->eq($entry_link);
            } else {
                $via_link = '';
                $entry_link = $base_url
                    ? URI->new_abs($entry->link, $base_url)->canonical
                    : URI->new($entry->link)->canonical;
            }

            my $enc;

            if ($portal) {
                # Need some media for non-text portals.
                $enc = $self->_find_enclosure($entry, $base_url, $entry_link) or next;
                $self->eurls->{$enc->{url}}   = 1;
                $self->eids->{$enc->{id}}     = 1 if $enc->{id};
                $self->eusers->{$enc->{user}} = 1 if $enc->{user};
            }

            my $pub_date = $entry->issued;
            my $upd_date = $entry->modified;
            next unless $pub_date || $upd_date;
            my $uuid     = _uuid($site_url, $entry_link);
            $upd_date    = $upd_date->set_time_zone('UTC')->iso8601 . 'Z' if $upd_date;
            $pub_date    = $pub_date
                ? $pub_date->set_time_zone('UTC')->iso8601 . 'Z'
                : $upd_date;
            push @ids => $uuid;

            my $up_to_date;
            if ($upd_date) {
                # See if we've been updated.
                ($up_to_date) = $dbh->selectrow_array( $sth, undef, $upd_date, $uuid);
                # Nothing to do if it's up-to-date.
                next if $up_to_date;
            }

            # Gather params.
            push @entries, [$upd_date, $up_to_date, _clean(
                $feed_id,
                $entry_link,
                $via_link,
                Parser->strip_html($entry->title || ''),
                $pub_date,
                $upd_date || $pub_date,
                _find_summary($entry), # XXX Use enclosure description here.
                Parser->strip_html($entry->author || ''),
                $enc->{type} || '',
                $enc->{url},
                $enc->{id},
                $enc->{user},
                $uuid,
            )];
        }
    });

    say STDERR "    ", scalar time, ": Starting transction" if $self->verbose > 1;
    $conn->txn(sub {
        my $dbh = shift;

        # Update the feed.
        say STDERR "       Updating feed" if $self->verbose > 1;
        $dbh->do(
            q{
                UPDATE feeds
                   SET id         = ?,
                       title      = ?,
                       subtitle   = ?,
                       site_url   = ?,
                       icon_url   = ?,
                       updated_at = ?,
                       rights     = ?,
                       fail_count = ?
                 WHERE url        = ?
            },
            _clean(
                undef,
                $feed_id,
                Parser->strip_html($feed->title || ''),
                Parser->strip_html($feed->description || ''),
                $site_url,
                URI->new(sprintf(
                    'http://getfavicon.appspot.com/%s?defaulticon=%s',
                    $site_url || $feed_url, $self->icon
                ))->canonical,
                ($feed->modified || DateTime->now)->set_time_zone('UTC')->iso8601 . 'Z',
                Parser->strip_html($feed->copyright || ''),
                0,
                $feed_url
            )
        );

        # Get ready to update the entries.
        say STDERR "       Preparing INSERT statement" if $self->verbose > 1;
        my $ins = $dbh->prepare(q{
            INSERT INTO entries (
                feed_id, url, via_url, title, published_at, updated_at, summary,
                author, enclosure_type, enclosure_url, enclosure_id,
                enclosure_user, id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        });

        say STDERR "       Preparing UPDATE statement" if $self->verbose > 1;
        my $upd = $dbh->prepare(q{
            UPDATE entries
               SET feed_id        = ?,
                   url            = ?,
                   via_url        = ?,
                   title          = ?,
                   published_at   = ?,
                   updated_at     = ?,
                   summary        = ?,
                   author         = ?,
                   enclosure_type = ?,
                   enclosure_url  = ?,
                   enclosure_id   = ?,
                   enclosure_user = ?
             WHERE id = ?
        });

        for my $params (@entries) {
            my $res = 0;
            my ($upd_date, $up_to_date) = (shift @$params, shift @$params);
            if (defined $up_to_date) {
                # Exists but is out-of date. So update it.
                $upd->execute(@$params);
            } elsif ($upd_date) {
                # New entry. Insert it.
                $ins->execute(@$params);
            } else {
                # No update date. Update or insert as appropriate.
                $ins->execute(@$params) if $upd->execute(@$params) == 0;
            }
        }

        say STDERR "       Deleting older entries" if $self->verbose > 1;
        $dbh->do(q{
            DELETE FROM entries
             WHERE feed_id = ?
               AND id <> ALL(?)
        }, undef, $feed_id, \@ids);
    });
    say STDERR "    ", scalar time, "Transction complete" if $self->verbose > 1;

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
        aside
        b
        bdo
        big
        blockquote
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
        footer
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

my %convert_to_div = map { $_ => 1 } qw(
    blockquote
);

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

                # We don't want the formatting of this element, so change it to a div.
                $elem->setNodeName('div') if $convert_to_div{$name};

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
            # We got something here. Strip any HTML and return it.
            return join ' ', map {
                Parser->strip_html($_->toString)
            } _wanted_nodes_for($body);
        }
    }

    # Try the content of the entry.
    my $content = $entry->content or return '';
    my $body    = $content->body  or return '';

    # Fetch a reasonable amount of the content to use as a summary.
    my @text;
    for my $elem (_wanted_nodes_for($body)) {
        if ($elem->nodeType == XML_TEXT_NODE) {
            push @text, Parser->strip_html($elem->toString)
                if $elem->toString =~ /\S/;
            next;
        }
        next if $elem->nodeType != XML_ELEMENT_NODE or !$allowed{$elem->nodeName};

        push @text, Parser->strip_html($elem->toString)
            if $elem->hasChildNodes || $elem->hasAttributes;
        my $ret = join ' ', @text;
        $ret =~ s/\s{2,}/ /g;
        return $ret if length $ret > 140;
    }
    my $ret = join ' ', @text;
    $ret =~ s/\s{2,}/ /g;
    return $ret;
}

sub _wanted_nodes_for {
    my $doc = Parser->parse_html_string(shift);
    map {
        # If it's an unwanted node but we want its children, keep them.
        $keep_children{$_->nodeName} ? $_->childNodes : $_
    } $doc->findnodes('/html/body')->get_node(1)->childNodes;
}

sub _find_enclosure {
    my ($self, $entry, $base_url, $entry_link) = @_;
    for my $enc ($entry->enclosures) {
        my $etype = $enc->type or next;
        next if $etype !~ m{^(?:image|audio|video)/};
        my $enc = $self->_validate_enclosure($enc->type, URI->new($enc->url)->canonical);
        return $enc if $enc;
    }

    # Use XML::LibXML and XPath to find something and link it up.
    for my $content ($entry->content, $entry->summary) {
        next unless $content;
        my $body = $content->body or next;
        my $doc = Parser->parse_html_string($body) or next;
        for my $node ($doc->findnodes('//img/@src|//audio/@src|//video/@src')) {
            my $url = $node->nodeValue or next;
            $url = $base_url
                ? URI->new_abs($url, $base_url)->canonical
                : URI->new($url)->canonical;
            next if !$url->can('host') || $url->host =~ /\bdoubleclick[.]net$/;
            (my($type), $url) = $self->_get_type($url, $base_url);
            next unless $type && $type =~ m{^(?:image|audio|video)/};
            my $enc = $self->_validate_enclosure($type, $url);
            return $enc if $enc;
        }
    }

    # Look at the direct link.
    my ($type, $url) = $self->_get_type($entry_link, $base_url);
    return $self->_validate_enclosure($type, $url)
        if $type && $type =~ m{^(?:image|audio|video)/};

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
    my ($self, $url, $base_url) = @_;
    $url = $base_url
        ? URI->new_abs($url, $base_url)->canonical
        : URI->new($url)->canonical;
    if (my $type = $mt->mimeTypeOf($url)) {
        return $type, $url;
    }

    # Maybe the thing redirects? Ask it for its content type.
    my $res = $self->ua->head($url);
    return $res->is_success
        ? (scalar $res->content_type, URI->new($res->request->uri)->canonical)
        : undef;
}

sub _validate_enclosure {
    my $self = shift;
    my $enc  = $self->_audit_enclosure(@_) or return;

    # Make sure it's not a dupe.
    my $conn = App::FeedScene->new($self->app)->conn;
    return if $self->eurls->{$enc->{url}} || $conn->run(sub {
        say STDERR "       Checking enclosure" if $self->verbose > 1;
        shift->selectcol_arrayref(
            'SELECT 1 FROM entries WHERE enclosure_url = ?',
            undef, $enc->{url}
        )->[0];
    });

    return $enc;
}

sub _audit_enclosure {
    my ($self, $type, $url) = @_;

    my $enc = {
        type => $type,
        url  => $url
    };

    return $enc unless $url->host =~ /^farm\d+[.]static[.]flickr[.]com$/;

    # Grab the photo ID or return.
    my ($photo_id) = ($url->path_segments)[-1] =~ /^([^_]+)(?=_)/;
    return $enc unless $photo_id;

    # See if we have it already.
    my $conn = App::FeedScene->new($self->app)->conn;
    my $enc_id = "flickr:$photo_id";
    return if $self->eids->{$enc_id} || $conn->run(sub {
        say STDERR "       Checking enclosure ID $enc_id" if $self->verbose > 1;
        shift->selectcol_arrayref(
            'SELECT 1 FROM entries WHERE enclosure_id = ?',
            undef, $enc_id
        )->[0];
    });
    $enc->{id} = $enc_id;

    # Request information about the photo or return.
    my $api_key = '58e9ec90618e63825e2372a94e306bb3';
    my $api_url = 'http://api.flickr.com/services/rest/?method='
        . "flickr.photos.getInfo&api_key=$api_key&photo_id=$photo_id";
    my $res = $self->ua->get($api_url);

    # If the request is unsuccessful, skip the photo.
    return unless $res->is_success || $res->code == HTTP_NOT_MODIFIED;

    # Grab the user ID and description.
    my $doc = Parser->libxml->parse_string($res->content);
    my $enc_user = 'flickr:' . $doc->findvalue('/rsp/photo/owner/@nsid');
    return if $self->eusers->{$enc_user} || $conn->run(sub {
        say STDERR "       Checking enclosure user $enc_user" if $self->verbose > 1;
        shift->selectcol_arrayref(
            'SELECT 1 FROM entries WHERE enclosure_user = ?',
            undef, $enc_user
        )->[0];
    });

    # Store the username and the description.
    $enc->{user} = $enc_user;
    $enc->{desc} = $doc->findvalue('/rsp/photo/description');

    # Fetch sizes.
    $api_url = 'http://api.flickr.com/services/rest/?method='
        . "flickr.photos.getSizes&api_key=$api_key&photo_id=$photo_id";
    $res = $self->ua->get($api_url);
    return $enc unless $res->is_success || $res->code == HTTP_NOT_MODIFIED;

    # Parse it.
    $doc = Parser->libxml->parse_string($res->content);

    # Go for large, medium, or original.
    for my $size qw(Large Medium Original) {
        if (my $source = $doc->find("/rsp/sizes/size[\@label='$size']/\@source")) {
            $enc->{url} = URI->new($source)->canonical;
            last;
        }
    }

    # Bah! Just go with what we've got.
    return $enc;
}

1;

=head1 Name

App::FeedScene::EntryUpdater - FeedScene entry updater

=head1 Author

David E. Wheeler <david@lunar-theory.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

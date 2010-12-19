package App::FeedScene::EntryUpdater 0.21;

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
has verbose => (is => 'rw', isa => 'Int');

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

    # Iterate over the entries;
    my (@ids, @entries);
    my $be_verbose = ($self->verbose || 0) > 1;
    $conn->run(sub {
        my $dbh = shift;

        my $sth = $dbh->prepare(q{
            SELECT updated_at >= ?
              FROM entries
             WHERE id = ?
        });

        for my $entry ($feed->entries) {
            say STDERR '    ', $entry->link if $be_verbose;
            my $entry_link = $base_url
                ? URI->new_abs($entry->link, $base_url)->canonical
                : URI->new($entry->link)->canonical;
            my ($enc_type, $enc_url) = ('', '');

            if ($portal) {
                # Need some media for non-text portals.
                ($enc_type, $enc_url) = $self->_find_enclosure($entry, $base_url, $entry_link);
                next unless $enc_type;
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
                Parser->strip_html($entry->title || ''),
                $pub_date,
                $upd_date || $pub_date,
                _find_summary($entry),
                Parser->strip_html($entry->author || ''),
                $enc_type,
                $enc_url,
                $uuid,
            )];
        }
    });

    $conn->txn(sub {
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
        my $ins = $dbh->prepare(q{
            INSERT INTO entries (
                feed_id, url, title, published_at, updated_at, summary,
                author, enclosure_type, enclosure_url, id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        });

        my $upd = $dbh->prepare(q{
            UPDATE entries
               SET feed_id        = ?,
                   url            = ?,
                   title          = ?,
                   published_at   = ?,
                   updated_at     = ?,
                   summary        = ?,
                   author         = ?,
                   enclosure_type = ?,
                   enclosure_url  = ?
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
            push @ids, $params->[-1];
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
        my $type = $enc->type or next;
        next if $type !~ m{^(?:image|audio|video)/};
        return $self->_audit_enclosure($enc->type, URI->new($enc->url)->canonical);
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
            return $self->_audit_enclosure($type, $url)
                if $type && $type =~ m{^(?:image|audio|video)/};
        }
    }

    # Look at the direct link.
    my ($type, $url) = $self->_get_type($entry_link, $base_url);
    return $self->_audit_enclosure($type, $url)
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

sub _audit_enclosure {
    my ($self, $type, $url) = @_;
    return $type, $url unless $url->host =~ /^farm\d+[.]static[.]flickr[.]com$/;

    # Grab the photo ID or return.
    my ($photo_id) = ($url->path_segments)[-1] =~ /^([^_]+)(?=_)/;
    return $type, $url unless $photo_id;

    # See if we have it in the cache already.
    my $conn = App::FeedScene->new($self->app)->conn;
    if (my $cached_url = $conn->run(sub {
        my ($url) = shift->selectrow_array(
            'SELECT url FROM audit_cache WHERE id = ?',
            undef, $photo_id,
        );
        return $url;
    })) {
        return $type, URI->new($cached_url)->canonical;
    }

    # Request information about the photo or return.
    my $api_key = '58e9ec90618e63825e2372a94e306bb3';
    my $api_url = 'http://api.flickr.com/services/rest/?method='
        . "flickr.photos.getSizes&api_key=$api_key&photo_id=$photo_id";
    my $res = $self->ua->get($api_url);
    return ($type, $url) unless $res->is_success
        || $res->code == HTTP_NOT_MODIFIED;

    # Parse it.
    my $doc = Parser->libxml->parse_string($res->content);

    # Go for large, medium, or original.
    for my $size qw(Large Medium Original) {
        if (my $source = $doc->find("/rsp/sizes/size[\@label='$size']/\@source")) {
            # This is the one we want.
            $conn->run(sub {
                shift->do(
                    'INSERT INTO audit_cache (id, url) VALUES (?, ?)',
                    undef, $photo_id, $source
                );
            });
            return $type, URI->new($source)->canonical;
        }
    }

    # Bah! Just go with what we've got.
    return $type, $url;
}

1;

=head1 Name

App::FeedScene::EntryUpdater - FeedScene entry updater

=head1 Author

David E. Wheeler <david@lunar-theory.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

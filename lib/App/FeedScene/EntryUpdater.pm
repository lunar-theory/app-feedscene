package App::FeedScene::EntryUpdater 0.01;

use 5.12.0;
use utf8;
use App::FeedScene;
use App::FeedScene::UA;
use Data::Feed;
use Data::Feed::Parser::Atom;
use Data::Feed::Parser::RSS;
use HTTP::Status qw(HTTP_NOT_MODIFIED);
use XML::LibXML qw(XML_ELEMENT_NODE XML_TEXT_NODE);
use OSSP::uuid;
use MIME::Types;

use Class::XSAccessor constructor => 'new', accessors => { map { $_ => $_ } qw(
   app
   portal
   ua
   verbose
) };

my $libxml_options = {
    recover    => 2,
    no_network => 1,
    no_blanks  => 1,
    encoding   => 'utf8',
    no_cdata   => 1,
};
my $parser = XML::LibXML->new($libxml_options);

my $parse_options = {
    suppress_errors   => 1,
    suppress_warnings => 1,
};

$XML::Atom::ForceUnicode = 1;
$Data::Feed::Parser::RSS::PARSER_CLASS = 'App::FeedScene::Parser::RSS';

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

    my $feed = Data::Feed->parse(\$res->content);

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
        my $be_verbose = ($self->verbose || 0) > 1;
        for my $entry ($feed->entries) {
            say '    ', $entry->link if $be_verbose;
            my ($enc_type, $enc_url) = ('', '');

            if ($portal) {
                # Need some media for non-text portals.
                ($enc_type, $enc_url) = $self->_find_enclosure($entry);
                next unless $enc_type;
            }

            my $pub_date = $entry->issued;
            my $upd_date = $entry->modified || $pub_date or next;
            $pub_date ||= $upd_date;
            my $uuid = _uuid($feed->link, $entry->link);

            $sth->execute(
                $uuid,
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

            push @ids, $uuid;
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
                my $sibling = $elem->nextSibling;
                $parent->removeChild($elem);
                $elem = $sibling;
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
    use Carp;
    if (my $sum = $entry->summary) {
        if (my $body = $sum->body) {
            # We got something here. Clean it up and return it.
            return join '', map { $_->toString } _clean_html(
                $parser->parse_html_string($body, $parse_options)->firstChild
            )->childNodes;
        }
    }

    # Try the content of the entry.
    my $content = $entry->content or return '';
    my $body    = $content->body  or return '';
    my $doc     = $parser->parse_html_string($body, $parse_options);

    # Fetch a reasonable amount of the content to use as a summary.
    my $ret = '';
    my @nodes = $doc->findnodes('/html/body')->get_node(1)->childNodes;
    while (@nodes) {
        my $elem = shift @nodes;
        next if $elem->nodeType != XML_ELEMENT_NODE;
        unless ($allowed{$elem->nodeName}) {
            # We don't want this element.
            if ($keep_children{$elem->nodeName}) {
                # But we want its children.
                unshift @nodes, map {
                    if ($_->nodeType == XML_TEXT_NODE) {
                        my $n = XML::LibXML::Element->new('p');
                        $n->addChild($_);
                        $n;
                    } else {
                        $_;
                    }
                } $elem->childNodes;
            }
            next;
        }

        # Clean the HTML.
        $ret .= _clean_html($elem)->toString;
        return $ret if length $ret > 140;
    }
    return $ret;
}


sub _find_enclosure {
    my ($self, $entry) = @_;
    for my $enc ($entry->enclosures) {
        my $type = $enc->type or next;
        next if $type !~ m{^(?:image|audio|video)/};
        return $enc->type, $enc->url;
    }

    # Use XML::LibXML and XPath to find something and link it up.
    for my $content ($entry->content, $entry->summary) {
        next unless $content;
        my $body = $content->body or next;
        my $doc = $parser->parse_html_string($body, $parse_options) or next;
        for my $node ($doc->findnodes('//img/@src|//audio/@src|//video/@src')) {
            my $url = $node->nodeValue or next;
            (my($type), $url) = $self->_get_type($url) or next;
            return $type, $url if $type =~ m{^(?:image|audio|video)/};
        }
    }

    # Look at the direct link.
    my ($type, $url) = $self->_get_type($entry->link);
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

RSSPARSER: {
    package App::FeedScene::Parser::RSS;
    use parent 'XML::RSS::LibXML';
    sub create_libxml { $parser }
}

1;

=head1 Name

App::FeedScene::EntryUpdater - FeedScene entry updater

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

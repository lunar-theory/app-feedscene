package App::FeedScene::LinkUpdater 0.01;

use 5.12.0;
use utf8;
use App::FeedScene;
use App::FeedScene::UA;
use Text::CSV_XS;
use HTTP::Status qw(HTTP_NOT_MODIFIED);

use Class::XSAccessor constructor => 'new', accessors => { map { $_ => $_ } qw(
   app
   url
) };

sub run {
    my $self = shift;
    my $res = App::FeedScene::UA->new($self->app)->get($self->url);
    require Carp && Carp::croak($res->status_line)
        unless $res->is_success or $res->code == HTTP_NOT_MODIFIED;
    $self->process($res->decoded_content)
        unless $res->code == HTTP_NOT_MODIFIED;
}

sub process {
    my $self = shift;
    my @csv  = split /\r?\n/ => shift;
    my $csv  = Text::CSV_XS->new({ binary => 1 });
    shift @csv; # Remove headers.

    my $conn = App::FeedScene->new($self->app)->conn;
    my $sth = $conn->run(sub {
        shift->prepare(q{
            INSERT OR REPLACE INTO links (portal, url, category)
            VALUES (?, ?, ?)
        });
    });

    $conn->txn(sub {
        my @urls;
        for my $line (@csv) {
            $csv->parse($line);
            my ($portal, $url, $category) = $csv->fields;
            $portal = 0 if $portal eq 'text';
            $sth->execute($portal, $url, $category);
            push @urls, $url;
        }

        # Remove old links.
        $_->do(
            'DELETE FROM links WHERE url NOT IN (' . join(', ', ('?') x @urls) . ')',
            undef, @urls
        ) if @urls;

    });
    return $self;
}

1;

=head1 Name

App::FeedScene::LinkUpdate - FeedScene link updater

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

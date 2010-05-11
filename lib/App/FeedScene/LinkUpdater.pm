package App::FeedScene::LinkUpdater 0.01;

use 5.12.0;
use utf8;
use App::FeedScene;
use App::FeedScene::UA;
use Text::CSV_XS;

use Class::XSAccessor constructor => '_new', accessors => { map { $_ => $_ } qw(
   app
   url
) };

sub new {
    my $self = shift->_new(@_);
    require Carp && Carp::croak('Missing the required "app" parameter')
        unless $self->app;
    require Carp && Carp::croak('Missing the required "url" parameter')
        unless $self->url;
    return $self;
}

sub run {
    my $self = shift;
    my $res = App::FeedScene::UA->new($self->app)->get($self->url);
    $self->process($res->decoded_content);
}

sub process {
    my $self = shift;
    my @csv = split /\r?\n/ => shift;
    my $csv   = Text::CSV_XS->new({ binary => 1 });
    shift @csv;

    my $sth = App::FeedScene->new($self->app)->conn->run(sub {
        shift->prepare(q{
            INSERT OR REPLACE INTO links (portal, url, category)
            VALUES (?, ?, ?)
        });
    });

    for my $line (@csv) {
        $csv->parse($line);
        my ($portal, $url, $category) = $csv->fields;
        $portal = 0 if $portal eq 'text';
        $sth->execute($portal, $url, $category);
    }
}


1;

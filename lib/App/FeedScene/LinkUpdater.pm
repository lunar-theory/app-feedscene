package App::FeedScene::LinkUpdater 0.01;

use 5.12.0;
use utf8;

use Class::XSAccessor constructor => 'new', accessors => { map { $_ => $_ } qw(
   name
   csv_url
) };


sub go {
    shift->new(@_)->run;
}

sub run {
    my $self = shift;
    my $conn = FeedScene::App->new($self->name)->conn;
}

1;

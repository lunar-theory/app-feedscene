package App::FeedScene::DBA;

use 5.12.0;
use utf8;
use App::FeedScene;

use Class::XSAccessor constructor => '_new', accessors => { map { $_ => $_ } qw(
    app
    client
    sql_dir
) };

sub new {
    my $self = shift->_new(@_);
    require Carp && Carp::croak('Missing the required "app" parameter')
        unless $self->app;
    $self->client('sqlite3') unless $self->client;
    $self->sql_dir('sql') unless $self->sql_dir;
    return $self;
}

sub init {
    my $self = shift;
    my $fs = App::FeedScene->new($self->app);
    my $db_file = $fs->db_name;
    die qq{Database "$db_file" already exists\n} if -e $db_file;
    $fs->conn->run(sub { shift->do('PRAGMA schema_version = 0' ) });
}

sub upgrade {
    my $self = shift;
    my $fs = App::FeedScene->new($self->app);
    $self->init unless -e $fs->db_name;
    my $conn = $fs->conn;

    my $current_version = $conn->run(sub {
        shift->selectrow_array('PRAGMA schema_version');
    });

    my $dir = $self->sql_dir;
    my @files = sort { $a->[0] <=> $b->[0] }
                grep { $_->[0] > $current_version }
                 map { (my $n = $_) =~ s{^\Q$dir\E[/\\](\d+)-.+}{$1}; [ $n => $_ ] }
                grep { -f }
        glob $self->sql_dir . '/[0-9]*-*.sql';

    my @args = (
        $self->client, '-noheader', '-bail', '-column',
        $fs->db_name,
    );

    for my $spec (@files) {
        my ($new_version, $file) = @{ $spec };

        # Apply the version.
        system(@args, ".read $file") == 0  or die;

        $conn->run(sub {
            shift->do("PRAGMA schema_version = $new_version");
        });
    }
}

1;

=head1 Name

App::FeedScene::DBA - FeedScene database administration

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

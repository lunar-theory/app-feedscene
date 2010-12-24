package App::FeedScene::DBA;

use 5.12.0;
use utf8;
use namespace::autoclean;
use App::FeedScene;
use Moose;

(my $def_dir = __FILE__) =~ s{(?:blib/)?lib/App/FeedScene/DBA[.]pm$}{sql};
has app     => (is => 'rw', isa => 'Str');
has client  => (is => 'rw', isa => 'Str', default => 'psql');
has user    => (is => 'rw', isa => 'Str', default => 'postgres');
has host    => (is => 'rw', isa => 'Str');
has port    => (is => 'rw', isa => 'Str');
has sql_dir => (is => 'rw', isa => 'Str', default => $def_dir );

sub init {
    my $self = shift;
    my $fs   = App::FeedScene->new($self->app);
    my $db   = $fs->db_name;
    system($self->_command, '-d', 'template1', '-c', qq{CREATE DATABASE $db}) == 0 or die;
    $fs->conn->run(sub {
        $_->do('CREATE TABLE schema_version (version int)');
        $_->do('INSERT INTO schema_version VALUES (0)');
    });
}

sub drop {
    my $self = shift;
    my $fs   = App::FeedScene->new($self->app);
    my $db   = $fs->db_name;
    system($self->_command, '-d', 'template1', '-c', qq{DROP DATABASE $db}) == 0 or die;
}

sub upgrade {
    my $self = shift;
    my $fs   = App::FeedScene->new($self->app);
    my $db   = $fs->db_name;
    my $conn = $fs->conn;

    # Create the database if it doesn't exist.
    eval { $conn->dbh };
    $self->init if ref $@ && $@->err == 1;

    my $current_version = $conn->run(sub {
        shift->selectrow_array('SELECT version FROM schema_version');
    });

    my $dir = $self->sql_dir;
    my @files = sort { $a->[0] <=> $b->[0] }
                grep { $_->[0] > $current_version }
                 map { (my $n = $_) =~ s{^\Q$dir\E[/\\](\d+)-.+}{$1}; [ $n => $_ ] }
                grep { -f }
        glob $self->sql_dir . '/[0-9]*-*.sql';

    my @cmd = $self->_command;

    for my $spec (@files) {
        my ($new_version, $file) = @{ $spec };

        # Apply the version.
        system(@cmd, '-d', $db, '-f', $file) == 0 or die;

        $conn->run(sub {
            shift->do("UPDATE schema_version SET version = $new_version");
        });
    }
    return $self;
}

sub recreate {
    my $self = shift;
    $self->drop;
    $self->init;
    $self->upgrade;
}

sub _command {
    my $self = shift;
    my @cmd = (
        $self->client,
        '--username' => $self->user,
        '--quiet',
        '--no-psqlrc',
        '--no-align',
        '--tuples-only',
        '--set' => 'ON_ERROR_ROLLBACK=1',
        '--set' => 'ON_ERROR_STOP=1',
    );
    push @cmd, '--host' => $self->host if $self->host;
    push @cmd, '--port' => $self->port if $self->port;

    return @cmd;
}

1;

=head1 Name

App::FeedScene::DBA - FeedScene database administration

=head1 Author

David E. Wheeler <david@lunar-theory.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

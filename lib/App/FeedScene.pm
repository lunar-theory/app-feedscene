package App::FeedScene 0.15;

use 5.12.0;
use utf8;
use namespace::autoclean;
use DBD::SQLite 1.29;
use DBIx::Connector 0.34;
use Exception::Class::DBI 1.0;
Exception::Class::DBI->Trace(1);
use Moose;

our $SELF;

has app  => (is => 'rw', isa => 'Str');
has conn => (is => 'rw', isa => 'DBIx::Connector');

sub new {
    my ($class, $app) = @_;
    if ($SELF) {
        return $SELF if !$app || $SELF->app eq $app;
        require Carp;
        Carp::croak(
            qq{You tried to create a "$app" app but the singleton is for "}
            . $SELF->app . '"'
        );
    }

    $SELF = bless { app => $app } => $class;
    my $dsn = 'dbi:SQLite:dbname=' . $SELF->db_name;
    my $conn = $SELF->conn(DBIx::Connector->new($dsn, '', '', {
        PrintError     => 0,
        RaiseError     => 0,
        HandleError    => Exception::Class::DBI->handler,
        AutoCommit     => 1,
        sqlite_unicode => 1,
        Callbacks      => {
            connected => sub { shift->do('PRAGMA foreign_keys = ON'); return; }
        }
    }));
    $conn->mode('fixup');
    return $SELF;
}

sub db_name {
    'db/' . shift->app . '.db';
}

1;

=head1 Name

App::FeedScene - FeedScene feed processor

=head1 Author

David E. Wheeler <david@lunar-theory.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut


package App::FeedScene 0.31;

use 5.12.0;
use utf8;
use namespace::autoclean;
use DBD::Pg 2.17.2;
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
    my $dsn = 'dbi:Pg:dbname=' . lc $SELF->app;
    my $conn = $SELF->conn(DBIx::Connector->new($dsn, 'postgres', '', {
        PrintError        => 0,
        RaiseError        => 0,
        HandleError       => Exception::Class::DBI->handler,
        AutoCommit        => 1,
        pg_enable_utf8    => 1,
        pg_server_prepare => 1,
    }));
    $conn->mode('fixup');
    return $SELF;
}

sub db_name {
    lc shift->app;
}

1;

=head1 Name

App::FeedScene - FeedScene feed processor

=head1 Author

David E. Wheeler <david@lunar-theory.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut


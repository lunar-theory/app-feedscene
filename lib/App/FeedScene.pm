package App::FeedScene 0.01;

use 5.12.0;
use utf8;
use DBD::SQLite 1.29;
use DBIx::Connector 0.34;
use Exception::Class::DBI 1.0;

our $SELF;

use Class::XSAccessor accessors => { map { $_ => $_ } qw(
    name
    conn
) };

sub new {
    my ($class, $name) = @_;
    if ($SELF) {
        return $SELF if !$name || $SELF->name eq $name;
        die qq{You tried to create a "$name" app but the singleton is "}
            . $SELF->name . '"';
    }

    $SELF = bless { name => $name } => $class;
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
    'db/' . shift->name . '.db';
}

1;

=head1 Name

App::FeedScene - FeedScene feed processor

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut


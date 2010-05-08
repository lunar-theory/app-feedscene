package App::FeedScene 0.01;

use strict;
use warnings;
use 5.12.0;
use utf8;
use DBD::SQLite 1.29;
use DBIx::Connector 0.34;
use Exception::Class::DBI 1.0;

our $SELF;

use Class::XSAccessor accessors => { map { $_ => $_ } qw(
   conn
) };

sub new {
    return $SELF if $SELF;
    my ($class, $config_file) = @_;
    my $config = _config($config_file);
    $SELF = bless {
        name => $config->{name},
        conn => DBIx::Connector->new(@{ $config->{dbi} }{qw(dsn username password)}, {
            PrintError     => 0,
            RaiseError     => 0,
            HandleError    => Exception::Class::DBI->handler,
            AutoCommit     => 1,
            pg_enable_utf8 => 1,
        })
    } => $class;
    return $SELF;
}

sub _config {
    my $file = shift;
    require YAML::XS;
    open my $fh, '<', $file or die "Cannot open $file: $!\n";
    local $/;
    my $config = YAML::XS::Load(<$fh>);
    close $fh;
    return $config;
}

1;

=head1 Name

App::FeedScene - FeedScene feed processor

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut


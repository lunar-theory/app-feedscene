#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 19;
#use Test::More 'no_plan';
use Test::NoWarnings;
use Test::File;
use Test::MockObject::Extends;

BEGIN { use_ok 'App::FeedScene::DBA' or die; }

ok my $dba = App::FeedScene::DBA->new(
    app     => 'foo',
    client  => 'bar',
    sql_dir => 'baz',
), 'Create a DBA object';

isa_ok $dba, 'App::FeedScene::DBA', 'It';

is $dba->app,     'foo', 'The app attribute should be set';
is $dba->client,  'bar', 'The client attribute should be set';
is $dba->sql_dir, 'baz', 'The sql_dir attribute should be set';

# Try default values.
ok $dba = App::FeedScene::DBA->new( app => 'hey' ),
    'Create another DBA object';

is $dba->app,     'hey',  'The app attribute should be set';
is $dba->client,  'psql', 'The client attribute should be the default';
is $dba->sql_dir, File::Spec->rel2abs('sql'),
    'The sql_dir attribute should be the default';

# Try with real stuff.
ok $dba = App::FeedScene::DBA->new( app => 'fstest', sql_dir => 't/sql' ),
    'Create testing DBA object';

ok $dba->init, 'Init the database';
END { $dba->drop }

# Make sure that the schema version is set.
my $fs = App::FeedScene->new('fstest');
is $fs->conn->run( sub { shift->selectcol_arrayref('SELECT version FROM schema_version')->[0] }),
    0, 'The schema version should be 0';
END { $fs->conn->disconnect }

# Let's make sure that the upgrade works.
my $conn = Test::MockObject::Extends->new( $fs->conn );
my $run = $conn->can('run');
my @versions = (0, 42, 123, 124);
$conn->mock(run => sub {
    $run->(@_);
    my $v = shift @versions;
    is $conn->$run( sub { ($_->selectrow_array('SELECT version FROM schema_version'))[0] }), $v,
        "Schema version should be $v";
});

ok $dba->upgrade, 'Upgrade the database';

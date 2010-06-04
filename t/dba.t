#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 21;
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

is $dba->app,     'hey',     'The app attribute should be set';
is $dba->client,  'sqlite3', 'The client attribute should be the default';
is $dba->sql_dir, File::Spec->rel2abs('sql'),
    'The sql_dir attribute should be the default';

# Try with real stuff.
ok $dba = App::FeedScene::DBA->new( app => 'fstest', sql_dir => 't/sql' ),
    'Create testing DBA object';

my $fs = App::FeedScene->new('fstest');
file_not_exists_ok $fs->db_name, 'The databse file should not (yet) exist';
END { unlink $fs->db_name }

ok $dba->init, 'Init the database';
file_exists_ok $fs->db_name, 'Now the databse file should exist';

# Make sure that the schema version is set.
is $fs->conn->run( sub { (shift->do('PRAGMA schema_version'))[0] }),
    '0E0', 'The schema version should be 0';

# Let's make sure that the upgrade works.
my $conn = Test::MockObject::Extends->new( $fs->conn );
my $run = $conn->can('run');
my @versions = (0, 42, 123, 124);
$conn->mock(run => sub {
    $run->(@_);
    my $v = shift @versions;
    is $conn->$run( sub { ($_->selectrow_array('PRAGMA schema_version'))[0] }), $v,
        "Schema version should be $v";
});

ok $dba->upgrade, 'Upgrade the database';

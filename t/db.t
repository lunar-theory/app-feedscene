#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 19;
#use Test::More 'no_plan';
use Test::Exception;

BEGIN { use_ok 'App::FeedScene' or die; }

isa_ok my $fs = App::FeedScene->new('myapp'), 'App::FeedScene';
END { $fs->conn->disconnect; unlink 'db/myapp.db' }

is $fs->app, 'myapp', 'App name should be correct';
is $fs->db_name, 'db/myapp.db', 'DB name should be correct';
isa_ok $fs->conn, 'DBIx::Connector';
is $fs->conn->mode, 'fixup', 'Should be fixup mode';
is +App::FeedScene->new, $fs, 'Should be a singleton';

throws_ok { App::FeedScene->new('foo') }
    qr/You tried to create a "foo" app but the singleton is for "myapp"/,
    'Error for invalid app name should be correct';

isa_ok my $dbh = $fs->conn->dbh, 'DBI::db', 'The DBH';
ok $fs->conn->connected, 'We should be connected to the database';

# What are we connected to, and how?
is $dbh->{Name}, 'dbname=db/myapp.db',
    'Should be connected to "db/myapp.db"';
ok !$dbh->{PrintError}, 'PrintError should be disabled';
ok !$dbh->{RaiseError}, 'RaiseError should be disabled';
ok $dbh->{AutoCommit}, 'AutoCommit should be enabled';
ok $dbh->{sqlite_unicode}, 'sqlite_unicode should be enabled';
isa_ok $dbh->{HandleError}, 'CODE', 'The error handler';
isa_ok $dbh->{Callbacks}, 'HASH', 'Should have callbacks';
isa_ok $dbh->{Callbacks}{connected}, 'CODE', 'Should have connected callback';
ok $dbh->selectrow_array('PRAGMA foreign_keys'),
    'Foreign key constraints should be enabled';

#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 18;
#use Test::More 'no_plan';
use Test::Exception;
use Test::NoWarnings;
use File::Path;

BEGIN { use_ok 'App::FeedScene' or die; }
File::Path::make_path 'db';

isa_ok my $fs = App::FeedScene->new('myapp'), 'App::FeedScene';
END { $fs->conn->disconnect; unlink 'db/myapp.db' }

is $fs->app, 'myapp', 'App name should be correct';
is $fs->db_name, lc $fs->app, 'DB name should be correct';
isa_ok $fs->conn, 'DBIx::Connector';
is $fs->conn->mode, 'fixup', 'Should be fixup mode';
is +App::FeedScene->new, $fs, 'Should be a singleton';

throws_ok { App::FeedScene->new('foo') }
    qr/You tried to create a "foo" app but the singleton is for "myapp"/,
    'Error for invalid app name should be correct';

use App::FeedScene::DBA;
my $dba = App::FeedScene::DBA->new(app => $fs->app);
$dba->init;
END { $dba->drop }
isa_ok my $dbh = $fs->conn->dbh, 'DBI::db', 'The DBH';
END { $dbh->disconnect }
ok $fs->conn->connected, 'We should be connected to the database';

# What are we connected to, and how?
is $dbh->{Name}, 'dbname=myapp', 'Should be connected to "myapp"';
ok !$dbh->{PrintError}, 'PrintError should be disabled';
ok !$dbh->{RaiseError}, 'RaiseError should be disabled';
ok $dbh->{AutoCommit}, 'AutoCommit should be enabled';
ok $dbh->{pg_enable_utf8}, 'pg_enable_utf8 should be enabled';
ok $dbh->{pg_server_prepare}, 'pg_server_prepare should be enabled';
isa_ok $dbh->{HandleError}, 'CODE', 'The error handler';

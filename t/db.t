#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 13;
#use Test::More 'no_plan';
use Test::Exception;

BEGIN { use_ok 'App::FeedScene' or die; }

isa_ok my $fs = App::FeedScene->new('myapp'), 'App::FeedScene';
END { $fs->conn->disconnect; unlink 'db/myapp.db' }

is $fs->name, 'myapp', 'Name should be correct';
isa_ok $fs->conn, 'DBIx::Connector';
is +App::FeedScene->new, $fs, 'Should be a singleton';

throws_ok { App::FeedScene->new('foo') }
    qr/You tried to create a "foo" app but the singleton is "myapp"/;

isa_ok my $dbh = $fs->conn->dbh, 'DBI::db', 'The DBH';
ok $fs->conn->connected, 'We should be connected to the database';

# What are we connected to, and how?
is $dbh->{Name}, 'dbname=db/myapp.db',
    'Should be connected to "db/myapp.db"';
ok !$dbh->{PrintError}, 'PrintError should be disabled';
ok !$dbh->{RaiseError}, 'RaiseError should be disabled';
ok $dbh->{AutoCommit}, 'AutoCommit should be enabled';
isa_ok $dbh->{HandleError}, 'CODE', 'The error handler';


#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 11;
#use Test::More 'no_plan';
use File::Spec;

BEGIN { use_ok 'App::FeedScene' or die; }

my $config_file = File::Spec->catfile(qw(conf test.yml));

isa_ok my $fs = App::FeedScene->new($config_file), 'App::FeedScene';
isa_ok $fs->conn, 'DBIx::Connector';
is +App::FeedScene->new, $fs, 'Should be a singleton';

isa_ok my $dbh = $fs->conn->dbh, 'DBI::db', 'The DBH';
ok $fs->conn->connected, 'We should be connected to the database';

# What are we connected to, and how?
is $dbh->{Name}, 'dbname=feedscene_test.db',
    'Should be connected to "feedscene_test.db"';
ok !$dbh->{PrintError}, 'PrintError should be disabled';
ok !$dbh->{RaiseError}, 'RaiseError should be disabled';
ok $dbh->{AutoCommit}, 'AutoCommit should be enabled';
isa_ok $dbh->{HandleError}, 'CODE', 'The error handler';


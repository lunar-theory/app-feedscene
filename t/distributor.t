#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 7;
#use Test::More 'no_plan';
use Test::MockModule;
use IO::Compress::Gzip qw(gzip $GzipError Z_BEST_COMPRESSION);
use File::Path;
use File::Copy;

BEGIN { use_ok 'App::FeedScene::Distributor' or die };

File::Path::make_path('feeds');
copy 't/data/simple.atom', 'feeds/simple.xml' or die "Cannot copy simple.atom: $!\n";
END { unlink 'feeds/simple.xml' };

isa_ok my $dist = App::FeedScene::Distributor->new(
    app    => 'simple',
    bucket => 'feedscene',
), 'App::FeedScene::Distributor', 'New dist';

gzip 'feeds/simple.xml', \my $data, (
    AutoClose => 1,
    -Level    => Z_BEST_COMPRESSION,
    TextFlag  => 1,
    Name      => 'simple.xml',
) or die "gzip failed: $GzipError\n";

my $bucket_mock = Test::MockModule->new('Net::Amazon::S3::Bucket');
$bucket_mock->mock(add_key => sub {
    my $bucket = shift;
    is $bucket->bucket, 'feedscene', 'Should be the "feedscene" bucket';
    is_deeply \@_, ['simple.xml', $data, {
        content_type     => 'application/atom+xml',
        content_encoding => 'gzip',
        acl_short        => 'public-read',
    }], 'Should have proper add_key params';
});

ok $dist->run, 'Run the distribution';

# Make sure that it dies on failure.
$bucket_mock->mock(add_key => sub { return 0 });

my $s3_mock = Test::MockModule->new('Net::Amazon::S3');
$s3_mock->mock(err => 'Errrr' );
$s3_mock->mock(errstr => 'That sucked');

eval { $dist->run };
ok my $err = $@, 'Should catch exception';
like $err, qr/Errrr: That sucked/, 'And it should be the expected exception';

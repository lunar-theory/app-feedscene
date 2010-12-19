package App::FeedScene::Distributor 0.21;

use 5.12.0;
use utf8;
use IO::Compress::Gzip qw(gzip $GzipError Z_BEST_COMPRESSION);
use aliased 'Net::Amazon::S3';
use File::Basename;
use namespace::autoclean;

use Moose;

has file    => (is => 'rw', isa => 'Str');
has bucket  => (is => 'rw', isa => 'Str');
has verbose => (is => 'rw', 'isa' => 'Bool');

sub run {
    my $self = shift;

    # Gzip the file.
    say STDERR "Compressing ", $self->file if $self->verbose;
    gzip $self->file, \my $data, (
        AutoClose => 1,
        -Level    => Z_BEST_COMPRESSION,
        TextFlag  => 1,
    ) or die "gzip failed: $GzipError\n";

    # Upload it to S3.
    my $s3 = S3->new(
        aws_access_key_id     => 'AKIAJ25RESYUQFSS5ORQ',
        aws_secret_access_key => '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',
        secure                => 1,
        retry                 => 1,
    );

    my $fn = basename $self->file;
    say STDERR "Uploading $fn to ", $self->bucket if $self->verbose;
    my $bucket = $s3->bucket($self->bucket);
    $bucket->add_key($fn, $data, {
        content_type     => 'application/atom+xml',
        content_encoding => 'gzip',
        acl_short        => 'public-read',
    }) or die $s3->err . ": " . $s3->errstr;
}

1;

=head1 Name

App::FeedScene::Distributor - FeedScene feed distributor

=head1 Author

David E. Wheeler <david@lunar-theory.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

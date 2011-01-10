package App::FeedScene::Distributor 0.42;

use 5.12.0;
use utf8;
use IO::Compress::Gzip qw(gzip $GzipError Z_BEST_COMPRESSION);
use aliased 'Net::Amazon::S3';
use File::Basename;
use namespace::autoclean;

use Moose;

(my $def_dir = __FILE__) =~ s{(?:blib/)?lib/App/FeedScene/Distributor[.]pm$}{feeds};
has app     => (is => 'rw', isa => 'Str');
has dir     => (is => 'rw', isa => 'Str',  default => $def_dir );
has bucket  => (is => 'rw', isa => 'Str');
has verbose => (is => 'rw', 'isa' => 'Bool');

sub run {
    my $self = shift;
    my $path = $self->filepath;
    my $file = $self->filename;

    # Gzip the file.
    say STDERR "Compressing $path" if $self->verbose;
    gzip $path, \my $data, (
        AutoClose => 1,
        -Level    => Z_BEST_COMPRESSION,
        TextFlag  => 1,
        Name      => $file,
    ) or die "gzip failed: $GzipError\n";

    # Upload it to S3.
    my $s3 = S3->new(
        aws_access_key_id     => 'AKIAJ25RESYUQFSS5ORQ',
        aws_secret_access_key => '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',
        secure                => 1,
        retry                 => 1,
    );

    say STDERR "Uploading $file to ", $self->bucket if $self->verbose;
    my $bucket = $s3->bucket($self->bucket);
    $bucket->add_key($file, $data, {
        content_type     => 'application/atom+xml',
        content_encoding => 'gzip',
        acl_short        => 'public-read',
    }) or die $s3->err . ": " . $s3->errstr;
}

sub filename {
    shift->app . '.xml'
}

sub filepath {
    my $self = shift;
    File::Spec->catfile($self->dir, $self->filename);
}

1;

=head1 Name

App::FeedScene::Distributor - FeedScene feed distributor

=head1 Author

David E. Wheeler <david@lunar-theory.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

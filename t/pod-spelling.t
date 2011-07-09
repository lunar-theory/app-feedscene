#!perl -w

use strict;
use Test::More;
eval "use Test::Spelling";
plan skip_all => "Test::Spelling required for testing POD spelling" if $@;

add_stopwords(<DATA>);
all_pod_files_spelling_ok(qw(lib bin));

__DATA__
FeedScene
CSV
PostgreSQL
CloudFront

#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 10;
#use Test::More 'no_plan';
use Test::NoWarnings;

BEGIN { use_ok 'App::FeedScene::UA' or die; }

ok my $ua = App::FeedScene::UA->new('foo'), 'New UA object';
isa_ok $ua, 'App::FeedScene::UA';
isa_ok $ua, 'LWP::UserAgent::WithCache';
isa_ok $ua, 'LWP::UserAgent';

is $ua->agent, 'feedscene/' . App::FeedScene->VERSION,
    'Agent should be set';
is $ua->from, 'bot@designsceneapp.com', 'From should be set';

is $ua->{cache}->get_namespace, 'foo', 'Namespace should be app name';
is $ua->{cache}->get_cache_root, File::Spec->rel2abs('cache'),
    'Cache root should be set';

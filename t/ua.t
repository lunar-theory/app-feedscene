#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 17;
#use Test::More 'no_plan';
use Test::NoWarnings;

BEGIN { use_ok 'App::FeedScene::UA' or die; }

ok my $ua = App::FeedScene::UA->new('foo'), 'New UA object';
isa_ok $ua, 'App::FeedScene::UA';
isa_ok $ua, 'LWP::UserAgent::WithCache';
isa_ok $ua, 'LWP::RobotUA';
isa_ok $ua, 'LWP::UserAgent';

is $ua->agent, 'feedscene/' . App::FeedScene->VERSION,
    'Agent should be set';
is $ua->from, 'bot@designsceneapp.com', 'From should be set';
is $ua->delay, 10, 'Delay should be 10';

is $ua->{cache}->get_namespace, 'foo', 'Namespace should be app name';
is $ua->{cache}->get_cache_root, File::Spec->rel2abs('cache'),
    'Cache root should be set';

my $netloc = 'google.com:80';
ok !$ua->host_wait($netloc), 'Should have no wait for first request';
ok $ua->rules->visit($netloc), 'Visit the location';
ok !$ua->host_wait($netloc), 'Should have no wait for second request';
ok $ua->rules->visit($netloc), 'Visit the location again';
ok $ua->host_wait($netloc), 'Should have wait for third request';

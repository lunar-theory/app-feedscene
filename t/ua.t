#!/usr/bin/env perl -w

use strict;
use 5.12.0;
use utf8;
use Test::More tests => 10;
#use Test::More 'no_plan';

BEGIN { use_ok 'App::FeedScene::UA' or die; }

ok my $ua = App::FeedScene::UA->new('foo'), 'New UA object';
isa_ok $ua, 'App::FeedScene::UA';
isa_ok $ua, 'LWP::UserAgent::WithCache';
TODO: {
    local $TODO = 'Need to inherit from LWP::RobotUA';
    isa_ok $ua, 'LWP::RobotUA';
}
isa_ok $ua, 'LWP::UserAgent';

is $ua->agent, 'feedscene/' . App::FeedScene->VERSION,
    'Agent should be set';
is $ua->from, 'bot@designsceneapp.com', 'From should be set';
# is $ua->delay, 10, 'Delay should be 10';

is $ua->{cache}->get_namespace, 'foo', 'Namespace should be app name';
(my $root = __FILE__) =~ s{t/ua[.]t$}{cache};
is $ua->{cache}->get_cache_root, File::Spec->rel2abs($root),
    'Cache root should be set';

package App::FeedScene::UA;

use 5.12.0;
use utf8;
use base 'LWP::UserAgent::WithCache';
use LWP::RobotUA;
use App::FeedScene;

# Monkey-patch to support RobotUA.
#@LWP::UserAgent::WithCache::ISA = ('LWP::RobotUA');

sub new {
    my ($class, $app) = (shift, shift);
    (my $cache_dir = __FILE__) =~ s{lib/App/FeedScene/UA[.]pm$}{cache};
    my $self = $class->SUPER::new(
        namespace  => $app,
        cache_root => $cache_dir,
        agent      => 'feedscene/' . App::FeedScene->VERSION,
        from       => 'bot@designsceneapp.com',
        # delay      => 10, # be very nice -- max one hit every ten minutes!
        # use_sleep  => 0,
    );
    return $self;
}

1;

=head1 Name

App::FeedScene::UA - FeedScene internet user agent

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

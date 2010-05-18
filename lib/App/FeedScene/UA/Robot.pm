package App::FeedScene::UA::Robot;

use 5.12.0;
use utf8;
use base 'App::FeedScene::UA';
use LWP::RobotUA;

# Monkey-patch to support RobotUA.
@LWP::UserAgent::WithCache::ISA = ('LWP::RobotUA');

sub new {
    my ($class, $app) = (shift, shift);
    return $class->SUPER::new(
        $app,
        from  => 'bot@designsceneapp.com',
        delay => 1, # be very nice -- max one hit every ten minutes!
    );
}

sub host_wait {
    my ($self, $netloc) = @_;
    # First visit is for robots.txt, so let it be free.
    return if $self->no_visits($netloc) < 2;
    $self->SUPER::host_wait($netloc);
}

1;

=head1 Name

App::FeedScene::UA - FeedScene Internet user agent

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

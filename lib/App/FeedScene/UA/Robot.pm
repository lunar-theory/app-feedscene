package App::FeedScene::UA::Robot;

use 5.12.0;
use utf8;
use parent 'App::FeedScene::UA';
use LWP::RobotUA;

FUCKTYPE: {
    # Import the RobotUA interface. This way we get its behavior without
    # having to change LWP::UserAgent::WithCache's inheritance.
    no strict 'refs';
    while ( my ($k, $v) = each %{'LWP::RobotUA::'} ) {
        *{$k} = *{$v}{CODE} if *{$v}{CODE} and not *{$k}{CODE};
    }
};

sub new {
    my ($class, $app, $delay) = @_;
    # Force RobotUA configuration.
    local @LWP::UserAgent::WithCache::ISA = ('LWP::RobotUA');
    my $self = $class->SUPER::new($app, delay => $delay);
    $self->delay(0) unless $delay;
    return $self;
}

sub host_wait {
    my ($self, $netloc) = @_;
    # Return false if no delay.
    return unless $self->delay;
    # First visit is for robots.txt, so let it be free.
    return if !$netloc || $self->no_visits($netloc) < 2;
    $self->LWP::RobotUA::host_wait($netloc);
}

1;

=head1 Name

App::FeedScene::UA - FeedScene Internet user agent

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

package App::FeedScene::UA;

use 5.12.0;
use utf8;
use parent 'LWP::UserAgent::WithCache';
use App::FeedScene;

(my $cache_dir = __FILE__) =~ s{(?:blib/)?lib/App/FeedScene/UA[.]pm$}{cache};

sub new {
    my ($class, $app) = (shift, shift);
    return $class->SUPER::new(
        namespace  => $app,
        cache_root => $cache_dir,
        agent      => 'feedscene/' . App::FeedScene->VERSION,
        from       => 'bot@designsceneapp.com',
        timeout    => 10,
        @_
    );
}

sub cache { shift->{cache} }

1;

=head1 Name

App::FeedScene::UA - FeedScene Internet user agent

=head1 Author

David E. Wheeler <david@kineticode.com>

=head1 Copyright

Copyright (c) 2010 David E. Wheeler. All rights reserved.

=cut

#!/usr/bin/env perl -w

use 5.12.0;
use utf8;
use Test::More tests => 157;
#use Test::More 'no_plan';
use Test::XPath;
use Test::MockTime;
use Test::NoWarnings;
use File::Path;
use LWP::Protocol::file; # Turn on local fetches.

my $CLASS;
BEGIN {
    $CLASS = 'App::FeedScene::Generator';
    use_ok 'App::FeedScene::DBA'          or die;
    use_ok 'App::FeedScene::EntryUpdater' or die;
    use_ok $CLASS                         or die;
}

# Set an absolute time.
my $time = '2010-06-05T17:29:41Z';
Test::MockTime::set_fixed_time($time);
my $domain   = 'kineticode.com';
my $company  = 'Lunar Theory';
my $icon_url = 'http://www.google.com/s2/favicons?domain';

# Build a database for us to use.
ok my $dba = App::FeedScene::DBA->new( app => 'foo' ),
    'Create a DBA object';
ok $dba->upgrade, 'Initialize and upgrade the database';
END {
    unlink App::FeedScene->new->db_name;
    File::Path::remove_tree 'cache/foo';
};

# Load some feed data.
my $uri = 'file://localhost' . File::Spec->rel2abs('t/data');

my $conn = App::FeedScene->new->conn;
$conn->txn(sub {
    my $sth = shift->prepare(q{
        INSERT INTO feeds (url, id, portal)
        VALUES(?, ?, ?)
    });
    for my $spec (
        [ 'simple.atom',     0 ],
        [ 'enclosures.atom', 1 ],
    ) {
        $sth->execute("$uri/$spec->[0]", @{$spec});
    }
});

# Load the entries.
for my $p (0..1) {
    App::FeedScene::EntryUpdater->new(
        app    => 'foo',
        portal => $p,
    )->run;
}

ok my $gen = $CLASS->new(
    app => 'foo',
    dir => 'bar',
), 'Create generator object';
isa_ok $gen, $CLASS, 'It';
ok !$gen->strict, 'Should not be strict';
is $gen->app, 'foo', 'Its app attribute should be correct';
is $gen->dir, 'bar', 'Its dir attribute should be correct';
is $gen->filename, $gen->app . '.xml', 'Its filename should be correct';
is $gen->filepath, File::Spec->catfile($gen->dir, $gen->filename),
    'Its file path should be correct';
is $gen->id, "tag:$domain,2010:feedscene/feeds/" . $gen->filename,
    'Its id should be correct';
is $gen->link, "http://$domain/feeds/" . $gen->filename,
    'Its link should be correct';

# Try default values.
ok $gen = $CLASS->new(app => 'foo'), 'Create another with default dir';
ok !$gen->strict, 'Should not be strict';
is $gen->app, 'foo', 'Its app attribute should be correct';
is $gen->dir, File::Spec->rel2abs('feeds'),
    'The dir attribute should be the default';
is $gen->filename, $gen->app . '.xml', 'Its filename should be correct';
is $gen->filepath, File::Spec->catfile($gen->dir, $gen->filename),
    'Its file path should be correct';
is $gen->id, "tag:$domain,2010:feedscene/feeds/" . $gen->filename,
    'Its id should be correct';
is $gen->link, "http://$domain/feeds/" . $gen->filename,
    'Its link should be correct';

##############################################################################
# Test non-strict output.
END { File::Path::remove_tree($gen->dir) if -d $gen->dir; }
ok $gen->go, 'Go!';
my $tx = Test::XPath->new(
    file  => $gen->filepath,
    xmlns => {
        'a'  => 'http://www.w3.org/2005/Atom',
        'fs' => "http://$domain/2010/FeedScene",
    },
);

test_root_metadata($tx);
test_entries($tx, 0);

# Check fs:sources element.
$tx->is('count(/a:feed/fs:sources)', 1, 'Should have 1 sources element');
$tx->ok('/a:feed/fs:sources', 'Should have sources', sub {
    $_->is('count(./fs:source)', 2, 'Should have two sources');
    $_->ok('./fs:source[1]', 'First source', sub {
        $_->is('count(./*)', 6, 'Should have five source subelements');
        $_->is('./fs:id', 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6', 'ID should be correct');
        $_->is('./fs:link/@rel', 'self', 'Should have self link');
        $_->is('./fs:link/@href', "$uri/simple.atom", 'Link URL should be correct');
        $_->is('./fs:title', 'Simple Atom Feed', 'Title should be correct');
        $_->is('./fs:subtitle', 'Witty and clever', 'Subtitle should be correct');
        $_->is('./fs:rights', '© 2010 Big Fat Example', 'Rights should be correct');
        $_->is('./fs:icon', "$icon_url=example.com", 'Icon should be correct');
    });
    $_->ok('./fs:source[2]', 'Second source', sub {
        $_->is('count(./*)', 6, 'Should have five source subelements');
        $_->is('./fs:id', 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af7', 'ID should be correct');
        $_->is('./fs:link/@rel', 'self', 'Should have self link');
        $_->is('./fs:link/@href', "$uri/enclosures.atom", 'Link URL should be correct');
        $_->is('./fs:title', 'Enclosures Atom Feed', 'Title should be correct');
        $_->is('./fs:subtitle', '', 'Subtitle should be correct');
        $_->is('./fs:rights', '', 'Rights should be correct');
        $_->is('./fs:icon', "$icon_url=example.com", 'Icon should be correct');
    });
});

##############################################################################
# Test strict output.
ok $gen = $CLASS->new(app => 'foo', strict => 1), 'Create strict generator';
ok $gen->strict, 'It Should be strict';
ok $gen->go, 'Go strict!';

$tx = Test::XPath->new(
    file  => $gen->filepath,
    xmlns => {
        'a'  => 'http://www.w3.org/2005/Atom',
        'fs' => "http://$domain/2010/FeedScene",
    },
);

test_root_metadata($tx);
test_entries($tx, 1);

# Should have no fs:sources.
$tx->is('count(/a:feed/fs:sources)', 0, 'Should have no sources element');

sub test_root_metadata {
    my $tx = shift;
    $tx->is('count(/a:feed)', 1, 'Should have 1 feed element');
    # $tx->is(
    #     '/a:feed/@xmlns',
    #     'http://www.w3.org/2005/Atom',
    #     'Should have Atom namespace'
    # );

    # Check title element.
    $tx->is('count(/a:feed/a:title)', 1, 'Should have 1 title element');
    $tx->is('/a:feed/a:title', 'foo Feed', 'Title should be correct');

    # Check link element.
    $tx->is('count(/a:feed/a:link)', 1, 'Should have 1 link element');
    $tx->is(
        '/a:feed/a:link[@rel="self"]/@href',
        "http://$domain/feeds/foo.xml",
        'link rel="self" element value should be correct'
    );

    # Check updated element.
    $tx->is('count(/a:feed/a:updated)', 1, 'Should have 1 updated element');
    $tx->is('/a:feed/a:updated', $time, 'Updated value should be correct');

    # Check rights element.
    $tx->is('count(/a:feed/a:rights)', 1, 'Should have 1 rights element');
    $tx->is(
        '/a:feed/a:rights',
        "© 2010 $company and others",
        'Rights should be correct'
    );

    # Check generator element.
    $tx->is(
        'count(/a:feed/a:generator)',
        1,
        'Should have 1 generator element'
    );
    $tx->is(
        '/a:feed/a:generator',
        'FeedScene',
        'Generator value should be correct'
    );
    $tx->is(
        '/a:feed/a:generator/@uri',
        "http://$domain/feedscene/",
        'Generator URI should be correct'
    );
    $tx->is(
        '/a:feed/a:generator/@version',
        App::FeedScene->VERSION,
        'Generator version should be correct'
    );

    # Check author element.
    $tx->is('count(/a:feed/a:author)', 1, 'Should have one author element');
    $tx->is('count(/a:feed/a:author/*)', 2, 'Should have one author subelements');
    $tx->is('count(/a:feed/a:author/a:name)', 1, 'Should have one author/name element');
    $tx->is('count(/a:feed/a:author/a:uri)', 1, 'Should have one author/uri element');
    $tx->is('/a:feed/a:author/a:name', $company, 'Should have author name');
    $tx->is('/a:feed/a:author/a:uri', "http://$domain/", 'Should have author URI');
}

sub test_entries {
    my ($tx, $strict) =@_;
    $tx->is('count(/a:feed/a:entry)', 13, 'Should have 13 entries' );
    my $scount = $strict ? 6 : 1;


    # Check the first entry.
    $tx->ok('/a:feed/a:entry[1]', 'Check first entry', sub {
        $_->is('count(./*)', 9, 'Should have 9 subelements');
        $_->is('./a:id', 'urn:uuid:e287d28b-5a4b-575c-b9da-d3dc894b9aa2', '...Entry ID');
        $_->is('./a:link[@rel="alternate"]/@href', 'http://example.com/story.html', '...Link');
        $_->is('./a:title', 'This is the title', '...Title');
        $_->is('./a:published', '2009-12-13T12:29:29Z', '...Published');
        $_->is('./a:updated', '2009-12-13T18:30:02Z', '...Updated');
        $_->is("./a:category[\@scheme='http://$domain/ns/portal']/\@term", 0, '...Portal');
        $_->is('./a:summary[@type="html"]', '<p>Summary of the story</p>', '...Summary');
        $_->ok('./a:author', '...Author', sub {
            $_->is('count(./*)', 1, '......Should have 1 author subelement');
            $_->is('./a:name', 'Ira Glass', '......Name');
        });
        $_->ok('./a:source', '...Source', sub {
            $_->is('count(./*)', $scount, "......Should have $scount subelements");
            $_->is('./a:id', 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6', '......ID');
            if ($strict) {
                # Confirm all other elments.
                $_->is('./a:link[@rel="self"]/@href', "$uri/simple.atom", '......Link');
                $_->is('./a:title', 'Simple Atom Feed', '......Title');
                $_->is('./a:subtitle', 'Witty and clever', '......Subtitle');
                $_->is('./a:rights', '© 2010 Big Fat Example', '......Rights');
                $_->is('./a:icon', "$icon_url=example.com", '......Icon');
            }
        });
    });

    # Look at the third entry, from portal 2, with an enclosure.
    $tx->ok('/a:feed/a:entry[3]', 'Check third entry', sub {
        $_->is('count(./*)', 10, 'Should have 10 subelements');
        $_->is('./a:id', 'urn:uuid:afac4e17-4775-55c0-9e61-30d7630ea909', '...Entry ID');
        $_->is('./a:link[@rel="alternate"]/@href', 'http://flickr.com/someimage', '...Link');
        $_->is('./a:title', 'This is the title', '...Title');
        $_->is('./a:published', '2009-12-13T08:29:29Z', '...Published');
        $_->is('./a:updated', '2009-12-13T08:29:29Z', '...Updated');
        $_->is("./a:category[\@scheme='http://$domain/ns/portal']/\@term", 1, '...Portal');
        $_->is('./a:summary[@type="html"]', '<p>Caption for the encosed image.</p>', '...Summary');
        $_->is('./a:link[@rel="enclosure"]/@type', 'image/jpeg', '...Enclosure type');
        $_->is(
            './a:link[@rel="enclosure"]/@href',
            'http://farm2.static.flickr.com/1169/4601733070_92cd987ff5_o.jpg',
            '...Enclosure link'
        );
        $_->ok('./a:source', '...Source', sub {
            $_->is('count(./*)', $scount, "......Should have $scount subelements");
            $_->is('./a:id', 'urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af7', '......ID');
            if ($strict) {
                # Confirm all other elments.
                $_->is('./a:link[@rel="self"]/@href', "$uri/enclosures.atom", '......Link');
                $_->is('./a:title', 'Enclosures Atom Feed', '......Title');
                $_->is('./a:subtitle', '', '......Subtitle');
                $_->is('./a:rights', '', '.....Rights');
                $_->is('./a:icon', "$icon_url=example.com", '......Icon');
            }
        });
    });

}

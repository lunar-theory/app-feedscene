use 5.12.0;
use Module::Build;

Module::Build->new(
    module_name        => 'App::FeedScene',
    license            => 'restrictive',
    configure_requires => {
        'Module::Build'     => '0.36',
        'Module::Build::DB' => '0.10',
    },
    build_requires     => {
        'Test::More'       => '0.70',
        'Test::Harness'    => '3.17',
        'Test::Exception'  => '0.29',
        'Test::File'       => '1.29',
        'Test::MockObject' => '1.09',
        'Test::MockModule' => '0.05',
        'Test::NoWarnings' => '1.01',
    },
    requires           => {
        'Class::XSAccessor'         => '1.05',
        'DBD::SQLite'               => '1.29',
        'DBI'                       => '1.608',
        'DBIx::Connector'           => '0.34',
        'Exception::Class::DBI'     => '1.00',
        'LWP'                       => '5.835',
        'LWP::UserAgent::WithCache' => '0.11',
        'perl'                      => 5.012,
        'Pod::Usage'                => '1.36',
        'Text::CSV_XS'              => '0.73',
        'Text::Markdown'            => '1.00',
        'XML::Feed'                 => '0.43',
        'XML::LibXML'               => '1.70',
    },
    recommends         => {
        'Test::Pod'           => '1.41',
#       'Test::Pod::Coverage' => '1.06',
    },
    meta_merge         => {
        resources => {
            homepage   => 'http://designsceneapp.com/',
            bugtracker => 'http://github.com/theory/app-feedscene/issues/',
            repository => 'http://github.com/theory/app-feedscene/tree/',
        }
    },
)->create_build_script;

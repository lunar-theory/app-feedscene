use lib '/Users/david/dev/github/module-build-db/lib';
use strict;
use warnings;
use Module::Build::DB;

Module::Build::DB->new(
    module_name        => 'App::FeedScene',
    license            => 'restrictive',
    script_files       => 'bin',
    db_config_key      => 'dbi',
    replace_config     => 'conf/dev.yml',
    db_client          => 'sqlite3',
    configure_requires => {
        'Module::Build'     => '0.36',
        'Module::Build::DB' => '0.10',
    },
    build_requires     => {
        'Module::Build::DB' => '0.10',
        'Test::MockModule'  => '0.05',
        'Test::More'        => '0.70',
        'Test::Harness'     => '3.18',
    },
    requires           => {
        'aliased'                           => '0.30',
        'DBD::SQLite'                       => '1.29',
        'DBI'                               => '1.608',
        'DBIx::Connector'                   => '0.34',
        'Encode'                            => '2.12',
        'Exception::Class::DBI'             => '1.00',
        'Getopt::Long'                      => '2.34',
        'perl'                              => 5.012,
        'Pod::Usage'                        => '1.36',
        'YAML::Syck'                        => '1.07',
    },
    recommends         => {
        'Test::Pod'              => '1.20',
        'Test::Pod::Coverage'    => '1.06',
    },
    meta_merge         => {
        resources => {
            homepage    => 'http://designsceneapp.com/',
            bugtracker  => 'http://github.com/theory/app-feedscene/issues/',
            repository  => 'http://github.com/theory/app-feedscene/tree/',
        }
    },
)->create_build_script;

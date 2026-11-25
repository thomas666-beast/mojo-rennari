use 5.020;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Mojo::Rennari',
    VERSION_FROM     => 'lib/Mojo/Rennari.pm',
    ABSTRACT         => 'Real-time event transport for Mojolicious (Old Norse: rennari, messenger)',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.020',
    EXE_FILES        => ['script/mojo-rennari'],
    PREREQ_PM        => {
        'Mojolicious'       => '9.00',
        'Data::MessagePack' => '0',
        'YAML::PP'          => '0',
    },
    TEST_REQUIRES    => {
        'Test::More'        => '0',
    },
);

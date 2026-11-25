use 5.020;
use strict;
use warnings;

use Test::More;
use Config;
use Cwd qw(abs_path getcwd);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use IO::Select;
use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess;
use Mojo::Rennari ();
use Mojo::Server::Daemon;
use Symbol qw(gensym);

sub run_perl {
    my (@args) = @_;

    my $error = gensym;

    my $pid = open3(
        my $in,
        my $out,
        $error,
        $^X,
        @args,
    );

    close $in;

    # Drain both pipes concurrently to avoid deadlocks when one fills.
    my $selector = IO::Select->new($out, $error);

    my ($stdout, $stderr) = ('', '');
    my $out_fd = fileno $out;

    while ($selector->count) {
        for my $handle ($selector->can_read) {
            my $read = sysread($handle, my $chunk, 8192);

            unless (defined $read) {
                next if $!{EINTR};
                die "Cannot read subprocess output: $!";
            }

            unless ($read) {
                $selector->remove($handle);
                close $handle;
                next;
            }

            if (fileno($handle) == $out_fd) {
                $stdout .= $chunk;
            }
            else {
                $stderr .= $chunk;
            }
        }
    }

    my $waited;

    do {
        $waited = waitpid $pid, 0;
    } while ($waited == -1 && $!{EINTR});

    die "Cannot wait for subprocess $pid: $!"
        if $waited == -1;

    my $status = $?;

    return ($status, $stdout, $stderr);
}

sub write_file {
    my ($file, $text) = @_;

    open my $fh, '>', $file
        or die "Cannot write $file: $!";

    print {$fh} $text
        or die "Cannot write $file: $!";

    close $fh
        or die "Cannot close $file: $!";

    return;
}

sub read_file {
    my ($file) = @_;

    open my $fh, '<', $file
        or die "Cannot read $file: $!";

    my $text = do {
        local $/;
        scalar <$fh>;
    };

    close $fh
        or die "Cannot close $file: $!";

    return $text;
}

sub integration_diagnostics {
    my ($label, $failure, $code, $output, $error) = @_;

    diag(
        "$label integration diagnostics:\n",
        "  subprocess failure: ",
        defined($failure) ? $failure : '(none)',
        "\n",
        "  raw process status: ",
        defined($code) ? $code : '(undefined)',
        "\n",
        "  exit code: ",
        defined($code) ? ($code >> 8) : '(undefined)',
        "\n",
        "  signal: ",
        defined($code) ? ($code & 127) : '(undefined)',
        "\n",
        "  stdout:\n",
        defined($output) && length($output)
            ? $output
            : "(empty)\n",
        "  stderr:\n",
        defined($error) && length($error)
            ? $error
            : "(empty)\n",
    );

    return;
}

my $distribution = getcwd();

local $0 = abs_path($0);

my $lib = '-I' . abs_path(
    -d 'blib/lib' ? 'blib/lib' : 'lib'
);

my $script = abs_path(
    -f 'blib/script/mojo-rennari'
        ? 'blib/script/mojo-rennari'
        : 'script/mojo-rennari'
);

my $temp = tempdir(CLEANUP => 1);

END {
    chdir $distribution if defined $distribution;
}

chdir $temp
    or die "Cannot enter temp folder: $!";

local %ENV = %ENV;

delete @ENV{
    qw(
        RENNARI_TOKEN
        RENNARI_SERIALIZER
        RENNARI_URL
        TOKEN_APP
        MOJO_HOME
    )
};

local $ENV{MOJO_MODE} = 'development';

# ----------------------------------------------------------------------
# Generator help and version
# ----------------------------------------------------------------------

my ($status, $stdout, $stderr) = run_perl(
    $lib,
    $script,
    'help',
);

is $status, 0, 'generator help succeeds';

like $stdout,
    qr/generate lite.*\n.*generate app/,
    'help includes both generators';

($status, $stdout, $stderr) = run_perl(
    $lib,
    $script,
    '--version',
);

is $status, 0, 'version succeeds';

is $stdout,
    "mojo-rennari $Mojo::Rennari::VERSION\n",
    'reports distribution version';

# ----------------------------------------------------------------------
# Lite generation
# ----------------------------------------------------------------------

($status, $stdout, $stderr) = run_perl(
    $lib,
    $script,
    'generate',
    'lite',
    'demo',
);

is $status, 0, 'generates Lite'
    or diag $stderr;

like $stdout,
    qr/Created 'demo'/,
    'reports Lite directory';

unlike $stdout,
    qr/\bexport\s+(?:RENNARI_TOKEN|TOKEN_APP)/,
    'no token export instructions';

for my $file (
    qw(
        server.pl
        client.pl
        server.yml
        client.yml
        cpanfile
        .gitignore
        README.md
    )
) {
    ok -f "demo/$file", "Lite creates $file";
}

SKIP: {
    skip 'Windows does not use Unix executable bits', 1
        if $^O eq 'MSWin32';

    ok(
        -x 'demo/server.pl' && -x 'demo/client.pl',
        'Lite scripts executable',
    );
}

# ----------------------------------------------------------------------
# Collision protection and invalid names
# ----------------------------------------------------------------------

($status, $stdout, $stderr) = run_perl(
    $lib,
    $script,
    'generate',
    'lite',
    'demo',
);

is $status, 1 << 8, 'existing destination refused';

like $stderr,
    qr/not overwritten/,
    'clear collision diagnostic';

ok(
    -f 'demo/server.pl' && -f 'demo/client.pl',
    'collision preserves scripts',
);

for my $bad (
    ['lite', '../elsewhere'],
    ['app', 'Broken::../Path'],
    ['unknown'],
) {
    ($status, $stdout, $stderr) = run_perl(
        $lib,
        $script,
        'generate',
        @$bad,
    );

    is $status, 2 << 8, "usage error for @$bad";
}

# ----------------------------------------------------------------------
# Structured App generation
# ----------------------------------------------------------------------

($status, $stdout, $stderr) = run_perl(
    $lib,
    $script,
    'generate',
    'app',
    'Acme::Chat',
);

is $status, 0, 'generates structured App'
    or diag $stderr;

like $stdout,
    qr/Created 'acme-chat'/,
    'package maps to directory';

for my $file (
    'cpanfile',
    'README.md',
    '.gitignore',
    'server/server.yml',
    'client/client.yml',
    'server/script/server',
    'client/script/client',
    'server/lib/Acme/Chat/Server.pm',
    'server/lib/Acme/Chat/Server/Events.pm',
    'client/lib/Acme/Chat/Client.pm',
    'client/lib/Acme/Chat/Client/Events.pm',
) {
    ok -f "acme-chat/$file", "App creates $file";
}

# ----------------------------------------------------------------------
# Configuration and dependency files
# ----------------------------------------------------------------------

for my $root ('demo', 'acme-chat') {
    like read_file("$root/cpanfile"),
        qr/YAML::PP/,
        "$root declares YAML loader";

    like read_file("$root/.gitignore"),
        qr/^server\.yml$/m,
        "$root ignores server config";

    like read_file("$root/.gitignore"),
        qr/^client\.yml$/m,
        "$root ignores client config";
}

for my $file (
    'demo/client.yml',
    'acme-chat/client/client.yml',
) {
    my $text = read_file($file);

    like $text,
        qr/^TOKEN_APP:[ \t]*CHANGE_ME[ \t]*$/m,
        "$file requires private credential";

    unlike $text,
        qr/^\s*(?:room|message|duration):/m,
        "$file contains no demo workflow settings";
}

# ----------------------------------------------------------------------
# Client help, missing credentials and usage errors
# ----------------------------------------------------------------------

for my $client (
    'demo/client.pl',
    'acme-chat/client/script/client',
) {
    ($status, $stdout, $stderr) = run_perl(
        $lib,
        $client,
        '--help',
    );

    is $status, 0, "$client help works without credentials"
        or diag $stderr;

    like $stdout,
        qr/TOKEN_APP/,
        "$client help explains application access";

    like $stdout,
        qr/client(?:\/client)?\.yml/,
        "$client help identifies YAML";

    ($status, $stdout, $stderr) = run_perl(
        $lib,
        $client,
    );

    is $status,
        2 << 8,
        "$client rejects unconfigured token";

    like $stderr,
        qr/TOKEN_APP/,
        "$client diagnostic identifies setting";

    ($status, $stdout, $stderr) = run_perl(
        $lib,
        $client,
        '--unknown',
    );

    is $status,
        2 << 8,
        "$client rejects unknown arguments";

    like $stderr,
        qr/Usage:/,
        "$client gives usage for unknown arguments";
}

# ----------------------------------------------------------------------
# Aliases and default names
# ----------------------------------------------------------------------

($status, $stdout, $stderr) = run_perl(
    $lib,
    $script,
    'generate',
    'lite_app',
);

is $status, 0, 'lite_app alias works'
    or diag $stderr;

ok -f 'rennari_lite/client.pl',
    'Lite default name works';

($status, $stdout, $stderr) = run_perl(
    $lib,
    $script,
    'generate',
    'app',
);

is $status, 0, 'App default works'
    or diag $stderr;

ok -f 'rennari_app/server/lib/RennariApp/Server.pm',
    'App default package works';

# ----------------------------------------------------------------------
# Real generated-server and generated-client integration
# ----------------------------------------------------------------------

SKIP: {
    skip 'loopback runner integration uses native fork', 8
        unless $Config{d_fork} && !$Config{d_pseudofork};

    my $token = 'test-only-application-token-1234567890';

    for my $case (
        [
            'Lite',
            'demo/server.pl',
            'demo/client.pl',
            'demo/server.yml',
            'demo/client.yml',
            'msgpack',
        ],
        [
            'App',
            'acme-chat/server/script/server',
            'acme-chat/client/script/client',
            'acme-chat/server/server.yml',
            'acme-chat/client/client.yml',
            'json',
        ],
    ) {
        my (
            $label,
            $server,
            $client,
            $server_yaml,
            $client_yaml,
            $serializer,
        ) = @$case;

        write_file(
            $server_yaml,
            "TOKEN_APP: $token\n"
                . "serializer: $serializer\n",
        );

        ($status, $stdout, $stderr) = run_perl(
            $lib,
            $server,
            'routes',
        );

        is $status,
            0,
            "$label runner starts Mojolicious CLI"
            or diag $stderr;

        like $stdout,
            qr{/ws\b},
            "$label registers WebSocket route";

        my $daemon = Mojo::Server::Daemon->new(
            listen => ['http://127.0.0.1:0'],
            silent => 1,
        );

        my $loaded = eval {
            if ($label eq 'Lite') {
                $daemon->load_app(abs_path($server));
            }
            else {
                local @INC = (
                    abs_path('acme-chat/server/lib'),
                    @INC,
                );

                $daemon->build_app('Acme::Chat::Server');
            }

            $daemon->app->log->level('fatal');
            $daemon->start;

            1;
        };

        unless ($loaded) {
            my $load_error = $@;

            eval { $daemon->stop };

            fail "$label starts for integration";
            diag $load_error;

            fail "$label completes example round trip";

            next;
        }

        my $url = 'ws://127.0.0.1:'
            . $daemon->ports->[0]
            . '/ws';

        write_file(
            $client_yaml,
            "url: $url\n"
                . "TOKEN_APP: $token\n"
                . "serializer: $serializer\n",
        );

        my $client_path = abs_path($client);

        # The generated client intentionally stays connected.
        #
        # This test-only wrapper observes the real generated handlers'
        # output and interrupts the client after both expected responses.
        #
        # The fallback timeout belongs to the test harness, not the
        # generated application or its YAML configuration.
        my $wrapper = q{
            use strict;
            use warnings;
            use IO::Handle;
            use Mojo::IOLoop;

            package GeneratorTestOutput;

            sub TIEHANDLE {
                my ($class, $real) = @_;

                return bless {
                    real            => $real,
                    tail            => '',
                    stop_scheduled  => 0,
                }, $class;
            }

            sub PRINT {
                my ($self, @parts) = @_;

                my $text = join '', @parts;

                print {$self->{real}} $text;

                $self->{tail} .= $text;

                if (
                    !$self->{stop_scheduled}
                    && $self->{tail} =~ /pong: 1/
                    && $self->{tail} =~ /reply: user_id=1 name=demo/
                ) {
                    $self->{stop_scheduled} = 1;

                    Mojo::IOLoop->next_tick(sub {
                        kill 'INT', $$;
                    });
                }

                return 1;
            }

            package main;

            open my $real, '>&', \*STDOUT
                or die "Cannot duplicate stdout: $!";

            $real->autoflush(1);

            tie *STDOUT, 'GeneratorTestOutput', $real;

            Mojo::IOLoop->timer(10 => sub {
                print STDERR "Generated client timed out\n";
                exit 124;
            });

            my $file = shift @ARGV;

            die "Missing generated client path\n"
                unless defined $file;

            # Emulate direct execution of the generated runner.
            # Under perl -e, FindBin otherwise resolves the wrong path.
            $0 = $file;

            require FindBin;
            FindBin::again();

            do $file;

            die(
                $@
                || $!
                || "Client runner returned unexpectedly\n"
            );
        };

        my ($failure, $code, $output, $error);

        my $job = Mojo::IOLoop::Subprocess->new;

        $job->run(
            sub {
                return run_perl(
                    $lib,
                    '-e',
                    $wrapper,
                    $client_path,
                );
            },
            sub {
                (
                    undef,
                    $failure,
                    $code,
                    $output,
                    $error,
                ) = @_;

                Mojo::IOLoop->stop;
            },
        );

        Mojo::IOLoop->start;

        $daemon->stop;

        my $client_ok =
            !$failure
            && defined($code)
            && $code == 0;

        ok $client_ok,
            "$label client exits cleanly after $serializer responses";

        unless ($client_ok) {
            integration_diagnostics(
                $label,
                $failure,
                $code,
                $output,
                $error,
            );
        }

        like $output // '',
            qr/pong: 1\n.*reply: user_id=1 name=demo\n/s,
            "$label exercises generated ping and whoami examples";
    }
}

chdir $distribution
    or die "Cannot restore working directory: $!";

done_testing;

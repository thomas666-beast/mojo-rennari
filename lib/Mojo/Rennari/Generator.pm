package Mojo::Rennari::Generator;
use Mojo::Base -strict;

use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use File::Spec;
use Mojo::Loader qw(data_section);
use Mojo::Rennari ();
use Mojo::Util qw(decamelize);

sub _usage {
    return <<'USAGE';
Usage:
  mojo-rennari generate lite [NAME]
  mojo-rennari generate app [PACKAGE]
  mojo-rennari --version
  mojo-rennari help

Lite creates readable server.pl and client.pl scripts with separate YAML
configuration files in NAME (default: rennari_lite).

App takes a Perl package name, such as MyApp or Acme::Chat (default:
RennariApp), and creates separate server/ and client/ folders.

Both styles use TOKEN_APP from YAML. No token exports are required.
Existing destinations are never replaced.
USAGE
}

sub run {
    my ($class, @args) = @_;

    if (@args == 1 && $args[0] =~ /\A(?:help|--help|-h)\z/) {
        print _usage();
        return 0;
    }

    if (@args == 1 && $args[0] =~ /\A(?:version|--version)\z/) {
        print "mojo-rennari $Mojo::Rennari::VERSION\n";
        return 0;
    }

    my ($command, $type, $name) = @args;

    unless (
        @args >= 2
        && @args <= 3
        && $command eq 'generate'
        && ($type eq 'lite' || $type eq 'lite_app' || $type eq 'app')
    ) {
        print STDERR _usage();
        return 2;
    }

    $type = 'lite' if $type eq 'lite_app';
    $name //= $type eq 'lite' ? 'rennari_lite' : 'RennariApp';

    my ($dir, @files, $server, $client);

    if (
        $type eq 'lite'
        && $name =~ /\A[A-Za-z][A-Za-z0-9_-]{0,79}\z/
    ) {
        $dir    = $name;
        $server = 'server.pl';
        $client = 'client.pl';

        @files = (
            [$server,      'lite-server', 1],
            [$client,      'lite-client', 1],
            ['server.yml', 'server-yaml'],
            ['client.yml', 'client-yaml'],
            ['cpanfile',   'cpanfile'],
            ['.gitignore', 'gitignore'],
            ['README.md',  'lite-readme'],
        );
    }
    elsif (
        $type eq 'app'
        && length($name) <= 80
        && $name =~ /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/
    ) {
        $dir = decamelize($name);

        my $path = join '/', split /::/, $name;

        $server = 'server/script/server';
        $client = 'client/script/client';

        @files = (
            ['README.md',        'app-readme'],
            ['cpanfile',         'cpanfile'],
            ['.gitignore',       'gitignore'],
            ['server/server.yml', 'server-yaml'],
            ['client/client.yml', 'client-yaml'],

            [$server, 'app-server-runner', 1],
            ["server/lib/$path/Server.pm", 'app-server'],
            ["server/lib/$path/Server/Events.pm", 'app-events'],

            [$client, 'app-client-runner', 1],
            ["client/lib/$path/Client.pm", 'app-client'],
            ["client/lib/$path/Client/Events.pm", 'app-client-events'],
        );
    }
    else {
        print STDERR $type eq 'lite'
            ? "mojo-rennari: invalid Lite project name "
                . "(try demo or chat_demo)\n"
            : "mojo-rennari: invalid App package name "
                . "(try MyApp or Acme::Chat)\n";

        return 2;
    }

    my %partials = map {
        $_ => _template($_)
    } qw(
        config_loader
        server_config
        events
        client_events
        client_run
    );

    my @output;

    for my $file (@files) {
        my ($relative, $section, $executable) = @$file;

        my $text = _template($section);

        $text =~ s{
            __PART_([a-z_]+)__
        }{
            exists $partials{$1}
                ? $partials{$1}
                : die "Unknown generator partial '$1'\n"
        }gex;

        $text =~ s/__APP__/$name/g;
        $text =~ s/__VERSION__/$Mojo::Rennari::VERSION/g;

        push @output, [$relative, $text, $executable];
    }

    my $created = eval {
        _write_project($dir, \@output);
        1;
    };

    unless ($created) {
        print STDERR "mojo-rennari: $@";
        return 1;
    }

    print
        "Created '$dir'.\n",
        "Edit the server and client YAML files and set the same private ",
        "TOKEN_APP in both.\n",
        "Then run these from '$dir' in separate terminals:\n",
        "  perl $server daemon -l http://127.0.0.1:3000\n",
        "  perl $client\n",
        "No token exports are required. See README.md.\n";

    return 0;
}

sub _template {
    my ($name) = @_;

    return data_section(__PACKAGE__, $name)
        // die "Missing generator template '$name'\n";
}

sub _write_project {
    my ($root, $files) = @_;

    mkdir $root
        or die "cannot create '$root' "
            . "(existing destinations are not overwritten): $!\n";

    my %created = ($root => 1);
    my @dirs    = ($root);
    my @written;

    my $ok = eval {
        for my $file (@$files) {
            my ($relative, $text, $executable) = @$file;

            my @parts = split '/', $relative;
            my $name  = pop @parts;
            my $parent = $root;

            for my $part (@parts) {
                $parent = File::Spec->catdir($parent, $part);

                next if $created{$parent};

                mkdir $parent
                    or die "cannot create directory '$parent': $!\n";

                $created{$parent} = 1;
                push @dirs, $parent;
            }

            my $path = File::Spec->catfile($parent, $name);

            my $mode = $relative =~ /\.yml\z/
                ? 0600
                : $executable
                    ? 0777
                    : 0666;

            sysopen my $handle, $path, O_WRONLY | O_CREAT | O_EXCL, $mode
                or die "cannot create '$path': $!\n";

            push @written, $path;

            binmode $handle, ':raw'
                or die "cannot set file mode for '$path': $!\n";

            print {$handle} $text
                or die "cannot write '$path': $!\n";

            close $handle
                or die "cannot close '$path': $!\n";
        }

        1;
    };

    unless ($ok) {
        my $error = $@;

        unlink $_ for reverse @written;
        rmdir $_ for reverse @dirs;

        die $error;
    }

    return;
}

1;

__DATA__

@@ lite-server
#!/usr/bin/env perl
use 5.020;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojolicious::Lite;
use Mojo::Rennari::Server;
use Mojo::Util qw(secure_compare);
use YAML::PP;

# Load connection and application-access settings.
my $config = load_config("$FindBin::Bin/server.yml");

# Create the server and configure authentication.
my $rennari = build_server($config, app->log);

# Register lifecycle callbacks and application events.
register_events($rennari);

# WebSocket endpoint.
websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};

app->start unless caller;
app;

__PART_config_loader__
__PART_server_config__
__PART_events__

@@ lite-client
#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::IOLoop;
use Mojo::Rennari::Client;
use YAML::PP;

# Help must work without a configuration file or credentials.
if (@ARGV == 1 && $ARGV[0] =~ /\A(?:--help|-h)\z/) {
    print
        "Usage: $0 [--help]\n",
        "\n",
        "Configure url, TOKEN_APP and serializer in client.yml.\n",
        "TOKEN_APP must match the server.\n",
        "User authentication is implemented separately in your application.\n",
        "No token environment exports are required.\n";

    exit 0;
}

if (@ARGV) {
    print STDERR "Usage: $0 [--help]\n";
    exit 2;
}

my $config = eval {
    load_config("$FindBin::Bin/client.yml");
};

unless ($config) {
    print STDERR $@;
    exit 2;
}

exit run_client($config, \&register_events);

__PART_config_loader__
__PART_client_events__
__PART_client_run__

@@ app-server-runner
#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Mojolicious::Commands;

Mojolicious::Commands->start_app('__APP__::Server');

@@ app-server
package __APP__::Server;
use Mojo::Base 'Mojolicious';
use Mojo::Rennari::Server;
use Mojo::Util qw(secure_compare);
use YAML::PP;
use __APP__::Server::Events ();

sub startup {
    my ($app) = @_;

    my $config = load_config(
        $app->home->child('server.yml')->to_string
    );

    my $rennari = build_server($config, $app->log);

    __APP__::Server::Events::register_events($rennari);

    $app->routes->websocket('/ws')->to(cb => sub {
        my $c = shift;
        $rennari->websocket_route($c);
    });
}

__PART_config_loader__
__PART_server_config__

1;

@@ app-events
package __APP__::Server::Events;
use Mojo::Base -strict;

__PART_events__

1;

@@ app-client-runner
#!/usr/bin/env perl
use 5.020;
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use __APP__::Client ();

exit __APP__::Client->run("$RealBin/../client.yml", @ARGV);

@@ app-client
package __APP__::Client;
use Mojo::Base -strict;
use Mojo::IOLoop;
use Mojo::Rennari::Client;
use YAML::PP;
use __APP__::Client::Events ();

sub run {
    my ($class, $file, @args) = @_;

    # Process help before reading configuration.
    if (@args == 1 && $args[0] =~ /\A(?:--help|-h)\z/) {
        print
            "Usage: $0 [--help]\n",
            "\n",
            "Configure url, TOKEN_APP and serializer in client/client.yml.\n",
            "TOKEN_APP must match the server.\n",
            "User authentication is implemented separately in your application.\n",
            "No token environment exports are required.\n";

        return 0;
    }

    if (@args) {
        print STDERR "Usage: $0 [--help]\n";
        return 2;
    }

    my $config = eval {
        load_config($file);
    };

    unless ($config) {
        print STDERR $@;
        return 2;
    }

    return run_client(
        $config,
        \&__APP__::Client::Events::register_events,
    );
}

__PART_config_loader__
__PART_client_run__

1;

@@ app-client-events
package __APP__::Client::Events;
use Mojo::Base -strict;

__PART_client_events__

1;

@@ config_loader
sub load_config {
    my ($file) = @_;

    my $config = eval {
        YAML::PP->new(schema => ['JSON'])->load_file($file);
    };

    die "Cannot load YAML configuration '$file'\n" if $@;

    die "Configuration '$file' must contain a mapping\n"
        unless ref $config eq 'HASH';

    my $token = $config->{TOKEN_APP};

    die "Set TOKEN_APP in '$file' to a private token "
        . "(32-256 letters/numbers/._~-)\n"
        unless defined $token
            && !ref $token
            && $token =~ /\A[A-Za-z0-9._~-]{32,256}\z/
            && $token ne 'CHANGE_ME';

    my $serializer = $config->{serializer} // 'msgpack';

    die "Configuration '$file': serializer must be msgpack or json\n"
        unless !ref $serializer
            && $serializer =~ /\A(?:msgpack|json)\z/;

    $config->{serializer} = $serializer;

    return $config;
}

@@ server_config
sub build_server {
    my ($config, $logger) = @_;

    return Mojo::Rennari::Server->new(
        serializer => $config->{serializer},
        logger     => $logger,

        auth_cb => sub {
            my $c = shift;

            # Application access:
            # require the shared application credential from YAML.
            my $provided = $c->req->headers->header(
                'X-Rennari-App-Token'
            ) // '';

            return undef
                unless secure_compare($provided, $config->{TOKEN_APP});

            # USER AUTHENTICATION GOES HERE.
            #
            # Validate your user's session or Authorization header.
            # Return that user's identity on success.
            # Return undef to reject authentication.
            #
            # TOKEN_APP is an application credential, not a user identity.
            #
            # Example integration with your own authentication service:
            #
            # my $user = ...;
            # return undef unless $user;
            #
            # return {
            #     id      => "$user->{id}",
            #     user_id => $user->{id},
            #     name    => $user->{name},
            # };

            # Demonstration identity only.
            # Replace this before using real user accounts.
            return {
                id      => 'demo-user',
                user_id => 1,
                name    => 'demo',
            };
        },
    );
}

@@ events
sub register_events {
    my ($rennari) = @_;

    # Connection lifecycle.

    $rennari->on_connect(sub {
        my ($c, $identity) = @_;

        $c->app->log->info(
            "connected: $identity->{name}"
        );
    });

    $rennari->on_disconnect(sub {
        my ($c, $identity) = @_;

        $c->app->log->info(
            "disconnected: $identity->{name}"
        );
    });

    $rennari->on_error(sub {
        my ($c, $kind, $detail) = @_;

        $c->app->log->warn(
            "protocol error: $kind"
        );
    });

    # Example: explicitly send a named event to this client.

    $rennari->on(ping => sub {
        my ($c, $payload) = @_;

        $c->rennari->send_to_self(
            pong => {got => $payload}
        );

        # Avoid sending an additional automatic reply.
        return undef;
    });

    # Example: return data to send an automatic 'reply' event.

    $rennari->on(whoami => sub {
        my $c = shift;

        my $identity = $c->stash('rennari_identity');

        return {
            user_id => $identity->{user_id},
            name    => $identity->{name},
        };
    });

    # Add your application events here.
    #
    # $rennari->on(your_event => sub {
    #     my ($c, $payload) = @_;
    #
    #     return {error => 'object required'}
    #         unless ref $payload eq 'HASH';
    #
    #     # Validate the payload and check user permissions here.
    #
    #     return {ok => 1};
    # });

    # Room example:
    #
    # $rennari->on(join_room => sub {
    #     my ($c, $payload) = @_;
    #
    #     return {error => 'object required'}
    #         unless ref $payload eq 'HASH';
    #
    #     my $room = $payload->{room};
    #
    #     return {error => 'invalid room'}
    #         unless defined $room
    #             && !ref $room
    #             && $room =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    #
    #     # Authorize this user's access BEFORE joining the room.
    #
    #     $c->rennari->join($room);
    #
    #     return {joined => $room};
    # });
}

@@ client_events
sub register_events {
    my ($client) = @_;

    # The connection is ready for application events.

    $client->on(connect => sub {
        my ($client) = @_;

        say 'Connected';

        # Working examples.
        # Replace these with your application's startup behavior.
        $client->send(ping   => {n => 1});
        $client->send(whoami => {});
    });

    # Receive a named event.

    $client->on(pong => sub {
        my ($client, $payload) = @_;

        return unless ref $payload eq 'HASH';
        return unless ref $payload->{got} eq 'HASH';

        say 'pong: ' . ($payload->{got}{n} // '?');
    });

    # Receive automatic server replies.

    $client->on(reply => sub {
        my ($client, $payload) = @_;

        return unless ref $payload eq 'HASH';

        if (exists $payload->{error}) {
            say 'server error: ' . ($payload->{error} // 'unknown');
            return;
        }

        if (exists $payload->{name}) {
            say
                'reply: user_id=' . ($payload->{user_id} // '-')
                . ' name=' . ($payload->{name} // '-');

            return;
        }

        if (exists $payload->{joined}) {
            say 'joined room: ' . $payload->{joined};
            return;
        }

        say 'Reply received';
    });

    # Add your own incoming event handlers here.
    #
    # $client->on(your_event => sub {
    #     my ($client, $payload) = @_;
    #
    #     # Handle the event.
    # });
    #
    # To use the optional join_room example on the server, add this
    # send inside the existing connect handler:
    #
    # $client->send(join_room => {room => 'lobby'});
}

@@ client_run
sub run_client {
    my ($config, $register_events) = @_;

    my $url = $config->{url};

    unless (
        defined $url
        && !ref $url
        && $url =~ m{\Awss?://}
    ) {
        print STDERR "client.yml: url must start with ws:// or wss://\n";
        return 2;
    }

    my $client = Mojo::Rennari::Client->new(
        url        => $url,
        serializer => $config->{serializer},

        headers => {
            'X-Rennari-App-Token' => $config->{TOKEN_APP},

            # Add your user's authentication header if needed.
            # Obtain the user credential through your own login flow.
            #
            # Authorization => "Bearer $user_token",
        },
    );

    $register_events->($client);

    my $status  = 0;
    my $stopped = 0;

    my $stop = sub {
        my ($error) = @_;

        return if $stopped++;

        if (defined $error) {
            warn "$error\n";
            $status = 1;
        }

        Mojo::IOLoop->stop;
    };

    $client->on(error => sub {
        my ($client, $error) = @_;

        $stop->($error);
    });

    $client->on(disconnect => sub {
        my ($client, $info) = @_;

        say 'Disconnected';

        $stop->();
    });

    # Keep the client running until disconnected or interrupted.
    # No demonstration shutdown timer is installed.
    local $SIG{INT} = sub {
        $stop->();
    };

    local $SIG{TERM} = sub {
        $stop->();
    };

    my $started = eval {
        $client->connect(sub {
            my ($tx, $error) = @_;

            $stop->($error) if defined $error;
        });

        1;
    };

    $stop->('Could not start the WebSocket connection')
        unless $started;

    Mojo::IOLoop->start unless $stopped;

    $client->disconnect;

    return $status;
}

@@ server-yaml
# Private application-access configuration.
# Do not commit this file.
#
# Replace CHANGE_ME with a private, randomly generated token containing
# 32-256 letters, numbers, periods, underscores, tildes or hyphens.
#
# Configure the same TOKEN_APP in client.yml.
# User authentication is implemented separately in auth_cb.

TOKEN_APP: CHANGE_ME
serializer: msgpack

@@ client-yaml
# Private connection configuration.
# Do not commit this file.
#
# TOKEN_APP must match the server configuration.

url: ws://127.0.0.1:3000/ws
TOKEN_APP: CHANGE_ME
serializer: msgpack

@@ gitignore
# Local files containing credentials.
# These patterns also match files in subdirectories.
server.yml
client.yml

@@ cpanfile
requires 'perl', '5.020';
requires 'Mojo::Rennari', '__VERSION__';
requires 'YAML::PP';

@@ lite-readme
# Rennari Lite

A readable Mojolicious WebSocket server and Perl client.

## Install dependencies

Install the dependencies declared in cpanfile, including your local
Mojo::Rennari distribution and YAML::PP.

## Configure

Edit server.yml and client.yml.

Replace CHANGE_ME with the same private, randomly generated TOKEN_APP in
both files. Use 32-256 letters, numbers, periods, underscores, tildes or
hyphens.

No token environment exports are required.

Server configuration:

```yaml
TOKEN_APP: CHANGE_ME
serializer: msgpack
```

Client configuration:

```yaml
url: ws://127.0.0.1:3000/ws
TOKEN_APP: CHANGE_ME
serializer: msgpack
```

Both sides must use the same serializer: msgpack or json.

## Run

From this directory, in separate terminals:

```sh
perl server.pl daemon -l http://127.0.0.1:3000
perl client.pl
```

Client help works without configured credentials:

```sh
perl client.pl --help
```

If you change the server listen port, update the client URL.

## Where to develop

- server.pl: authentication, lifecycle callbacks, event handlers and /ws.
- client.pl: incoming event handlers, example sends and connection startup.
- server.yml: application credential and serializer.
- client.yml: URL, application credential and serializer.

The examples send ping and whoami and receive pong and reply.

Change the examples directly in Perl code. Do not put sample messages,
room names or demonstration timers into connection configuration.

The client stays connected until disconnected or interrupted with Ctrl+C.
It does not automatically reconnect. Idle connections may still be closed
by server or proxy inactivity timeouts.

An optional room-handler example is included as comments in the code.
Authorize room access before joining or broadcasting private data.

## Authentication

TOKEN_APP is sent through the X-Rennari-App-Token handshake header and
checked in auth_cb.

It checks possession of a shared application credential. It is not user
authentication or proof that a connection comes from an approved program.

The generated server returns a demonstration identity. Replace that part
of auth_cb with real user authentication before using user accounts.

Do not embed TOKEN_APP in public browser JavaScript or publicly distributed
clients and expect it to remain secret.

Use TLS through wss:// before sending credentials over a non-local network.

## Private configuration

The YAML files are ignored by Git and created with mode 0600, subject to
platform support and process permissions. Do not publish them.

Configuration paths are resolved relative to the scripts, not your shell's
working directory.

@@ app-readme
# __APP__

A modular Mojolicious WebSocket server and Perl client using Mojo::Rennari.

## Install dependencies

Install the dependencies declared in cpanfile, including your local
Mojo::Rennari distribution and YAML::PP.

## Configure

Edit:

- server/server.yml
- client/client.yml

Replace CHANGE_ME with the same private, randomly generated TOKEN_APP in
both files. Use 32-256 letters, numbers, periods, underscores, tildes or
hyphens.

No token environment exports are required.

Server configuration:

```yaml
TOKEN_APP: CHANGE_ME
serializer: msgpack
```

Client configuration:

```yaml
url: ws://127.0.0.1:3000/ws
TOKEN_APP: CHANGE_ME
serializer: msgpack
```

Both sides must use the same serializer: msgpack or json.

## Run

From this directory, in separate terminals:

```sh
perl server/script/server daemon -l http://127.0.0.1:3000
perl client/script/client
```

Client help works without configured credentials:

```sh
perl client/script/client --help
```

If you change the server listen port, update the client URL.

## Where to develop

### Server

- Server.pm under server/lib/ loads YAML, configures authentication and
  mounts the /ws route.
- Server/Events.pm registers lifecycle callbacks and application events.
- server/script/server launches the application.

### Client

- Client.pm under client/lib/ loads YAML and manages the connection.
- Client/Events.pm registers incoming events and sends examples on connect.
- client/script/client launches the client.

Normally, start in Events.pm when adding application behavior.

The examples send ping and whoami and receive pong and reply. Replace them
with your own on() callbacks and send() calls.

Keep application examples in Perl code, not connection YAML.

As the application grows, split related handlers into clearly named
modules and register them explicitly from Events.pm. No additional event
framework is required.

The client stays connected until disconnected or interrupted with Ctrl+C.
It does not automatically reconnect. Idle connections may still be closed
by server or proxy inactivity timeouts.

An optional room-handler example is included as comments in the server
events module. Authorize room access before joining or broadcasting
private data.

## Authentication

TOKEN_APP is sent through the X-Rennari-App-Token handshake header and
checked in auth_cb.

It checks possession of a shared application credential. It is not user
authentication or proof that a connection comes from an approved program.

The generated server returns a demonstration identity. Replace that part
of auth_cb with real user authentication before using user accounts.

Do not embed TOKEN_APP in public browser JavaScript or publicly distributed
clients and expect it to remain secret.

Use TLS through wss:// before sending credentials over a non-local network.

## Private configuration

The YAML files are ignored by Git and created with mode 0600, subject to
platform support and process permissions. Do not publish them.

The server resolves server.yml through the Mojolicious application home.
The client runner resolves client.yml relative to its own location.

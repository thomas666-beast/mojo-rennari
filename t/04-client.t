use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Client;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious::Lite;

my $server = Mojo::Rennari::Server->new(mock => 1, recovery => 1);

$server->on('smile' => sub {
    my ($c, $payload) = @_;
    return { ok => 1, got => $payload };
});

$server->on('ping' => sub { return undef });

$server->namespace('/chat')->on('hello' => sub {
    my ($c, $p) = @_;
    $c->rennari->send_to_self('hello_back', { from => '/chat', got => $p });
    return undef;
});

websocket '/ws' => sub {
    my $c = shift;
    $server->websocket_route($c);
};

my $daemon = Mojo::Server::Daemon->new(
    app    => app,
    listen => ['http://127.0.0.1:0'],
);
$daemon->start;
my $port = $daemon->ports->[0];
my $url  = "ws://127.0.0.1:$port/ws";

my ($reply, $connect_fired, $got, $ack_result, $ack_err, $disconnect_fired);
my $session_id;
my $last_offset;

my $client = Mojo::Rennari::Client->new(url => $url);
my $chat   = $client->of('/chat');

$client->on('connect' => sub { $connect_fired = 1 });
$client->on('disconnect' => sub { $disconnect_fired = 1 });
$client->on('reply' => sub { $reply = $_[1] });
$chat->on('hello_back' => sub { $got = $_[1] });

my $run_tests = sub {
    $session_id  = $client->session_id;
    $last_offset = $client->last_offset;

    $client->disconnect;
};

$client->connect(sub {
    my ($tx, $e) = @_;
    if ($e) {
        Mojo::IOLoop->stop;
        return;
    }

    Mojo::IOLoop->timer(0.1 => sub {
        $client->send('smile' => { n => 42 });
    });

    Mojo::IOLoop->timer(0.3 => sub {
        $chat->send('hello' => { n => 1 });
    });

    Mojo::IOLoop->timer(0.5 => sub {
        $client->emit_with_ack('ping' => { n => 1 }, sub {
            my ($result, $err) = @_;
            $ack_result = $result;
            $ack_err    = $err;
        });
    });

    Mojo::IOLoop->timer(1.0 => sub {
        $run_tests->();
    });

    Mojo::IOLoop->timer(1.3 => sub {
        Mojo::IOLoop->stop;
    });
});

Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

is $connect_fired, 1, 'connect local event fired';
is_deeply $reply, { ok => 1, got => { n => 42 } }, 'reply round-trip';
is_deeply $got, { from => '/chat', got => { n => 1 } }, 'namespace round-trip';
is $ack_err, undef, 'ack received without error';
ok $ack_result && $ack_result->{id}, 'ack carries an id';
ok defined $session_id, 'session id present';
ok $last_offset >= 0, 'offset tracked';
ok $disconnect_fired, 'disconnect local event fired';
ok !$client->is_connected, 'is_connected false after disconnect';

# --- mock guard ------------------------------------------------------
{
    local $ENV{MOJO_MODE} = 'production';
    my $c = Mojo::Rennari::Client->new(url => 'ws://x', mock => 1);
    eval { $c->_mock_enabled };
    like $@, qr/mock mode refused in production/, 'mock refused in production';
}

{
    local $ENV{MOJO_MODE} = 'production';
    my $c = Mojo::Rennari::Client->new(url => 'ws://x', mock => 1, force_mock => 1);
    ok $c->_mock_enabled, 'force_mock allows mock in production';
}

# --- send without connect dies --------------------------------------
my $orphan = Mojo::Rennari::Client->new(url => 'ws://x');
eval { $orphan->send('smile' => {}) };
like $@, qr/not connected/, 'send without connect dies';

done_testing;

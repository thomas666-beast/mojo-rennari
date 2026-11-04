use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Client;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious::Lite;

# Server side for the round-trip
my $server = Mojo::Rennari::Server->new(mock => 1);
$server->on('smile' => sub {
    my ($c, $payload) = @_;
    return { ok => 1, got => $payload };
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

# --- connect, send, receive reply -----------------------------------
my ($reply, $err);
my $client = Mojo::Rennari::Client->new(url => $url);

$client->on('reply' => sub {
    my ($client, $payload) = @_;
    $reply = $payload;
    Mojo::IOLoop->stop;
});

$client->connect(sub {
    my ($tx, $e) = @_;
    if ($e) { $err = $e; Mojo::IOLoop->stop; return }
    $client->send('smile' => { n => 42 });
});

Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

is $err, undef, 'connected without error';
is_deeply $reply, { ok => 1, got => { n => 42 } },
    'client received reply with original payload';

# --- disconnect ------------------------------------------------------
ok $client->is_connected, 'still connected';
$client->disconnect;
ok !$client->is_connected, 'disconnected';

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

use v5.36;
use Test::More;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Test::Mojo;
use Mojolicious::Lite;

# --- mock refuses in production -------------------------------------
{
    local $ENV{MOJO_MODE} = 'production';
    my $server = Mojo::Rennari::Server->new(mock => 1);
    eval { $server->_mock_enabled };
    like $@, qr/mock mode refused in production/, 'mock refused in production';
}

# --- force_mock overrides -------------------------------------------
{
    local $ENV{MOJO_MODE} = 'production';
    my $server = Mojo::Rennari::Server->new(mock => 1, force_mock => 1);
    ok $server->_mock_enabled, 'force_mock allows mock in production';
}

# --- mock bypasses auth, tolerates unknown events -------------------
my $rennari = Mojo::Rennari::Server->new(mock => 1);

$rennari->on('echo' => sub {
    my ($ws, $payload) = @_;
    return $payload;
});

websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};

my $t = Test::Mojo->new(app);

$t->websocket_ok('/ws')
  ->send_ok({binary => encode_frame('echo', { x => 1 })})
  ->message_ok;

is_deeply decode_frame($t->message->[1]),
    { e => 'reply', d => { x => 1 } },
    'mock: known event handled';
$t->finish_ok;

$t->websocket_ok('/ws')
  ->send_ok({binary => encode_frame('nosuch', {})})
  ->send_ok({binary => encode_frame('echo', { y => 2 })})
  ->message_ok;

is_deeply decode_frame($t->message->[1]),
    { e => 'reply', d => { y => 2 } },
    'mock: unknown event did not close connection';
$t->finish_ok;

done_testing;

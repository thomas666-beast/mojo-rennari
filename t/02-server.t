use v5.36;
use Test::More;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Test::Mojo;
use Mojolicious::Lite;

my $rennari = Mojo::Rennari::Server->new(
    auth_cb => sub {
        my $c = shift;
        my $token = $c->param('token') // return undef;
        return undef unless $token eq 'good';
        return { id => 'user-1' };
    },
);

$rennari->on('echo' => sub {
    my ($ws, $payload) = @_;
    return $payload;
});

$rennari->on('silent' => sub {
    return undef;
});

$rennari->on('boom' => sub {
    die "handler exploded\n";
});

websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};

my $t = Test::Mojo->new(app);

# --- echo ------------------------------------------------------------
$t->websocket_ok('/ws?token=good')
  ->send_ok({binary => encode_frame('echo', { hello => 'world' })})
  ->message_ok;

is_deeply decode_frame($t->message->[1]),
    { e => 'reply', d => { hello => 'world' } },
    'echo returned payload as reply';

$t->finish_ok;

# --- silent handler: no reply, connection still open -----------------
$t->websocket_ok('/ws?token=good')
  ->send_ok({binary => encode_frame('silent', { x => 1 })})
  ->send_ok({binary => encode_frame('echo', { y => 2 })})
  ->message_ok;

is_deeply decode_frame($t->message->[1]),
    { e => 'reply', d => { y => 2 } },
    'silent handler sent no reply; next frame still handled';

$t->finish_ok;

# --- unknown event closes 4003 --------------------------------------
$t->websocket_ok('/ws?token=good')
  ->send_ok({binary => encode_frame('nosuch', { x => 1 })})
  ->finished_ok(4003);

# --- bad frame closes 4002 ------------------------------------------
$t->websocket_ok('/ws?token=good')
  ->send_ok({binary => 'this is not messagepack'})
  ->finished_ok(4002);

# --- handler die closes 4004 ----------------------------------------
$t->websocket_ok('/ws?token=good')
  ->send_ok({binary => encode_frame('boom', {})})
  ->finished_ok(4004);

done_testing;

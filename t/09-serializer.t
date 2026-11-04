use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious::Lite;

# --- Protocol level -------------------------------------------------
my $mp_bytes = encode_frame('smile', { n => 1 });
my $js_bytes = encode_frame('smile', { n => 1 }, 'json');

isnt $mp_bytes, $js_bytes, 'msgpack and json bytes differ';

is_deeply decode_frame($mp_bytes),
    { e => 'smile', d => { n => 1 } }, 'msgpack round-trip';
is_deeply decode_frame($js_bytes, serializer => 'json'),
    { e => 'smile', d => { n => 1 } }, 'json round-trip';

is decode_frame($mp_bytes, serializer => 'json'), undef,
    'msgpack bytes rejected by json decoder';
is decode_frame($js_bytes), undef,
    'json bytes rejected by msgpack decoder';

eval { encode_frame('x', {}, 'xml') };
like $@, qr/unsupported serializer/, 'unknown serializer dies on encode';

# --- Server with json serializer ------------------------------------
my $rennari = Mojo::Rennari::Server->new(mock => 1, serializer => 'json');

$rennari->on('echo' => sub {
    my ($c, $p) = @_;
    $c->rennari->send_to_self('echo_back', $p);
    return undef;
});

websocket '/ws' => sub { $rennari->websocket_route(shift) };

my $daemon = Mojo::Server::Daemon->new(
    app => app, listen => ['http://127.0.0.1'], silent => 1,
);
$daemon->start;
my $port = $daemon->ports->[0];
my $url  = "ws://127.0.0.1:$port/ws";

my $wait = sub {
    my $n = shift;
    Mojo::IOLoop->timer($n => sub { Mojo::IOLoop->stop });
};

my $ua = Mojo::UserAgent->new;
my ($tx, @frames);
$ua->websocket($url => sub {
    my ($ua, $t) = @_;
    return Mojo::IOLoop->stop unless $t->is_websocket;
    $tx = $t;
    $tx->on(message => sub {
        my ($tx, $bytes) = @_;
        push @frames, decode_frame($bytes, serializer => 'json');
    });
    Mojo::IOLoop->stop;
});
Mojo::IOLoop->start;

ok $tx, 'connected';

# send a frame in JSON
$tx->send({binary => encode_frame('echo', { n => 7 }, 'json')});
$wait->(0.3); Mojo::IOLoop->start;

my ($back) = grep { $_->{e} eq 'echo_back' } @frames;
ok $back, 'json server replied with custom event';
is $back->{d}{n}, 7, 'payload intact';

# sending messagepack to a json server closes with 4002
@frames = ();
$tx->send({binary => encode_frame('echo', { n => 8 })});
$wait->(0.3); Mojo::IOLoop->start;

is scalar(@frames), 0, 'no frames after mismatched serializer';
ok $tx->is_finished, 'connection closed on wrong serializer';

done_testing;

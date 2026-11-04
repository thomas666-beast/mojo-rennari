use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame valid_id);
use Mojolicious::Lite;

# --- Protocol level -------------------------------------------------
is valid_id('42'),   1, 'numeric id ok';
is valid_id('0'),    1, 'zero ok';
is valid_id('-1'),   0, 'negative rejected';
is valid_id('1.5'),  0, 'fraction rejected';
is valid_id('abc'),  0, 'string rejected';
is valid_id(undef),  0, 'undef rejected';
is valid_id('1' x 21), 0, 'too long rejected';

my $bytes = encode_frame('smile', { n => 1 }, undef, 42);
my $frame = decode_frame($bytes);
is_deeply $frame, { e => 'smile', d => { n => 1 }, id => 42 },
    'id round-trips';

eval { encode_frame('smile', {}, undef, 'abc') };
like $@, qr/invalid id/, 'encode rejects bad id';

my $bad_id = Mojo::Rennari::Protocol::encode_frame('smile', {});
# Manually corrupt by appending a bad id via msgpack of a different shape
# Just test decode directly:
my $mp = Data::MessagePack->new->utf8;
my $bad = $mp->pack({ e => 'smile', d => {}, id => 'abc' });
is decode_frame($bad), undef, 'decode rejects bad id';

# --- Server: acks on success ----------------------------------------
my $rennari = Mojo::Rennari::Server->new(mock => 1);

$rennari->on('ping' => sub {
    my ($c, $p) = @_;
    $c->rennari->send_to_self('pong', { n => $p->{n} });
    return undef;
});

$rennari->on('boom' => sub { die "explode\n" });

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
        push @frames, decode_frame($bytes);
    });
    Mojo::IOLoop->stop;
});
Mojo::IOLoop->start;

ok $tx, 'connected';

# --- Test 1: ack arrives after success -------------------------------
$tx->send({binary => encode_frame('ping', { n => 5 }, undef, 7)});
$wait->(0.3); Mojo::IOLoop->start;

my ($pong) = grep { $_->{e} eq 'pong' } @frames;
my ($ack)  = grep { $_->{e} eq 'rennari_ack' } @frames;
ok $pong, 'pong sent';
ok $ack,  'ack sent after handler success';
is $ack->{d}{id}, 7, 'ack carries original id';

# --- Test 2: no ack on handler error, connection closes --------------
@frames = ();
$tx->send({binary => encode_frame('boom', {}, undef, 8)});
$wait->(0.3); Mojo::IOLoop->start;

ok !(grep { $_->{e} eq 'rennari_ack' } @frames),
    'no ack when handler dies';
ok $tx->is_finished, 'connection closed on handler error';

done_testing;

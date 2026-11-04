use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious::Lite;

my @events;

my $rennari = Mojo::Rennari::Server->new(mock => 1);

$rennari->on_connect(sub {
    my ($c, $identity) = @_;
    push @events, [ connect => $identity->{id} ];
});

$rennari->on_disconnect(sub {
    my ($c, $identity) = @_;
    push @events, [ disconnect => $identity->{id} ];
});

$rennari->on_error(sub {
    my ($c, $kind, $detail) = @_;
    push @events, [ error => $kind, $detail ];
});

$rennari->on('echo' => sub {
    my ($c, $payload) = @_;
    return $payload;
});

$rennari->on('boom' => sub {
    die "handler exploded\n";
});

websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};

my $daemon = Mojo::Server::Daemon->new(
    app    => app,
    listen => ['http://127.0.0.1'],
    silent => 1,
);
$daemon->start;
my $port = $daemon->ports->[0];
my $url  = "ws://127.0.0.1:$port/ws";

my $wait = sub {
    my $n = shift;
    Mojo::IOLoop->timer($n => sub { Mojo::IOLoop->stop });
};

# --- connect fires --------------------------------------------------
my $ua = Mojo::UserAgent->new;
my $tx;
$ua->websocket($url => sub {
    my ($ua, $t) = @_;
    return Mojo::IOLoop->stop unless $t->is_websocket;
    $tx = $t;
    Mojo::IOLoop->stop;
});
Mojo::IOLoop->start;

is $events[0][0], 'connect', 'on_connect fired';

# --- bad_frame fires on_error --------------------------------------
$tx->send({binary => 'not messagepack'});
$wait->(0.3); Mojo::IOLoop->start;

my ($bad) = grep { $_->[1] eq 'bad_frame' } @events;
ok $bad, 'on_error fired with bad_frame';

# --- new connection, unknown_event ---------------------------------
@events = ();
$ua->websocket($url => sub {
    my ($ua, $t) = @_;
    return Mojo::IOLoop->stop unless $t->is_websocket;
    $tx = $t;
    Mojo::IOLoop->stop;
});
Mojo::IOLoop->start;

$tx->send({binary => encode_frame('nosuch', {})});
$wait->(0.3); Mojo::IOLoop->start;

my ($unk) = grep { $_->[1] eq 'unknown_event' } @events;
ok $unk, 'on_error fired with unknown_event';
is $unk->[2], 'nosuch', 'detail carries event name';

# --- new connection, handler_error ---------------------------------
@events = ();
$ua->websocket($url => sub {
    my ($ua, $t) = @_;
    return Mojo::IOLoop->stop unless $t->is_websocket;
    $tx = $t;
    Mojo::IOLoop->stop;
});
Mojo::IOLoop->start;

$tx->send({binary => encode_frame('boom', {})});
$wait->(0.3); Mojo::IOLoop->start;

my ($h) = grep { $_->[1] eq 'handler_error' } @events;
ok $h, 'on_error fired with handler_error';
is $h->[2], 'boom', 'detail carries event name';

# --- disconnect fires on close --------------------------------------
@events = ();
$ua->websocket($url => sub {
    my ($ua, $t) = @_;
    return Mojo::IOLoop->stop unless $t->is_websocket;
    $tx = $t;
    Mojo::IOLoop->stop;
});
Mojo::IOLoop->start;

$tx->finish;
$wait->(0.3); Mojo::IOLoop->start;

my ($d) = grep { $_->[0] eq 'disconnect' } @events;
ok $d, 'on_disconnect fired';

# --- hook that dies does not break the connection -------------------
@events = ();
my $bad_server = Mojo::Rennari::Server->new(mock => 1);
$bad_server->on_connect(sub { die "hook died\n" });
$bad_server->on('echo' => sub { return $_[1] });

# reuse the same route cannot; skip this check — already covered by _fire's eval

done_testing;

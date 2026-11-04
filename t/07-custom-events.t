use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious::Lite;

my $b_id;
my @connect_ids;

my $rennari = Mojo::Rennari::Server->new(mock => 1);

$rennari->on_connect(sub {
    my ($c, $identity) = @_;
    push @connect_ids, $c->stash('rennari_id');
});

$rennari->on('smile' => sub {
    my ($c, $payload) = @_;
    $c->rennari->send_to_self('smile_back', { got => $payload });
    return undef;
});

$rennari->on('ping_b' => sub {
    my ($c, $payload) = @_;
    $c->rennari->send_to($b_id, 'ping', { text => 'to B' });
    return undef;
});

$rennari->on('system' => sub {
    my ($c, $payload) = @_;
    $c->rennari->broadcast('system_msg', { text => $payload->{text} });
    return undef;
});

$rennari->on('join' => sub {
    my ($c, $payload) = @_;
    $c->rennari->join($payload->{room});
    return undef;
});

$rennari->on('room_evt' => sub {
    my ($c, $payload) = @_;
    $c->rennari->broadcast_to_room($payload->{room}, 'room_msg', $payload);
    return undef;
});

$rennari->on('echo' => sub {
    my ($c, $payload) = @_;
    return $payload;
});

websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};

my $app = app;

my $daemon = Mojo::Server::Daemon->new(
    app    => $app,
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

package TestConn {
    use Mojo::Base -base;
    has 'ua';
    has 'tx';
    has 'frames' => sub { [] };

    sub connect {
        my ($self, $url, $cb) = @_;
        $self->ua(Mojo::UserAgent->new);
        $self->ua->websocket($url => sub {
            my ($ua, $tx) = @_;
            return $cb->(undef) unless $tx->is_websocket;
            $self->tx($tx);
            $tx->on(message => sub {
                my ($tx, $bytes) = @_;
                push @{ $self->frames },
                    Mojo::Rennari::Protocol::decode_frame($bytes);
            });
            $cb->($tx);
        });
    }

    sub send {
        my ($self, $event, $payload) = @_;
        $self->tx->send(
            {binary => Mojo::Rennari::Protocol::encode_frame($event, $payload)}
        );
    }

    sub clear { @{ $_[0]->frames } = () }

    sub frames_of {
        my ($self, $name) = @_;
        return grep { $_->{e} eq $name } @{ $self->frames };
    }
}

package main;

my ($a, $b) = (TestConn->new, TestConn->new);
my $err;

$a->connect($url, sub { $err = $_[0] ? undef : 'a failed'; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is $err, undef, 'A connected';

$b->connect($url, sub { $err = $_[0] ? undef : 'b failed'; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is $err, undef, 'B connected';

is scalar(@connect_ids), 2, 'two connections registered';
$b_id = $connect_ids[1];
ok defined $b_id, 'B id captured';

# --- Test 1: custom event in, custom event out to self --------------
$a->send('smile', { n => 1 });
$wait->(0.3); Mojo::IOLoop->start;

my ($s) = $a->frames_of('smile_back');
ok $s, 'A received smile_back (custom name)';
is_deeply $s->{d}, { got => { n => 1 } }, 'payload intact';

# --- Test 2: send_to one client by id -------------------------------
$a->clear; $b->clear;
$a->send('ping_b', {});
$wait->(0.3); Mojo::IOLoop->start;

is scalar($a->frames_of('ping')), 0, 'A did not receive ping';
my ($p) = $b->frames_of('ping');
ok $p, 'B received ping';
is $p->{d}{text}, 'to B', 'ping payload intact';

# --- Test 3: broadcast to everyone ----------------------------------
$a->clear; $b->clear;
$a->send('system', { text => 'restart' });
$wait->(0.3); Mojo::IOLoop->start;

my ($sa) = $a->frames_of('system_msg');
my ($sb) = $b->frames_of('system_msg');
ok $sa, 'A received system_msg (broadcast includes sender)';
ok $sb, 'B received system_msg';

# --- Test 4: broadcast_to_room with custom name ---------------------
$a->clear; $b->clear;
$a->send('join', { room => 'r1' });
$b->send('join', { room => 'r1' });
$wait->(0.2); Mojo::IOLoop->start;
$a->clear; $b->clear;

$a->send('room_evt', { room => 'r1', text => 'room hi' });
$wait->(0.3); Mojo::IOLoop->start;

my ($ra) = $a->frames_of('room_msg');
my ($rb) = $b->frames_of('room_msg');
ok $ra, 'A received room_msg (custom name)';
ok $rb, 'B received room_msg (custom name)';
is $rb->{d}{text}, 'room hi', 'payload intact';

# --- Test 5: handler return value goes as 'reply' -------------------
$a->clear;
$a->send('echo', { x => 7 });
$wait->(0.3); Mojo::IOLoop->start;

my ($r) = $a->frames_of('reply');
ok $r, 'handler return value sent as reply';
is_deeply $r->{d}, { x => 7 }, 'reply payload intact';

$a->tx->finish;
$b->tx->finish;
Mojo::IOLoop->timer(0.2 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

done_testing;

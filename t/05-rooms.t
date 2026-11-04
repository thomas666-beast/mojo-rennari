use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious::Lite;

my $rennari = Mojo::Rennari::Server->new(mock => 1);

$rennari->on('join' => sub {
    my ($c, $payload) = @_;
    $c->rennari->join($payload->{room});
    return { ok => 1 };
});

$rennari->on('leave' => sub {
    my ($c, $payload) = @_;
    $c->rennari->leave($payload->{room});
    return { ok => 1 };
});

$rennari->on('chat' => sub {
    my ($c, $payload) = @_;
    $c->rennari->broadcast_to_room($payload->{room}, 'chat', $payload);
});

$rennari->on('members' => sub {
    my ($c, $payload) = @_;
    return {
        room    => $payload->{room},
        members => $c->rennari->members_of($payload->{room}),
    };
});

websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};

my $app = app;

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

    sub chat_frames {
        my $self = shift;
        return grep { $_->{e} eq 'chat' } @{ $self->frames };
    }

    sub reply_frames {
        my $self = shift;
        return grep { $_->{e} eq 'reply' } @{ $self->frames };
    }

    sub finish { $_[0]->tx->finish if $_[0]->tx }
}

package main;

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

my ($a, $b) = (TestConn->new, TestConn->new);
my $err;

$a->connect($url, sub { $err = $_[0] ? undef : 'a failed'; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is $err, undef, 'client A connected';

$b->connect($url, sub { $err = $_[0] ? undef : 'b failed'; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is $err, undef, 'client B connected';

# --- Test 1: both join lobby, both receive --------------------------
$a->send('join', { room => 'lobby' });
$b->send('join', { room => 'lobby' });
$wait->(0.2); Mojo::IOLoop->start;
$a->clear; $b->clear;

$a->send('chat', { room => 'lobby', text => 'from A' });
$b->send('chat', { room => 'lobby', text => 'from B' });
$wait->(0.4); Mojo::IOLoop->start;

my @a_chat = $a->chat_frames;
my @b_chat = $b->chat_frames;
is scalar(@a_chat), 2, 'A received both chats';
is scalar(@b_chat), 2, 'B received both chats';
is_deeply [sort map { $_->{d}{text} } @a_chat],
    ['from A', 'from B'], 'A got both messages';
is_deeply [sort map { $_->{d}{text} } @b_chat],
    ['from A', 'from B'], 'B got both messages';

# --- Test 2: B leaves, stops receiving ------------------------------
$b->send('leave', { room => 'lobby' });
$wait->(0.2); Mojo::IOLoop->start;

$a->clear;
$b->clear;
$a->send('chat', { room => 'lobby', text => 'after leave' });
$wait->(0.2); Mojo::IOLoop->start;

is scalar($a->chat_frames), 1, 'A still receives';
is scalar($b->chat_frames), 0, 'B no longer receives';

# --- Test 3: disconnect removes from room ---------------------------
$b->finish;
$wait->(0.2); Mojo::IOLoop->start;

$a->clear;
$a->send('members', { room => 'lobby' });
$wait->(0.2); Mojo::IOLoop->start;

my ($m) = $a->reply_frames;
is scalar(@{ $m->{d}{members} }), 1, 'only A remains';

# --- Test 4: broadcast to empty room returns 0 ----------------------
is $rennari->broadcast_to_room('ghost', 'chat', { text => 'x' }), 0,
    'broadcast to empty room returns 0';

# --- Test 5: join twice idempotent ----------------------------------
$a->send('join', { room => 'solo' });
$a->send('join', { room => 'solo' });
$wait->(0.2); Mojo::IOLoop->start;

$a->clear;
$a->send('members', { room => 'solo' });
$wait->(0.2); Mojo::IOLoop->start;

my ($s) = $a->reply_frames;
is scalar(@{ $s->{d}{members} }), 1, 'join twice kept one member entry';

$a->finish;
Mojo::IOLoop->timer(0.2 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

done_testing;

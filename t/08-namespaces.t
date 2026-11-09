use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious::Lite;

my $rennari = Mojo::Rennari::Server->new(mock => 1);

$rennari->on('hello' => sub {
    my ($c, $p) = @_;
    $c->rennari->send_to_self('hello_back', { from => '/', got => $p });
    return undef;
});

my $chat = $rennari->namespace('/chat');
$chat->on('hello' => sub {
    my ($c, $p) = @_;
    $c->rennari->send_to_self('hello_back', { from => '/chat', got => $p });
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
        my ($self, $event, $payload, $nsp) = @_;
        $self->tx->send({
            binary => Mojo::Rennari::Protocol::encode_frame(
                $event, $payload, undef, undef, undef,
                ($nsp && $nsp ne '/' ? $nsp : undef),
            ),
        });
    }

    sub clear { @{ $_[0]->frames } = () }

    sub frames_of {
        my ($self, $name) = @_;
        return grep { $_->{e} eq $name } @{ $self->frames };
    }
}

package main;

my $a = TestConn->new;
my $err;
$a->connect($url, sub { $err = $_[0] ? undef : 'a failed'; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is $err, undef, 'A connected';

# --- Test 1: default namespace works --------------------------------
$a->send('hello', { n => 1 });
$wait->(0.3); Mojo::IOLoop->start;

my ($r1) = $a->frames_of('hello_back');
ok $r1, 'default namespace handler fired';
is $r1->{d}{from}, '/', 'default namespace confirmed';

# --- Test 2: switch to /chat -----------------------------------------
$a->clear;
$a->send('rennari_nsp', { name => '/chat' });
$wait->(0.2); Mojo::IOLoop->start;

my ($ok) = $a->frames_of('rennari_nsp_ok');
ok $ok, 'namespace switch acked';
is $ok->{d}{name}, '/chat', 'ack names /chat';

# --- Test 3: /chat handler fires -------------------------------------
$a->clear;
$a->send('hello', { n => 2 }, '/chat');
$wait->(0.3); Mojo::IOLoop->start;

my ($r2) = $a->frames_of('hello_back');
ok $r2, 'chat namespace handler fired';
is $r2->{d}{from}, '/chat', 'chat namespace confirmed';
is $r2->{d}{got}{n}, 2, 'payload intact';

# --- Test 4: unknown namespace closes with 4005 ---------------------
$a->clear;
$a->send('rennari_nsp', { name => '/nope' });
$wait->(0.3); Mojo::IOLoop->start;

my $conn_gone = 1;
for my $id (keys %{ $rennari->_connections }) {
    $conn_gone = 0;
}

ok $conn_gone, 'unknown namespace closed the connection (registry empty)';

done_testing;

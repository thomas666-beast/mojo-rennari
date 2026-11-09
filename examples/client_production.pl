#!/usr/bin/env perl
use v5.36;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::IOLoop;
use Mojo::Rennari::Client;

my $port  = shift @ARGV or die "usage: $0 <port> [token]\n";
my $token = shift @ARGV // 'alice-token';
my $url   = "ws://127.0.0.1:$port/ws";

my $client = Mojo::Rennari::Client->new(url => $url);

$client->on('auth_ok' => sub {
    my ($client, $p) = @_;
    say "authenticated as $p->{id}";
    $client->send('chat'   => { room => 'lobby', text => 'hello from perl' });
    $client->send('ping'   => { n => 1 });
    $client->send('whoami' => {});
});

$client->on('auth_error' => sub {
    my ($client, $p) = @_;
    say "auth failed: $p->{reason}";
    $client->disconnect(4001, 'auth failed');
    Mojo::IOLoop->stop;
});

$client->on('chat' => sub {
    my ($client, $p) = @_;
    say "chat from $p->{from}: $p->{text}";
});

$client->on('pong' => sub {
    my ($client, $p) = @_;
    say "pong: " . ($p->{got}{n} // '?');
});

$client->on('reply' => sub {
    my ($client, $p) = @_;
    say "reply: user_id=$p->{user_id} name=$p->{name}";
});

$client->connect(sub {
    my ($tx, $err) = @_;
    if ($err) {
        say "connect failed: $err";
        Mojo::IOLoop->stop;
        return;
    }
    say "connected, sending auth";
    $client->send('auth' => { token => $token });
});

Mojo::IOLoop->timer(3 => sub {
    $client->disconnect;
    Mojo::IOLoop->stop;
});

Mojo::IOLoop->start;

#!/usr/bin/env perl
use v5.36;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojolicious::Lite;
use Mojo::Rennari::Server;

my %TOKENS = (
    'alice-token' => { id => 'alice', user_id => 1, name => 'alice' },
    'bob-token'   => { id => 'bob',   user_id => 2, name => 'bob'   },
);

my $rennari = Mojo::Rennari::Server->new(
    auth_cb => sub {
        my $c     = shift;
        my $token = $c->param('token');
        return undef unless defined $token && length $token;
        return $TOKENS{$token};
    },
);

$rennari->on_connect(sub {
    my ($c, $identity) = @_;
    say "connected: $identity->{name} (id=$identity->{id})";
});

$rennari->on_disconnect(sub {
    my ($c, $identity) = @_;
    say "disconnected: $identity->{name}";
});

$rennari->on_error(sub {
    my ($c, $kind, $detail) = @_;
    warn "protocol error ($kind) from user: " . ($detail // '-');
});

$rennari->on('chat' => sub {
    my ($c, $payload) = @_;
    my $identity = $c->stash('rennari_identity');
    my $room     = $payload->{room} or return { error => 'room required' };

    $c->rennari->join($room);
    $c->rennari->broadcast_to_room($room, 'chat', {
        room => $room,
        from => $identity->{name},
        text => $payload->{text} // '',
    });
    return undef;
});

$rennari->on('leave' => sub {
    my ($c, $payload) = @_;
    my $room = $payload->{room} or return { error => 'room required' };
    $c->rennari->leave($room);
    return { ok => 1, left => $room };
});

$rennari->on('ping' => sub {
    my ($c, $payload) = @_;
    $c->rennari->send_to_self('pong', { got => $payload });
    return undef;
});

$rennari->on('whoami' => sub {
    my $c = shift;
    my $identity = $c->stash('rennari_identity');
    return { user_id => $identity->{user_id}, name => $identity->{name} };
});

websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};

app->start;

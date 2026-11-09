#!/usr/bin/env perl
use v5.36;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::Rennari::Server;

my %TOKENS = (
    'alice-token' => { id => 'alice', user_id => 1, name => 'alice' },
    'bob-token'   => { id => 'bob',   user_id => 2, name => 'bob'   },
);

my $AUTH_TIMEOUT   = 5;
my $ALLOWED_ORIGIN = 'https://app.example.com';

my $rennari = Mojo::Rennari::Server->new(
    auth_cb => sub {
        my $c      = shift;
        my $origin = $c->req->headers->origin;

        # Browsers always send Origin. Non-browser clients may not.
        # The primary gate is the token in the first message, so only
        # enforce Origin when present.
        if (defined $origin && $origin ne $ALLOWED_ORIGIN) {
            return undef;
        }

        return { id => 'pending', authenticated => 0 };
    },
);

$rennari->on_connect(sub {
    my ($c, $identity) = @_;

    $c->stash(rennari_authed => 0);

    my $timer = Mojo::IOLoop->timer($AUTH_TIMEOUT => sub {
        return if $c->stash('rennari_authed');
        $c->tx->finish(4001, 'auth timeout');
    });
    $c->stash(rennari_auth_timer => $timer);
});

$rennari->on('auth' => sub {
    my ($c, $payload) = @_;

    if (my $t = $c->stash('rennari_auth_timer')) {
        Mojo::IOLoop->remove($t);
    }

    my $token    = ref $payload eq 'HASH' ? ($payload->{token} // '') : '';
    my $identity = $TOKENS{$token};

    unless ($identity) {
        $c->rennari->send_to_self('auth_error', { reason => 'invalid_token' });
        $c->tx->finish(4001, 'unauthorized');
        return undef;
    }

    $c->stash(rennari_identity => $identity);
    $c->stash(rennari_authed   => 1);
    $c->rennari->send_to_self('auth_ok', { id => $identity->{id} });
    return undef;
});

my $require_auth = sub {
    my $c = shift;
    unless ($c->stash('rennari_authed')) {
        $c->rennari->send_to_self('auth_error', { reason => 'not_authenticated' });
        $c->tx->finish(4001, 'unauthorized');
        return 0;
    }
    return 1;
};

$rennari->on('chat' => sub {
    my ($c, $payload) = @_;
    return undef unless $require_auth->($c);

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

$rennari->on('ping' => sub {
    my ($c, $payload) = @_;
    return undef unless $require_auth->($c);
    $c->rennari->send_to_self('pong', { got => $payload });
    return undef;
});

$rennari->on('whoami' => sub {
    my $c = shift;
    return undef unless $require_auth->($c);
    my $identity = $c->stash('rennari_identity');
    return { user_id => $identity->{user_id}, name => $identity->{name} };
});

$rennari->on_disconnect(sub {
    my ($c, $identity) = @_;
    if (my $t = $c->stash('rennari_auth_timer')) {
        Mojo::IOLoop->remove($t);
    }
});

websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};

app->start;

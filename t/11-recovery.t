use v5.36;
use Test::More;
use Mojo::IOLoop;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious::Lite;

my $rennari = Mojo::Rennari::Server->new(mock => 1, recovery => 1);

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
my ($tx, @frames, $session_id, $last_offset);
my $connect = sub {
    my ($resume) = @_;
    $ua->websocket($url => sub {
        my ($ua, $t) = @_;
        return Mojo::IOLoop->stop unless $t->is_websocket;
        $tx = $t;
        $tx->on(message => sub {
            my ($tx, $bytes) = @_;
            my $f = decode_frame($bytes);
            push @frames, $f;
            $last_offset = $f->{o} if defined $f->{o};
            if ($f->{e} eq 'rennari_session') {
                $session_id = $f->{d}{id};
            }
        });
        if ($resume) {
            $tx->send({binary => encode_frame('rennari_resume',
                { session_id => $session_id, offset => $last_offset })});
        }
        Mojo::IOLoop->stop;
    });
    Mojo::IOLoop->start;
};

# --- connect, get session -------------------------------------------
$connect->(0);
ok $tx, 'connected';
ok $session_id, 'session id received';
ok defined $last_offset, 'initial offset received';

# --- send a frame so there is an offset to track --------------------
$tx->send({binary => encode_frame('echo', { n => 1 })});
$wait->(0.3); Mojo::IOLoop->start;

my ($back) = grep { $_->{e} eq 'echo_back' } @frames;
ok $back, 'echo_back received';
ok defined $back->{o}, 'outbound frame carries offset';

# --- disconnect and reconnect with resume ---------------------------
my $saved_offset = $last_offset;
$tx->finish;
$wait->(0.2); Mojo::IOLoop->start;

$connect->(1);
$wait->(0.3); Mojo::IOLoop->start;

my ($resumed) = grep { $_->{e} eq 'rennari_resumed' } @frames;
ok $resumed, 'resume succeeded';
is $resumed->{d}{offset}, $saved_offset, 'server offset matches client last';

# --- unknown session fails resume -----------------------------------
@frames = ();
$session_id = 'deadbeef' x 4;
$last_offset = 0;
$connect->(1);
$wait->(0.3); Mojo::IOLoop->start;

my ($failed) = grep { $_->{e} eq 'rennari_resume_failed' } @frames;
ok $failed, 'unknown session resume fails';
is $failed->{d}{reason}, 'unknown_session', 'reason is unknown_session';

done_testing;

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

# Wait for a frame matching a predicate, up to $timeout seconds.
sub await_frame {
    my ($frames_ref, $pred, $timeout) = @_;
    $timeout //= 2;
    my $deadline = time + $timeout;
    while (time < $deadline) {
        for my $f (@$frames_ref) {
            return $f if $pred->($f);
        }
        Mojo::IOLoop->one_tick;
        select undef, undef, undef, 0.02;
    }
    return undef;
}

my $ua = Mojo::UserAgent->new;
my ($tx, @frames);

my $connect = sub {
    my ($resume_data) = @_;
    $ua->websocket($url => sub {
        my ($ua, $t) = @_;
        return Mojo::IOLoop->stop unless $t->is_websocket;
        $tx = $t;
        $tx->on(message => sub {
            my ($tx, $bytes) = @_;
            my $f = decode_frame($bytes);
            push @frames, $f if $f;
        });
        if ($resume_data) {
            $tx->send({binary => encode_frame('rennari_resume', $resume_data)});
        }
        Mojo::IOLoop->stop;
    });
    Mojo::IOLoop->start;
};

$connect->();
ok $tx, 'connected';

my $sess = await_frame(\@frames, sub { $_[0]{e} eq 'rennari_session' });
ok $sess, 'session id received';
my $session_id = $sess->{d}{id};
my $last_offset = $sess->{o};
ok defined $last_offset, 'initial offset received';

# --- echo -----------------------------------------------------------------
@frames = ();
$tx->send({binary => encode_frame('echo', { n => 1 })});
my $back = await_frame(\@frames, sub { $_[0]{e} eq 'echo_back' });
ok $back, 'echo_back received';
ok defined $back->{o}, 'outbound frame carries offset';

my $saved_offset = $back->{o};

# --- disconnect, resume ---------------------------------------------------
$tx->finish;
Mojo::IOLoop->one_tick;
select undef, undef, undef, 0.1;

@frames = ();
$connect->({ session_id => $session_id, offset => $saved_offset });
my $resumed = await_frame(\@frames, sub { $_[0]{e} eq 'rennari_resumed' });
ok $resumed, 'resume succeeded';
is $resumed->{d}{offset}, $saved_offset, 'server offset matches client last';

# --- unknown session ------------------------------------------------------
$tx->finish;
Mojo::IOLoop->one_tick;
select undef, undef, undef, 0.1;

@frames = ();
$connect->({ session_id => 'deadbeef' x 4, offset => 0 });
my $failed = await_frame(\@frames, sub { $_[0]{e} eq 'rennari_resume_failed' });
ok $failed, 'unknown session resume fails';
is $failed->{d}{reason}, 'unknown_session', 'reason is unknown_session';

done_testing;

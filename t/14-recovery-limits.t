use 5.020;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::Rennari::Server;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojolicious;

my $APP = 'test-only-application-token-1234567890';
my $app = Mojolicious->new;
$app->log->level('fatal');
my $server = Mojo::Rennari::Server->new(
    app_token => $APP,
    recovery => 1,
    recovery_max_frames => 1,
    logger => $app->log,
    auth_cb => sub {
        my $authorization = $_[0]->req->headers->authorization // '';
        return {id => $1} if $authorization =~ /\ABearer (alice|bob)\z/;
        return;
    },
);
my $connection;
$server->on_connect(sub { $connection = $_[0]->rennari });
$app->routes->websocket('/ws')->to(cb => sub { $server->websocket_route(shift) });
my $t = Test::Mojo->new($app);

$t->ua->on(start => sub {
    $_[1]->req->headers->header('X-Rennari-App-Token' => $APP);
});

sub receive {
    my ($label) = @_;
    $t->message_ok($label);
    my $msg = $t->message or return {};
    return decode_frame($msg->[1]) || {};
}

$t->websocket_ok('/ws', {Authorization => 'Bearer alice'});
my $start = receive('Alice receives initial session');
like $start->{d}{id}, qr/\A[0-9a-f]{32}\z/, 'session ID is 16 bytes of hex-encoded randomness';
my $offline = $connection;
$t->finish_ok;
ok $offline->send_to_self('update', {number => 1}), 'direct offline send is buffered';
my $resume = {session_id => $start->{d}{id}, offset => $start->{o}};

$t->websocket_ok('/ws', {Authorization => 'Bearer bob'});
receive('Bob receives his own initial session');
$t->send_ok({binary => encode_frame('rennari_resume', $resume)});
is receive('unmatched identity gets a recovery response')->{e},
    'rennari_resume_failed', 'resume is tied to the authenticated identity';
$t->finish_ok;

$t->websocket_ok('/ws', {Authorization => 'Bearer alice'});
receive('Alice opens a fresh transport');
$t->send_ok({binary => encode_frame('rennari_resume', $resume)});
my $replay = receive('Alice receives her buffered frame');
is_deeply $replay->{d}, {number => 1}, 'matching identity can replay the offline update';
is receive('Alice receives resume confirmation')->{e}, 'rennari_resumed', 'recovery succeeds';

$offline = $connection;
$t->finish_ok;
ok $offline->send_to_self('update', {number => 2}), 'first update fits the offline buffer';
ok !$offline->send_to_self('update', {number => 3}), 'overflow invalidates instead of growing the buffer';

$t->websocket_ok('/ws', {Authorization => 'Bearer alice'});
receive('Alice receives a new session after overflow');
$t->send_ok({binary => encode_frame('rennari_resume', $resume)});
is receive('recovery after overflow receives a failure')->{e},
    'rennari_resume_failed', 'overflowed session is no longer resumable';
$t->finish_ok;

done_testing;

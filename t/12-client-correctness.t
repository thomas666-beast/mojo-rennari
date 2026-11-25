use 5.020;
use strict;
use warnings;
use Test::More;
use Mojo::IOLoop;
use Mojo::Log;
use Mojo::Rennari::Client;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojo::Rennari::Server;
use Mojo::Server::Daemon;
use Mojolicious;

my $quiet = Mojo::Log->new(level => 'fatal');
my $app = Mojolicious->new(log => $quiet);
my $headers = {Authorization => 'Bearer integration-test-token'};
my $server = Mojo::Rennari::Server->new(
    logger => $quiet, serializer => 'json',
    auth_cb => sub {
        return unless ($_[0]->req->headers->authorization // '') eq $headers->{Authorization};
        return {id => 'tester'};
    },
);
$server->namespace('/chat')->on(echo => sub { return $_[1] });
$app->routes->websocket('/ws')->to(cb => sub { $server->websocket_route(shift) });
my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1:0'], silent => 1);
$daemon->start;

my $client = Mojo::Rennari::Client->new(
    url => 'ws://127.0.0.1:' . $daemon->ports->[0] . '/ws',
    headers => $headers, serializer => 'json', logger => $quiet,
);
my $ns = $client->of('/chat');
my ($reply, $ack, $error);
my $stop_when_complete = sub { Mojo::IOLoop->stop if defined $reply && (defined $ack || defined $error) };
$ns->on(reply => sub { $reply = $_[1]; $stop_when_complete->() });
$client->connect(sub {
    my ($tx, $failure) = @_;
    if ($failure) {
        $error = $failure;
        return Mojo::IOLoop->stop;
    }
    $ns->emit_with_ack(echo => {message => 'hello'}, sub {
        ($ack, $error) = @_;
        $stop_when_complete->();
    });
});
my $deadline = Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
Mojo::IOLoop->remove($deadline);
is $error, undef, 'header-authenticated JSON exchange completes without error';
is_deeply $reply, {message => 'hello'}, 'JSON namespace handshake and event framing work';
ok $ack && defined $ack->{id}, 'JSON acknowledgement is decoded and delivered';
$client->disconnect;
$daemon->stop;

my @errors;
my $parser = Mojo::Rennari::Client->new(logger => $quiet);
$parser->on(error => sub { push @errors, $_[1] });
for my $event (qw(rennari_ack rennari_resumed rennari_session)) {
    my $ok = eval { $parser->_on_message(encode_frame($event, 'not an object'), 65536); 1 };
    ok $ok, "malformed $event is rejected without throwing";
}
is_deeply \@errors, [('bad frame') x 3], 'malformed control payloads fire error callbacks';
is $parser->session_id, undef, 'malformed controls do not install session state';
is decode_frame('{"e":"echo","d":{},"o":null}', serializer => 'json'), undef,
    'null offset is rejected';

{
    package Local::RennariTransaction;
    sub new { bless {sent => []}, shift }
    sub send { push @{$_[0]{sent}}, $_[1]{binary}; return $_[0] }
    sub finish { return $_[0] }
}

my $tx = Local::RennariTransaction->new;
my $pending = Mojo::Rennari::Client->new(_tx => $tx, logger => $quiet, ack_timeout => 0.01);
my @callbacks;
$pending->emit_with_ack(echo => {}, sub { push @callbacks, [@_] });
$pending->disconnect;
$pending->disconnect;
is_deeply \@callbacks, [[undef, 'disconnected before acknowledgement']],
    'disconnect resolves a pending acknowledgement exactly once';
is_deeply $pending->_pending, {}, 'pending acknowledgement state is cleared';
Mojo::IOLoop->timer(0.04 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is scalar @{$tx->{sent}}, 1, 'a disconnected client does not send a retry';
is scalar @callbacks, 1, 'the cancelled timer does not call the callback again';

my $retry_tx = Local::RennariTransaction->new;
my $retry = Mojo::Rennari::Client->new(_tx => $retry_tx, logger => $quiet,
    ack_timeout => 0.01, retries => 1);
my $retry_error;
$retry->emit_with_ack(echo => {}, sub { $retry_error = $_[1]; Mojo::IOLoop->stop });
my $retry_deadline = Mojo::IOLoop->timer(1 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
Mojo::IOLoop->remove($retry_deadline);
my @ids = map { decode_frame($_)->{id} } @{$retry_tx->{sent}};
is_deeply \@ids, [1, 1], 'a retry preserves the acknowledgement ID';
like $retry_error, qr/ack timeout/, 'exhausted retries report a timeout';

done_testing;

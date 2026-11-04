use v5.36;
use Test::More;
use Test::Mojo;
use Mojolicious::Lite;

websocket '/ws' => sub {
    my $c = shift;
    $c->on(message => sub {
        my ($c, $msg) = @_;
        $c->send("echo: $msg");
    });
};

my $t = Test::Mojo->new(app);

$t->websocket_ok('/ws')->send_ok('hello');
$t->message_ok;
diag "got: [" . $t->message->[1] . "]";

done_testing;

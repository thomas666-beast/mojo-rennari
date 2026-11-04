package Mojo::Rennari::Client;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojo::IOLoop;
use Mojo::UserAgent;

our $VERSION = '0.001';

has 'url';
has 'mock'       => 0;
has 'force_mock' => 0;
has 'max_bytes'  => 64 * 1024;
has 'logger';
has 'ua';
has '_handlers'  => sub { {} };
has '_tx';

sub on {
    my ($self, $event, $cb) = @_;
    die 'on: invalid event name'
        unless Mojo::Rennari::Protocol::valid_event_name($event);
    die 'on: handler must be a code ref'
        unless ref $cb eq 'CODE';
    $self->_handlers->{$event} = $cb;
    return $self;
}

sub _mock_enabled {
    my $self = shift;
    return 0 unless $self->mock;
    if (($ENV{MOJO_MODE} // '') eq 'production' && !$self->force_mock) {
        die 'mock mode refused in production (set force_mock to override)';
    }
    return 1;
}

sub _log {
    my ($self, $level, $msg) = @_;
    if (my $logger = $self->logger) {
        $logger->$level($msg);
    }
    else {
        warn "[rennari $level] $msg\n";
    }
}

sub connect {
    my ($self, $cb) = @_;

    my $url = $self->url // die 'connect: url required';
    $self->_mock_enabled;

    my $ua = $self->ua // Mojo::UserAgent->new;
    $self->ua($ua);

    $ua->websocket($url => sub {
        my ($ua, $tx) = @_;

        unless ($tx->is_websocket) {
            my $code = $tx->res->code // '?';
            $self->_log(error => "rennari: handshake failed ($code)");
            $cb->(undef, 'handshake failed') if $cb;
            return;
        }

        $self->_tx($tx);
        $self->_log(info => "rennari: connected to $url");

        my $handlers = $self->_handlers;
        my $max      = $self->max_bytes;

        $tx->on(message => sub {
            my ($tx, $bytes) = @_;

            my $frame = decode_frame($bytes, max_bytes => $max);
            unless ($frame) {
                $self->_log(warn => 'rennari: bad frame from server');
                return $tx->finish(4002, 'bad frame');
            }

            my $event = $frame->{e};
            my $handler = $handlers->{$event};

            unless ($handler) {
                $self->_log(debug => "rennari: no handler for '$event'");
                return;
            }

            my $ok = eval { $handler->($self, $frame->{d}) };
            $self->_log(error => "rennari: handler '$event' died: $@") if $@;
        });

        $tx->on(finish => sub {
            my ($tx, $code, $reason) = @_;
            $self->_log(info => "rennari: disconnected ($code)");
            $self->_tx(undef);
        });

        $cb->($tx, undef) if $cb;
    });

    return $self;
}

sub send {
    my ($self, $event, $payload) = @_;
    my $tx = $self->_tx // die 'send: not connected';
    $tx->send({binary => encode_frame($event, $payload)});
    return $self;
}

sub disconnect {
    my $self = shift;
    if (my $tx = $self->_tx) {
        $tx->finish;
        $self->_tx(undef);
    }
    return $self;
}

sub is_connected {
    my $self = shift;
    my $tx = $self->_tx;
    return $tx && $tx->is_websocket ? 1 : 0;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Client - WebSocket event client for Mojo::Rennari

=head1 SYNOPSIS

  use Mojo::Rennari::Client;
  use Mojo::IOLoop;

  my $client = Mojo::Rennari::Client->new(url => 'ws://127.0.0.1:3999/ws');

  $client->on('reply' => sub {
      my ($client, $payload) = @_;
      say "reply: ", $payload->{ok};
  });

  $client->connect(sub {
      my ($tx, $err) = @_;
      die $err if $err;
      $client->send('smile' => { n => 42 });
  });

  Mojo::IOLoop->start;

=head1 DESCRIPTION

Connects to a Mojo::Rennari::Server (or any WebSocket server that speaks
the same MessagePack envelope). Frames are C<< { e => $event, d => $payload } >>
sent as binary WebSocket frames.

=head1 ATTRIBUTES

=head2 url

WebSocket URL to connect to. Required.

=head2 mock

When true, refuses to run in production unless C<force_mock> is set.
Matches the server-side guard so the same config works on both sides.

=head2 force_mock

Overrides the production refusal.

=head2 max_bytes

Maximum accepted frame size. Default 64 KiB.

=head2 logger

Optional. Falls back to C<warn>.

=head2 ua

Optional L<Mojo::UserAgent>. A fresh one is created if unset.

=head1 METHODS

=head2 connect

  $client->connect(sub { my ($tx, $err) = @_; ... });

Opens the connection. The callback receives the WebSocket transaction on
success, or C<undef> and an error string on failure. After connect you
must run C<Mojo::IOLoop->start> for anything to happen.

=head2 on

  $client->on('reply' => sub { my ($client, $payload) = @_; ... });

Registers a handler for an incoming event.

=head2 send

  $client->send('smile' => { n => 42 });

Sends an event as a binary MessagePack frame.

=head2 disconnect

  $client->disconnect;

Closes the connection.

=head2 is_connected

Returns true if the WebSocket is open.

=head1 LICENSE

Same terms as Perl itself.

=cut

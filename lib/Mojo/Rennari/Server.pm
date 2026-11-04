package Mojo::Rennari::Server;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);

our $VERSION = '0.001';

has 'auth_cb';
has 'mock'       => 0;
has 'force_mock' => 0;
has 'max_bytes'  => 64 * 1024;
has 'logger';
has '_handlers'  => sub { {} };

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

sub websocket_route {
    my ($self, $c) = @_;

    my $mock = $self->_mock_enabled;

    my $identity;
    if ($mock) {
        $identity = { mock => 1, id => 'mock-' . int(rand(1e9)) };
    }
    else {
        my $cb = $self->auth_cb;
        unless ($cb) {
            $self->_log(warn => 'no auth_cb configured and mock disabled');
            return $c->render(status => 500, text => 'server misconfigured');
        }
        $identity = eval { $cb->($c) };
        if ($@) {
            $self->_log(error => "auth_cb died: $@");
            return $c->render(status => 500, text => 'auth error');
        }
        unless ($identity) {
            return $c->render(status => 401, text => 'unauthorized');
        }
    }

    $c->stash(rennari_identity => $identity);

    my $handlers = $self->_handlers;
    my $max      = $self->max_bytes;
    my $is_mock  = $mock;

    $self->_log(info => "rennari: connection opened ($identity->{id})");

    $c->on(message => sub {
        my ($c, $bytes) = @_;

        my $frame = decode_frame($bytes, max_bytes => $max);
        unless ($frame) {
            $self->_log(warn => "rennari: bad frame from $identity->{id}");
            return $c->tx->finish(4002, 'bad frame');
        }

        my $event = $frame->{e};
        my $cb    = $handlers->{$event};

        unless ($cb) {
            if ($is_mock) {
                $self->_log(debug => "rennari: mock ignoring '$event'");
                return;
            }
            $self->_log(warn => "rennari: unknown event '$event'");
            return $c->tx->finish(4003, 'unknown event');
        }

        my $reply = eval { $cb->($c, $frame->{d}) };
        if ($@) {
            $self->_log(error => "rennari: handler '$event' died: $@");
            return $c->tx->finish(4004, 'handler error');
        }

        if (defined $reply) {
            my $ok = eval { $c->send({binary => encode_frame('reply', $reply)}) };
            $self->_log(error => "rennari: send failed: $@") if $@;
        }
    });

    $c->on(finish => sub {
        $self->_log(info => "rennari: connection closed ($identity->{id})");
    });

    return undef;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Server - WebSocket event server for Mojolicious

=head1 SYNOPSIS

  use Mojolicious::Lite;
  use Mojo::Rennari::Server;

  my $rennari = Mojo::Rennari::Server->new(
      auth_cb => sub {
          my $c = shift;
          my $token = $c->param('token') // return undef;
          return undef unless $token eq 'secret';
          return { id => 'user-1' };
      },
  );

  $rennari->on('smile' => sub {
      my ($c, $payload) = @_;
      return { ok => 1, received => $payload };
  });

  websocket '/ws' => sub {
      my $c = shift;
      $rennari->websocket_route($c);
  };

  app->start;

=head1 DESCRIPTION

Mounts a WebSocket endpoint in a Mojolicious route. Authentication runs
during the HTTP request phase, before the upgrade. Failed auth renders
401 and no socket is opened.

Frames are MessagePack maps C<< { e => $event, d => $payload } >> as
defined by L<Mojo::Rennari::Protocol>. The server dispatches each frame
to a handler registered with L</on>.

=head1 ATTRIBUTES

=head2 auth_cb

  auth_cb => sub { my $c = shift; ... }

Called with the Mojolicious controller during the HTTP request. Must
return a truthy identity (typically a hashref) on success, falsy on
failure. A dying callback renders 500.

=head2 mock

When true, skips C<auth_cb>, synthesizes an identity, and ignores
unknown events instead of closing the connection. Refused when
C<MOJO_MODE> is C<production> unless C<force_mock> is also set.

=head2 force_mock

Overrides the production refusal of C<mock>. Use only in controlled
environments.

=head2 max_bytes

Maximum accepted frame size in bytes. Default 64 KiB. Passed through
to L<Mojo::Rennari::Protocol/decode_frame>.

=head2 logger

Optional. If unset, logs go to C<warn>.

=head1 METHODS

=head2 on

  $server->on('smile' => sub { my ($c, $payload) = @_; ... });

Registers a handler for an event name. The name must be a valid
Mojo::Rennari event name. Return value, if defined, is sent back to the
sender as a C<reply> frame.

=head2 websocket_route

  $rennari->websocket_route($c);

Called from inside a C<websocket> route callback with the controller.
Performs authentication and, on success, wires up the message handlers
on the upgraded connection.

=head1 CLOSE CODES

  4002  bad frame
  4003  unknown event
  4004  handler error

=head1 LICENSE

Same terms as Perl itself.

=cut

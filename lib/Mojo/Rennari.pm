package Mojo::Rennari;
use Mojo::Base -strict;

our $VERSION = '0.001';

1;
__END__

=head1 NAME

Mojo::Rennari - real-time event transport for Mojolicious

=head1 SYNOPSIS

  # server side (in a Mojolicious app)
  use Mojo::Rennari::Server;

  my $rennari = Mojo::Rennari::Server->new(
      auth_cb => sub ($c) {
          my $token = $c->param('token') // return undef;
          return undef unless $token eq 'valid';
          return { user_id => 42 };
      },
  );

  $rennari->on('smile' => sub ($c, $payload) {
      return { ok => 1, received => $payload };
  });

  # inside a route
  $rennari->websocket_route($c);

=head1 DESCRIPTION

Mojo::Rennari is a small, Viking-named real-time messaging layer for
Mojolicious. It is not a Socket.IO clone and does not chase Socket.IO
protocol compatibility. Instead it offers a lean, secure, MessagePack-
framed event transport with a handful of well-chosen features:

=over 4

=item * Authentication happens before the WebSocket upgrade.

=item * Frames are MessagePack-encoded C<< { e => $event, d => $payload } >>.

=item * Handlers are plain Perl callbacks: C<< $server->on('name' => sub { ... }) >>.

=item * A C<mock> mode exists for development and is refused in production.

=item * The client protocol handler is transport-agnostic; the browser
transport is a thin JavaScript bridge written later.

=back

The name comes from Old Norse I<rennari>, "runner, messenger, envoy."

=head1 LICENSE

Same terms as Perl itself.

=cut

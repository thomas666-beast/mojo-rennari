package Mojo::Rennari;
use Mojo::Base -strict;

our $VERSION = '0.003';

1;
__END__

=head1 NAME

Mojo::Rennari - real-time event transport for Mojolicious

=head1 SYNOPSIS

  # server side (in a Mojolicious app)
  use Mojo::Rennari::Server;

  my $rennari = Mojo::Rennari::Server->new(
      auth_cb => sub ($c) {
          my ($c) = @_;
          my $token = $c->param('token') // return undef;
          return undef unless $token eq 'valid';
          return { id => 'user-42' };
      },
  );

  $rennari->on('smile' => sub {
      my ($c, $payload) = @_;
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

=head1 PROJECT GENERATOR

    mojo-rennari generate lite demo
    mojo-rennari generate app MyApp

The Lite generator writes C<server.pl> and C<client.pl>. The App
generator creates C<server/> and C<client/> trees with class-based
modules and independent runners. Both starters read YAML configuration files and use C<TOKEN_APP>
for application access. User authentication is configured separately in
C<auth_cb>. No token environment exports are required. Run C<mojo-rennari help> for usage.

=head1 LICENSE

Same terms as Perl itself.

=cut

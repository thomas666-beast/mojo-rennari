package Mojo::Rennari::Connection;
use Mojo::Base -base;

our $VERSION = '0.002';

has 'server';
has 'id';
has 'namespace' => '/';

sub _nsp { my $self = shift; $self->server->namespace($self->namespace) }

sub join {
    my ($self, $room) = @_;
    $self->_nsp->join($self->id, $room);
    return $self;
}

sub leave {
    my ($self, $room) = @_;
    $self->_nsp->leave($self->id, $room);
    return $self;
}

sub broadcast_to_room {
    my ($self, $room, $event, $payload) = @_;
    return $self->_nsp->broadcast_to_room($room, $event, $payload);
}

sub members_of {
    my ($self, $room) = @_;
    return $self->_nsp->members_of($room);
}

sub rooms {
    my $self = shift;
    return $self->_nsp->rooms_of($self->id);
}

# reply on the namespace the current frame arrived on
sub send_to_self {
    my ($self, $event, $payload) = @_;
    return $self->server->_send_to_connection(
        $self->id, $event, $payload, $self->namespace);
}

sub send_to {
    my ($self, $id, $event, $payload) = @_;
    return $self->server->_send_to_connection(
        $id, $event, $payload, $self->namespace);
}

# send to every member of the current namespace
sub broadcast {
    my ($self, $event, $payload) = @_;
    return $self->_nsp->broadcast($event, $payload);
}

1;
__END__

=head1 NAME

Mojo::Rennari::Connection - per-connection helper

=head1 DESCRIPTION

Returned by C<< $c->rennari >>. The C<namespace> attribute is set by the
server to the namespace of the frame being handled, so handlers can use
the room and send methods without naming it. All send methods tag their
frames with that namespace and route through the server's
C<_send_to_connection>, which handles offline buffering when recovery
is on.

C<broadcast> reaches the members of the current namespace only.

=head1 LICENSE

Same terms as Perl itself.

=cut

package Mojo::Rennari::Connection;
use Mojo::Base -base;

our $VERSION = '0.001';

has 'server';
has 'id';
has 'namespace' => '/';

sub join {
    my ($self, $room) = @_;
    $self->server->namespace($self->namespace)->join($self->id, $room);
    return $self;
}

sub leave {
    my ($self, $room) = @_;
    $self->server->namespace($self->namespace)->leave($self->id, $room);
    return $self;
}

sub broadcast_to_room {
    my ($self, $room, $event, $payload) = @_;
    return $self->server->namespace($self->namespace)
        ->broadcast_to_room($room, $event, $payload);
}

sub members_of {
    my ($self, $room) = @_;
    return $self->server->namespace($self->namespace)->members_of($room);
}

sub rooms {
    my $self = shift;
    return $self->server->namespace($self->namespace)->rooms_of($self->id);
}

sub send_to_self {
    my ($self, $event, $payload) = @_;
    return $self->server->_send_to_connection($self->id, $event, $payload);
}

sub send_to {
    my ($self, $id, $event, $payload) = @_;
    return $self->server->_send_to_connection($id, $event, $payload);
}

sub broadcast {
    my ($self, $event, $payload) = @_;
    my $count = 0;
    for my $id (keys %{ $self->server->_connections }) {
        $count++ if $self->server->_send_to_connection($id, $event, $payload);
    }
    return $count;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Connection - per-connection helper

=head1 DESCRIPTION

Returned by C<< $c->rennari >>. All room methods operate within the
connection's current namespace. Send methods route through the server's
C<_send_to_connection>, which handles offline buffering when recovery
is on.

=head1 LICENSE

Same terms as Perl itself.

=cut

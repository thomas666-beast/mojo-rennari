package Mojo::Rennari::Connection;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame);

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
    my $conn = $self->server->_connections->{ $self->id } or return 0;
    eval { $conn->{tx}->send({binary => encode_frame($event, $payload)}) };
    $self->server->_log(warn => "rennari: send_to_self failed: $@") if $@;
    return $@ ? 0 : 1;
}

sub send_to {
    my ($self, $id, $event, $payload) = @_;
    my $conn = $self->server->_connections->{$id} or return 0;
    eval { $conn->{tx}->send({binary => encode_frame($event, $payload)}) };
    $self->server->_log(warn => "rennari: send_to failed: $@") if $@;
    return $@ ? 0 : 1;
}

sub broadcast {
    my ($self, $event, $payload) = @_;
    my $bytes = encode_frame($event, $payload);
    my $count = 0;
    for my $id (keys %{ $self->server->_connections }) {
        my $conn = $self->server->_connections->{$id} or next;
        eval { $conn->{tx}->send({binary => $bytes}) };
        $self->server->_log(warn => "rennari: broadcast failed: $@") if $@;
        $count++ unless $@;
    }
    return $count;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Connection - per-connection helper

=head1 DESCRIPTION

Returned by C<< $c->rennari >>. All room methods operate within the
connection's current namespace. See L<Mojo::Rennari::Server>.

=head1 LICENSE

Same terms as Perl itself.

=cut

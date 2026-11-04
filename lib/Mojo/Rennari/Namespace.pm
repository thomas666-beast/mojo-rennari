package Mojo::Rennari::Namespace;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame);

our $VERSION = '0.001';

has 'name'         => '/';
has 'server';
has '_handlers'    => sub { {} };
has '_rooms'       => sub { {} };   # room -> { id => 1 }
has '_connections' => sub { {} };   # id    -> 1

sub on {
    my ($self, $event, $cb) = @_;
    die 'on: invalid event name'
        unless Mojo::Rennari::Protocol::valid_event_name($event);
    die 'on: handler must be a code ref'
        unless ref $cb eq 'CODE';
    $self->_handlers->{$event} = $cb;
    return $self;
}

sub handler_for {
    my ($self, $event) = @_;
    return $self->_handlers->{$event};
}

sub attach {
    my ($self, $id) = @_;
    $self->_connections->{$id} = 1;
    return $self;
}

sub detach {
    my ($self, $id) = @_;
    delete $self->_connections->{$id};
    for my $room (keys %{ $self->_rooms }) {
        delete $self->_rooms->{$room}{$id};
        delete $self->_rooms->{$room}
            if $self->_rooms->{$room} && !%{ $self->_rooms->{$room} };
    }
    return $self;
}

sub join {
    my ($self, $id, $room) = @_;
    die 'join: room name required' unless defined $room && length $room;
    return unless $self->_connections->{$id};
    $self->_rooms->{$room}{$id} = 1;
    return $self;
}

sub leave {
    my ($self, $id, $room) = @_;
    return $self unless defined $room;
    delete $self->_rooms->{$room}{$id};
    delete $self->_rooms->{$room}
        if $self->_rooms->{$room} && !%{ $self->_rooms->{$room} };
    return $self;
}

sub members_of {
    my ($self, $room) = @_;
    my $members = $self->_rooms->{$room} or return [];
    return [sort keys %$members];
}

sub rooms_of {
    my ($self, $id) = @_;
    my @rooms;
    for my $room (keys %{ $self->_rooms }) {
        push @rooms, $room if $self->_rooms->{$room}{$id};
    }
    return [sort @rooms];
}

sub broadcast_to_room {
    my ($self, $room, $event, $payload) = @_;
    my $members = $self->_rooms->{$room} or return 0;
    my $server  = $self->server;
    my $count   = 0;
    for my $id (keys %$members) {
        my $conn = $server->_connections->{$id} or next;
        next unless $conn->{namespaces}{ $self->name };
        $count++ if $server->_send_to_connection($id, $event, $payload);
    }
    return $count;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Namespace - one namespace's handlers, rooms, and members

=head1 SYNOPSIS

  my $chat = $server->namespace('/chat');
  $chat->on('message' => sub { ... });

=head1 DESCRIPTION

Namespaces multiplex multiple logical channels over a single WebSocket
connection, like Socket.IO. Each namespace has its own handlers, rooms,
and member set.

Use the default C</> namespace via C<< $server->on(...) >>. Use named
namespaces via C<< $server->namespace($name)->on(...) >>.

=head1 LICENSE

Same terms as Perl itself.

=cut

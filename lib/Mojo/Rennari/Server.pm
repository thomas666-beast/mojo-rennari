package Mojo::Rennari::Server;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojo::Rennari::Connection;
use Mojo::Rennari::Namespace;
use Mojo::IOLoop;

our $VERSION = '0.001';

{
    no strict 'refs';
    no warnings 'redefine';
    *Mojolicious::Controller::rennari = sub {
        my $c = shift;
        return $c->stash('rennari');
    } unless Mojolicious::Controller->can('rennari');
}

has 'auth_cb';
has 'mock'          => 0;
has 'force_mock'    => 0;
has 'max_bytes'     => 64 * 1024;
has 'serializer'    => 'msgpack';
has 'logger';
has 'recovery'      => 0;
has 'recovery_window' => 120;

has 'on_connect_cb';
has 'on_disconnect_cb';
has 'on_error_cb';

has '_namespaces'  => sub { {} };
has '_connections' => sub { {} };
has '_sessions'    => sub { {} };
has '_next_id'     => 0;

sub namespace {
    my ($self, $name) = @_;
    $name //= '/';
    return $self->_namespaces->{$name}
        //= Mojo::Rennari::Namespace->new(name => $name, server => $self);
}

sub on {
    my $self = shift;
    return $self->namespace('/')->on(@_);
}

sub on_connect    { my ($s, $cb) = @_; die 'code ref' unless ref $cb eq 'CODE'; $s->on_connect_cb($cb);    $s }
sub on_disconnect { my ($s, $cb) = @_; die 'code ref' unless ref $cb eq 'CODE'; $s->on_disconnect_cb($cb); $s }
sub on_error      { my ($s, $cb) = @_; die 'code ref' unless ref $cb eq 'CODE'; $s->on_error_cb($cb);      $s }

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
    if (my $logger = $self->logger) { $logger->$level($msg) }
    else { warn "[rennari $level] $msg\n" }
}

sub _fire {
    my ($self, $kind, @args) = @_;
    my $cb = $self->can("on_${kind}_cb")->($self);
    return unless $cb;
    eval { $cb->(@args) };
    $self->_log(error => "on_$kind died: $@") if $@;
}

sub _new_session_id {
    my $self = shift;
    my $id = '';
    $id .= sprintf '%02x', int(rand(256)) for 1 .. 16;
    return $id;
}

sub _session_of {
    my ($self, $id) = @_;
    my $conn = $self->_connections->{$id} or return undef;
    return $conn->{session_id} ? $self->_sessions->{ $conn->{session_id} } : undef;
}

sub broadcast_to_room {
    my ($self, $room, $event, $payload) = @_;
    return $self->namespace('/')->broadcast_to_room($room, $event, $payload);
}

sub members_of {
    my ($self, $room) = @_;
    return $self->namespace('/')->members_of($room);
}

sub rooms_of {
    my ($self, $id) = @_;
    my $conn = $self->_connections->{$id} or return [];
    my %seen;
    for my $nsp_name (keys %{ $conn->{namespaces} }) {
        my $nsp = $self->_namespaces->{$nsp_name} or next;
        $seen{$_} = 1 for @{ $nsp->rooms_of($id) };
    }
    return [sort keys %seen];
}

# send a frame to one connection, buffering if recovery is on and the
# connection is in the disconnected-but-recoverable state
sub _send_to_connection {
    my ($self, $id, $event, $payload) = @_;
    my $conn = $self->_connections->{$id};
    my $s    = $self->serializer;

    if ($conn && $conn->{tx} && !$conn->{offline}) {
        my $next_offset;
        if ($self->recovery) {
            $next_offset = ++$conn->{offset};
            if ($conn->{session_id} && (my $sess = $self->_sessions->{ $conn->{session_id} })) {
                $sess->{offset} = $next_offset;
            }
        }
        my $bytes = encode_frame($event, $payload, $s, undef, $next_offset);
        eval { $conn->{tx}->send({binary => $bytes}) };
        $self->_log(warn => "rennari: send failed: $@") if $@;
        return 1;
    }

    # offline: buffer if recovery
    return 0 unless $self->recovery;
    my $session = $self->_session_of($id) or return 0;
    my $offset  = ++$session->{offset};
    my $bytes   = encode_frame($event, $payload, $s, undef, $offset);
    my $offset  = ++$session->{offset};
    push @{ $session->{buffered} }, { offset => $offset, bytes => $bytes };
    return 1;
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

    my $id      = ++$self->{_next_id};
    my $session = $self->_new_session_id;
    my $conn    = Mojo::Rennari::Connection->new(server => $self, id => $id);
    my $s       = $self->serializer;

    $c->stash(rennari_id       => $id);
    $c->stash(rennari_session  => $session);
    $c->stash(rennari_identity => $identity);
    $c->stash(rennari          => $conn);

    $self->_connections->{$id} = {
        tx         => $c->tx,
        identity   => $identity,
        session_id => $session,
        namespaces => {},
        offset     => 0,
        offline    => 0,
    };

    if ($self->recovery) {
        $self->_sessions->{$session} = {
            id         => $session,
            identity   => $identity,
            namespaces => {},
            rooms      => {},
            offset     => 0,
            buffered   => [],
        };
    }

    # default namespace
    my $default = $self->namespace('/');
    $default->attach($id);
    $self->_connections->{$id}{namespaces}{'/'} = 1;
    $c->stash(rennari_namespace => '/');
    $conn->namespace('/');

    # announce session and default namespace
    if ($self->recovery) {
        $self->_send_to_connection($id, 'rennari_session', { id => $session });
    }

    my $max     = $self->max_bytes;
    my $is_mock = $mock;

    $self->_log(info => "rennari: connection opened ($identity->{id})");
    $self->_fire(connect => $c, $identity);

    $c->on(message => sub {
        my ($c, $bytes) = @_;

        my $frame = decode_frame(
            $bytes, max_bytes => $max, serializer => $s,
        );
        unless ($frame) {
            $self->_log(warn => "rennari: bad frame from $identity->{id}");
            $self->_fire(error => $c, 'bad_frame', undef);
            return $c->tx->finish(4002, 'bad frame');
        }

        my $event = $frame->{e};
        my $data  = $frame->{d};
        my $fid   = $frame->{id};

        # --- resume -------------------------------------------------
        if ($event eq 'rennari_resume') {
            return $self->_handle_resume($c, $id, $data, $s);
        }

        # --- namespace switch ---------------------------------------
        if ($event eq 'rennari_nsp') {
            my $name = $data->{name} // '/';
            my $nsp  = $self->_namespaces->{$name};
            unless ($nsp) {
                $self->_log(warn => "rennari: unknown namespace '$name'");
                $self->_fire(error => $c, 'unknown_namespace', $name);
                return $c->tx->finish(4005, 'unknown namespace');
            }
            $nsp->attach($id);
            $self->_connections->{$id}{namespaces}{$name} = 1;
            $c->stash(rennari_namespace => $name);
            $conn->namespace($name);
            $self->_send_to_connection($id, 'rennari_nsp_ok', { name => $name });
            return;
        }

        my $current = $c->stash('rennari_namespace') // '/';
        my $nsp     = $self->_namespaces->{$current} or return;
        my $cb      = $nsp->handler_for($event);

        unless ($cb) {
            $self->_fire(error => $c, 'unknown_event', $event);
            if ($is_mock) {
                $self->_log(debug => "rennari: mock ignoring '$event'");
                return;
            }
            $self->_log(warn => "rennari: unknown event '$event' in '$current'");
            return $c->tx->finish(4003, 'unknown event');
        }

        my $reply = eval { $cb->($c, $data) };
        if ($@) {
            $self->_log(error => "rennari: handler '$event' died: $@");
            $self->_fire(error => $c, 'handler_error', $event);
            return $c->tx->finish(4004, 'handler error');
        }

        if (defined $reply) {
            $self->_send_to_connection($id, 'reply', $reply);
        }

        if (defined $fid) {
            $self->_send_to_connection($id, 'rennari_ack', { id => $fid });
        }
    });

    $c->on(finish => sub {
        $self->_log(info => "rennari: connection closed ($identity->{id})");
        my $conn = $self->_connections->{$id};

        if ($conn) {
            for my $nsp_name (keys %{ $conn->{namespaces} }) {
                my $nsp = $self->_namespaces->{$nsp_name} or next;
                $nsp->detach($id);
            }

            # keep session alive for recovery window
            if ($self->recovery && $conn->{session_id}) {
                my $sess = $self->_sessions->{ $conn->{session_id} };
                if ($sess) {
                    $sess->{namespaces} = { %{ $conn->{namespaces} } };
                    $sess->{rooms}      = {};
                    for my $nsp_name (keys %{ $conn->{namespaces} }) {
                        my $nsp = $self->_namespaces->{$nsp_name} or next;
                        my $rooms = $nsp->rooms_of($id);
                        $sess->{rooms}{$nsp_name} = $rooms if @$rooms;
                    }
                    $conn->{offline} = 1;
                    my $sid = $conn->{session_id};
                    Mojo::IOLoop->timer($self->recovery_window => sub {
                        delete $self->_sessions->{$sid};
                    });
                }
            }
            else {
                delete $self->_connections->{$id};
            }
        }

        $self->_fire(disconnect => $c, $identity);
    });

    return undef;
}

sub _handle_resume {
    my ($self, $c, $new_id, $data, $s) = @_;

    return $c->tx->finish(4006, 'recovery disabled') unless $self->recovery;

    my $sid    = $data->{session_id} // '';
    my $offset = $data->{offset}     // -1;

    my $sess = $self->_sessions->{$sid};
    unless ($sess) {
        return $self->_send_to_connection($new_id, 'rennari_resume_failed',
            { reason => 'unknown_session' });
    }

    # re-attach namespaces and rooms
    for my $nsp_name (keys %{ $sess->{namespaces} }) {
        my $nsp = $self->_namespaces->{$nsp_name} or next;
        $nsp->attach($new_id);
        $self->_connections->{$new_id}{namespaces}{$nsp_name} = 1;
    }
    for my $nsp_name (keys %{ $sess->{rooms} }) {
        my $nsp = $self->_namespaces->{$nsp_name} or next;
        $nsp->join($new_id, $_) for @{ $sess->{rooms}{$nsp_name} };
    }

    # replay buffered frames past the client's offset
    my @replay = grep { $_->{offset} > $offset } @{ $sess->{buffered} };
    for my $entry (@replay) {
        eval { $c->send({binary => $entry->{bytes}}) };
        $self->_log(warn => "rennari: replay send failed: $@") if $@;
    }

    # transfer session to the new connection
    $self->_connections->{$new_id}{session_id} = $sid;
    $self->_connections->{$new_id}{offset}     = $sess->{offset};
    $sess->{buffered} = [];

    $self->_send_to_connection($new_id, 'rennari_resumed',
        { offset => $sess->{offset} });

    return;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Server - WebSocket event server

=head1 RECOVERY

Set C<< recovery => 1 >> to enable connection state recovery. The server
issues a private session id, tracks an offset on every outbound frame,
and buffers frames sent to a connection that has temporarily dropped.

On reconnect, the client sends C<< { e => 'rennari_resume', d => { session_id, offset } } >>.
If the session is still alive (within C<recovery_window> seconds, default
120), the server replays missed frames and re-attaches namespaces and
rooms.

Sessions expire C<recovery_window> seconds after disconnect.

=head1 LICENSE

Same terms as Perl itself.

=cut

package Mojo::Rennari::Server;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojo::Rennari::Connection;
use Mojo::Rennari::Namespace;
use Mojo::IOLoop;

our $VERSION = '0.002';

{
    no strict 'refs';
    no warnings 'redefine';
    *Mojolicious::Controller::rennari = sub {
        my $c = shift;
        return $c->stash('rennari');
    } unless Mojolicious::Controller->can('rennari');
}

has 'auth_cb';
has 'mock'            => 0;
has 'force_mock'      => 0;
has 'max_bytes'       => 64 * 1024;
has 'serializer'      => 'msgpack';
has 'logger';
has 'recovery'        => 0;
has 'recovery_window' => 120;
has 'inactivity_timeout' => 300;

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

sub broadcast {
    my ($self, $event, $payload) = @_;
    return $self->namespace('/')->broadcast($event, $payload);
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

# Send a frame to one connection, tagged with a namespace (default '/').
# If recovery is on and the connection is offline, buffer it on the session.
sub _send_to_connection {
    my ($self, $id, $event, $payload, $nsp) = @_;
    $nsp //= '/';
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
        my $bytes = encode_frame($event, $payload, $s, undef, $next_offset, $nsp);
        eval { $conn->{tx}->send({binary => $bytes}) };
        $self->_log(warn => "rennari: send failed: $@") if $@;
        return 1;
    }

    # offline: buffer if recovery
    return 0 unless $self->recovery;
    my $session = $self->_session_of($id) or return 0;
    my $offset  = ++$session->{offset};
    my $bytes   = encode_frame($event, $payload, $s, undef, $offset, $nsp);
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

    # Mojolicious closes idle connections after 30s by default
    $c->inactivity_timeout($self->inactivity_timeout);

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
            conn_id    => $id,
            offline    => 0,
            gen        => 0,
        };
    }

    # default namespace
    my $default = $self->namespace('/');
    $default->attach($id);
    $self->_connections->{$id}{namespaces}{'/'} = 1;
    $c->stash(rennari_namespace => '/');
    $conn->namespace('/');

    # announce session
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

        # --- namespace join -----------------------------------------
        if ($event eq 'rennari_nsp') {
            my $name = (ref $data eq 'HASH' ? $data->{name} : undef) // '/';
            my $nsp  = $self->_namespaces->{$name};
            unless ($nsp) {
                $self->_log(warn => "rennari: unknown namespace '$name'");
                $self->_fire(error => $c, 'unknown_namespace', $name);
                return $c->tx->finish(4005, 'unknown namespace');
            }
            $nsp->attach($id);
            $self->_connections->{$id}{namespaces}{$name} = 1;
            $self->_send_to_connection($id, 'rennari_nsp_ok', { name => $name });
            return;
        }

        # --- regular event: routed by the frame's own namespace -----
        my $nsp_name = $frame->{n} // '/';
        my $nsp      = $self->_namespaces->{$nsp_name};
        unless ($nsp && $self->_connections->{$id}{namespaces}{$nsp_name}) {
            $self->_log(warn => "rennari: frame for unjoined namespace '$nsp_name'");
            $self->_fire(error => $c, 'unknown_namespace', $nsp_name);
            return $c->tx->finish(4005, 'unknown namespace');
        }

        # handlers use $c->rennari, which follows the frame being handled
        $conn->namespace($nsp_name);
        $c->stash(rennari_namespace => $nsp_name);

        my $cb = $nsp->handler_for($event);
        unless ($cb) {
            $self->_fire(error => $c, 'unknown_event', $event);
            if ($is_mock) {
                $self->_log(debug => "rennari: mock ignoring '$event'");
                return;
            }
            $self->_log(warn => "rennari: unknown event '$event' in '$nsp_name'");
            return $c->tx->finish(4003, 'unknown event');
        }

        my $reply = eval { $cb->($c, $data) };
        if ($@) {
            $self->_log(error => "rennari: handler '$event' died: $@");
            $self->_fire(error => $c, 'handler_error', $event);
            return $c->tx->finish(4004, 'handler error');
        }

        if (defined $reply) {
            $self->_send_to_connection($id, 'reply', $reply, $nsp_name);
        }

        if (defined $fid) {
            $self->_send_to_connection($id, 'rennari_ack', { id => $fid });
        }
    });

    $c->on(finish => sub {
        $self->_log(info => "rennari: connection closed ($identity->{id})");
        my $rec = $self->_connections->{$id};

        if ($rec) {
            # capture rooms BEFORE detaching: detach clears them
            my %rooms;
            for my $nsp_name (keys %{ $rec->{namespaces} }) {
                my $nsp = $self->_namespaces->{$nsp_name} or next;
                my $r = $nsp->rooms_of($id);
                $rooms{$nsp_name} = $r if @$r;
            }

            for my $nsp_name (keys %{ $rec->{namespaces} }) {
                my $nsp = $self->_namespaces->{$nsp_name} or next;
                $nsp->detach($id);
            }

            my $sid  = $rec->{session_id};
            my $sess = ($self->recovery && $sid) ? $self->_sessions->{$sid} : undef;

            if ($sess) {
                # keep the session alive for the recovery window
                $sess->{namespaces} = { %{ $rec->{namespaces} } };
                $sess->{rooms}      = \%rooms;
                $sess->{conn_id}    = $id;
                $sess->{offline}    = 1;
                $rec->{offline}     = 1;
                my $gen = ++$sess->{gen};

                Mojo::IOLoop->timer($self->recovery_window => sub {
                    my $cur = $self->_sessions->{$sid} or return;
                    # a resume (or a later disconnect) bumps gen: leave it alone
                    return unless $cur->{offline} && $cur->{gen} == $gen;
                    delete $self->_connections->{ $cur->{conn_id} };
                    delete $self->_sessions->{$sid};
                });
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

    $data = {} unless ref $data eq 'HASH';
    my $sid    = $data->{session_id} // '';
    my $offset = $data->{offset}     // -1;
    $offset = -1 unless $offset =~ /\A-?[0-9]+\z/;

    my $sess = $sid ne '' ? $self->_sessions->{$sid} : undef;
    unless ($sess && $sess->{offline}) {
        return $self->_send_to_connection($new_id, 'rennari_resume_failed',
            { reason => 'unknown_session' });
    }

    my $new = $self->_connections->{$new_id};

    # drop the throwaway session created for this connection and the
    # offline record of the connection being resumed
    delete $self->_sessions->{ $new->{session_id} };
    delete $self->_connections->{ $sess->{conn_id} }
        if defined $sess->{conn_id} && $sess->{conn_id} != $new_id;

    # re-attach namespaces and rooms
    for my $nsp_name (keys %{ $sess->{namespaces} }) {
        my $nsp = $self->_namespaces->{$nsp_name} or next;
        $nsp->attach($new_id);
        $new->{namespaces}{$nsp_name} = 1;
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

    # transfer the session to the new connection
    $new->{session_id} = $sid;
    $new->{offset}     = $sess->{offset};
    $sess->{buffered}  = [];
    $sess->{conn_id}   = $new_id;
    $sess->{offline}   = 0;
    $sess->{gen}++;    # cancels the pending expiry timer

    # report the session id so the client keeps using it, not the
    # throwaway one announced when this socket opened
    $self->_send_to_connection($new_id, 'rennari_resumed',
        { offset => $sess->{offset}, session_id => $sid });

    return;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Server - WebSocket event server

=head1 ATTRIBUTES

=head2 inactivity_timeout

Seconds of silence before a connection is closed. Default 300. Mojolicious
itself defaults to 30, which drops idle clients.

=head1 NAMESPACES

Every frame may carry an C<n> field naming its namespace (default C</>).
The server routes each incoming frame by that field, so handlers for
C</chat> and C</> never depend on connection state. A client must first
join a non-default namespace with C<rennari_nsp>; frames for a namespace
it has not joined close the connection with code 4005. Handlers see the
namespace of the frame being handled via C<< $c->rennari->namespace >>,
and everything they send is tagged with it.

=head1 RECOVERY

Set C<< recovery => 1 >> to enable connection state recovery. The server
issues a private session id, tracks an offset on every outbound frame,
and buffers frames sent to a connection that has temporarily dropped.

On reconnect, the client sends C<< { e => 'rennari_resume', d => { session_id, offset } } >>.
If the session is still alive (within C<recovery_window> seconds, default
120), the server replays missed frames, re-attaches namespaces and
rooms, and answers C<rennari_resumed> with the offset and session id. A
session that is unknown, expired, or still attached to a live connection
gets C<rennari_resume_failed>.

Sessions and their offline connection records are removed
C<recovery_window> seconds after disconnect unless resumed.

=head1 LICENSE

Same terms as Perl itself.

=cut

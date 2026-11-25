package Mojo::Rennari::Server;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame valid_namespace_name);
use Mojo::Rennari::Connection;
use Mojo::Rennari::Namespace;
use Mojo::IOLoop;
use Mojo::Util ();
use bytes ();

our $VERSION = '0.003';

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
has 'recovery_max_frames' => 256;
has 'recovery_max_bytes'  => 1024 * 1024;
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
    die 'namespace: invalid namespace' unless valid_namespace_name($name);
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
    my ($self, $mode) = @_;
    return 0 unless $self->mock;
    if ((($mode // '') eq 'production' || ($ENV{MOJO_MODE} // '') eq 'production')
        && !$self->force_mock) {
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
    if (my $random = Mojo::Util->can('random_bytes')) {
        return unpack 'H*', $random->(16);
    }

    # Older Mojolicious versions do not provide random_bytes.
    open my $source, '<:raw', '/dev/urandom'
        or die "No secure randomness available for recovery: $!";
    my $bytes = '';
    while (length($bytes) < 16) {
        my $read = sysread $source, $bytes, 16 - length($bytes), length($bytes);
        next if !defined $read && $!{EINTR};
        die "Cannot read secure randomness for recovery: $!" unless $read;
    }
    return unpack 'H*', $bytes;
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
        my $next_offset = $self->recovery ? $conn->{offset} + 1 : undef;
        my $sent = eval {
            my $bytes = encode_frame($event, $payload, $s, undef, $next_offset, $nsp);
            $conn->{tx}->send({binary => $bytes});
            1;
        };
        unless ($sent) {
            $self->_log(warn => "rennari: send failed: $@");
            return 0;
        }
        if (defined $next_offset) {
            $conn->{offset} = $next_offset;
            my $sess = $self->_session_of($id);
            $sess->{offset} = $next_offset if $sess;
        }
        return 1;
    }

    # offline: buffer if recovery
    return 0 unless $self->recovery;
    my $session = $self->_session_of($id) or return 0;
    my $offset = $session->{offset} + 1;
    my $bytes = eval { encode_frame($event, $payload, $s, undef, $offset, $nsp) };
    unless (defined $bytes) {
        $self->_log(warn => "rennari: buffer failed: $@");
        return 0;
    }
    my $size = $session->{buffered_bytes} + bytes::length($bytes);
    if (@{ $session->{buffered} } >= $self->recovery_max_frames || $size > $self->recovery_max_bytes) {
        delete $self->_sessions->{ $session->{id} };
        delete $self->_connections->{$id};
        return 0;
    }
    $session->{offset} = $offset;
    $session->{buffered_bytes} = $size;
    push @{ $session->{buffered} }, { offset => $offset, bytes => $bytes };
    return 1;
}

sub websocket_route {
    my ($self, $c) = @_;

    my $mock = $self->_mock_enabled($c->app->mode);
    my $s = Mojo::Rennari::Protocol::_check_serializer($self->serializer);

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
        unless (ref $identity eq 'HASH') {
            $self->_log(error => 'auth_cb must return a hash reference or reject authentication');
            return $c->render(status => 500, text => 'auth error');
        }
        if ($self->recovery && !(defined $identity->{id} && !ref $identity->{id} && length $identity->{id})) {
            $self->_log(error => 'recovery requires a stable identity id from auth_cb');
            return $c->render(status => 500, text => 'auth error');
        }
    }

    my $identity_id = $identity->{id} // '(unspecified)';
    # Mojolicious closes idle connections after 30s by default
    $c->inactivity_timeout($self->inactivity_timeout);

    my $id      = ++$self->{_next_id};
    my $session = $self->recovery ? $self->_new_session_id : undef;
    my $conn    = Mojo::Rennari::Connection->new(server => $self, id => $id);

    $c->stash(rennari_id       => $id);
    $c->stash(rennari_session  => $session);
    $c->stash(rennari_identity => $identity);
    $c->stash(rennari          => $conn);

    $self->_connections->{$id} = {
        tx         => $c->tx,
        owner_id   => "$identity_id",
        mock       => $mock,
        session_id => $session,
        namespaces => {},
        offset     => 0,
        offline    => 0,
    };

    if ($self->recovery) {
        $self->_sessions->{$session} = {
            id         => $session,
            owner_id   => "$identity_id",
            mock       => $mock,
            namespaces => {},
            rooms      => {},
            offset     => 0,
            buffered   => [],
            buffered_bytes => 0,
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

    $self->_log(info => "rennari: connection opened ($identity_id)");
    $self->_fire(connect => $c, $identity);

    $c->on(message => sub {
        my ($c, $bytes) = @_;

        my $frame = decode_frame(
            $bytes, max_bytes => $max, serializer => $s,
        );
        unless ($frame) {
            $self->_log(warn => "rennari: bad frame from $identity_id");
            $self->_fire(error => $c, 'bad_frame', undef);
            return $c->tx->finish(4002, 'bad frame');
        }

        my $event = $frame->{e};
        my $data  = $frame->{d};
        my $fid   = $frame->{id};

        # --- resume -------------------------------------------------
        if ($event eq 'rennari_resume') {
            return $self->_handle_resume($c, $id, $data);
        }

        # --- namespace join -----------------------------------------
        if ($event eq 'rennari_nsp') {
            my $name = ref $data eq 'HASH' ? $data->{name} : undef;
            my $nsp  = valid_namespace_name($name) ? $self->_namespaces->{$name} : undef;
            unless ($nsp) {
                $self->_log(warn => 'rennari: missing, invalid, or unknown namespace');
                $self->_fire(error => $c, 'unknown_namespace', ref $name ? undef : $name);
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

        if (defined $reply && !$self->_send_to_connection($id, 'reply', $reply, $nsp_name)) {
            $self->_fire(error => $c, 'handler_error', $event);
            return $c->tx->finish(4004, 'handler error');
        }

        if (defined $fid) {
            $self->_send_to_connection($id, 'rennari_ack', { id => $fid });
        }
    });

    $c->on(finish => sub {
        $self->_log(info => "rennari: connection closed ($identity_id)");
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
                delete $rec->{tx};
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
    my ($self, $c, $new_id, $data) = @_;

    return $c->tx->finish(4006, 'recovery disabled') unless $self->recovery;

    $data = {} unless ref $data eq 'HASH';
    my $sid    = $data->{session_id};
    my $offset = $data->{offset}     // -1;
    $offset = -1 unless Mojo::Rennari::Protocol::valid_offset($offset);
    my $new = $self->_connections->{$new_id};
    my $sess = defined $sid && !ref $sid && $sid =~ /\A[0-9a-f]{32}\z/
        ? $self->_sessions->{$sid} : undef;
    unless ($sess && $sess->{offline} && !$new->{resumed} && $sess->{mock} == $new->{mock}
        && ($sess->{mock} || $sess->{owner_id} eq $new->{owner_id})) {
        return $self->_send_to_connection($new_id, 'rennari_resume_failed',
            { reason => 'unknown_session' });
    }

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
    $new->{resumed}    = 1;
    $sess->{buffered}  = [];
    $sess->{buffered_bytes} = 0;
    $sess->{conn_id}   = $new_id;
    $sess->{offline}   = 0;
    $sess->{gen}++;    # cancels the pending expiry timer
    $c->stash(rennari_session => $sid);

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
C<recovery_window> seconds after disconnect unless resumed. When
recovery is enabled outside mock mode, the C<auth_cb> identity must
contain a stable C<id>. Only a connection authenticated as that same
identity can resume its session.

Offline buffers are limited per session by C<recovery_max_frames>
(default 256) and C<recovery_max_bytes> (default 1 MiB). Exceeding
either limit invalidates the offline session. Recovery is process-local.

=head1 LICENSE

Same terms as Perl itself.

=cut

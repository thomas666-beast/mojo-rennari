package Mojo::Rennari::Client;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame valid_event_name valid_id valid_namespace_name);
use Mojo::IOLoop;
use Mojo::UserAgent;
use Scalar::Util qw(weaken);

our $VERSION = '0.003';

has 'url';
has 'headers'     => sub { {} };
has 'serializer'  => 'msgpack';
has 'mock'        => 0;
has 'force_mock'  => 0;
has 'max_bytes'   => 64 * 1024;
has 'ack_timeout' => 5;
has 'retries'     => 3;
has 'logger';
has 'ua';
has '_handlers'   => sub { {} };
has '_pending'    => sub { {} };
has '_namespaces' => sub { {} };
has '_next_id'    => 0;
has '_tx';
has '_connecting' => 0;
has '_active_serializer';
has 'session_id';
has 'last_offset' => -1;

sub on {
    my ($self, $event, $cb) = @_;
    return $self->of('/')->on($event, $cb);
}

sub of {
    my ($self, $name) = @_;
    $name //= '/';
    die 'of: invalid namespace' unless valid_namespace_name($name);
    return $self->_namespaces->{$name} //=
        Mojo::Rennari::Client::Namespace->new(client => $self, name => $name);
}

sub _register {
    my ($self, $nsp, $event, $cb) = @_;
    die 'on: invalid event name' unless valid_event_name($event);
    die 'on: handler must be a code ref' unless ref $cb eq 'CODE';
    $self->_handlers->{"$nsp\0$event"} = $cb;
    return $self;
}

sub _unregister {
    my ($self, $nsp, $event) = @_;
    delete $self->_handlers->{"$nsp\0$event"};
    return $self;
}

sub _fire {
    my ($self, $nsp, $event, @args) = @_;
    my $cb = $self->_handlers->{"$nsp\0$event"} or return;
    eval { $cb->($self, @args) };
    $self->_log(error => "rennari: handler '$event' died: $@") if $@;
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

sub connect {
    my ($self, $cb) = @_;

    my $url = $self->url // die 'connect: url required';
    die 'connect: callback must be a code ref' if defined $cb && ref $cb ne 'CODE';
    die 'connect: connection already active' if $self->_connecting || $self->_tx;
    $self->_mock_enabled;
    my $serializer = Mojo::Rennari::Protocol::_check_serializer($self->serializer);
    my $headers = $self->headers;
    die 'connect: headers must be a hash reference' unless ref $headers eq 'HASH';

    my $ua = $self->ua // Mojo::UserAgent->new;
    $self->ua($ua);

    my $max = $self->max_bytes;

    my $handshake = $ua->build_websocket_tx($url, $headers);
    $self->_connecting(1);
    $ua->start($handshake => sub {
        my ($ua, $tx) = @_;
        $self->_connecting(0);

        unless ($tx->is_websocket) {
            my $code = $tx->res->code // '?';
            $self->_log(error => "rennari: handshake failed ($code)");
            $self->_fire('/', 'error', 'handshake failed');
            $cb->(undef, 'handshake failed') if $cb;
            return;
        }

        $self->_active_serializer($serializer);
        $self->session_id(undef);
        $self->last_offset(-1);
        $self->_tx($tx);
        $self->_log(info => 'rennari: connected');
        my $client = $self;
        weaken($client);

        $tx->on(message => sub {
            my ($tx, $bytes) = @_;
            $client->_on_message($bytes, $max, $serializer) if $client;
        });

        $tx->on(finish => sub {
            my ($tx, $code, $reason) = @_;
            return unless $client;
            if ($client->_tx && $client->_tx == $tx) {
                $client->_tx(undef);
                $client->_fail_pending('disconnected before acknowledgement');
            }
            $client->_log(info => "rennari: disconnected ($code)");
            $client->_fire('/', 'disconnect', { code => $code, reason => $reason });
        });

        for my $name (sort keys %{ $self->_namespaces }) {
            next if $name eq '/';
            $tx->send({binary => encode_frame('rennari_nsp', { name => $name }, $serializer)});
        }

        $self->_fire('/', 'connect');
        $cb->($tx, undef) if $cb;
    });

    return $self;
}

sub _on_message {
    my ($self, $bytes, $max, $serializer) = @_;

    my $frame = decode_frame($bytes, max_bytes => $max, serializer => $serializer);
    unless ($frame) {
        $self->_log(warn => 'rennari: bad frame from server');
        $self->_fire('/', 'error', 'bad frame');
        return;
    }

    my $event = $frame->{e};
    my $data  = $frame->{d};

    if (
        ($event eq 'rennari_session' && !(ref $data eq 'HASH' && _valid_session($data->{id})))
        || ($event eq 'rennari_resumed' && !(ref $data eq 'HASH'
            && _valid_session($data->{session_id})
            && Mojo::Rennari::Protocol::valid_offset($data->{offset})))
        || ($event eq 'rennari_ack' && !(ref $data eq 'HASH' && valid_id($data->{id})))
    ) {
        $self->_log(warn => "rennari: invalid '$event' payload");
        $self->_fire('/', 'error', 'bad frame');
        return;
    }

    if (defined $frame->{o} && $frame->{o} > $self->last_offset) {
        $self->last_offset($frame->{o});
    }

    if ($event eq 'rennari_session') {
        $self->session_id($data->{id});
        $self->last_offset($frame->{o} // -1);
        return;
    }
    if ($event eq 'rennari_nsp_ok') {
        return;
    }
    if ($event eq 'rennari_resumed') {
        $self->session_id($data->{session_id}) if $data->{session_id};
        $self->_fire('/', 'recovered', { offset => $data->{offset} });
        return;
    }
    if ($event eq 'rennari_resume_failed') {
        $self->session_id(undef);
        $self->last_offset(-1);
        return;
    }
    if ($event eq 'rennari_ack') {
        my $id = $data->{id};
        my $pending = delete $self->_pending->{$id};
        if ($pending) {
            $self->_complete_ack($pending, $data);
        }
        return;
    }

    my $nsp = $frame->{n} // '/';
    $self->_fire($nsp, $event, $data);
}

sub _valid_session {
    my ($id) = @_;
    return defined $id && !ref $id && $id =~ /\A[0-9a-f]{32}\z/i;
}

sub _send_frame {
    my ($self, $nsp, $event, $payload, $id) = @_;

    my $tx = $self->_tx // die 'send: not connected';
    my $bytes = encode_frame(
        $event, $payload, $self->_active_serializer // $self->serializer, $id, undef,
        ($nsp eq '/' ? undef : $nsp),
    );
    $tx->send({binary => $bytes});
    return 1;
}

sub send {
    my ($self, $event, $payload) = @_;
    return $self->_send_frame('/', $event, $payload, undef);
}

sub emit_with_ack {
    my ($self, $event, $payload, $cb) = @_;
    return $self->of('/')->emit_with_ack($event, $payload, $cb);
}

sub _emit_with_ack {
    my ($self, $nsp, $event, $payload, $cb) = @_;

    die 'emit_with_ack: callback must be a code ref' if defined $cb && ref $cb ne 'CODE';
    my $id = $self->_next_id + 1;
    $self->_next_id($id);
    $self->_send_attempt($nsp, $event, $payload, {
        id => $id, cb => $cb, remaining => $self->retries, timeout => $self->ack_timeout,
    });
    return $self;
}

sub _send_attempt {
    my ($self, $nsp, $event, $payload, $pending) = @_;
    my $id = $pending->{id};

    my $sent = eval { $self->_send_frame($nsp, $event, $payload, $id); 1 };
    return $self->_complete_ack($pending, undef, $@) unless $sent;

    $self->_pending->{$id} = $pending;
    weaken($self);
    $pending->{timer} = Mojo::IOLoop->timer($pending->{timeout} => sub {
        return unless $self && (my $entry = delete $self->_pending->{$id});
        delete $entry->{timer};
        return $self->_send_attempt($nsp, $event, $payload, $entry) if $entry->{remaining}-- > 0;
        $self->_fire('/', 'ack_timeout', { event => $event, payload => $payload });
        $self->_complete_ack($entry, undef, "ack timeout for '$event'");
    });
    return;
}

sub _complete_ack {
    my ($self, $pending, @args) = @_;
    Mojo::IOLoop->remove($pending->{timer}) if defined $pending->{timer};
    my $cb = $pending->{cb} or return;
    eval { $cb->(@args); 1 } or $self->_log(error => "rennari: acknowledgement callback died: $@");
    return;
}

sub _fail_pending {
    my ($self, $error) = @_;
    my $pending = $self->_pending;
    $self->_pending({});
    $self->_complete_ack($_, undef, $error) for values %$pending;
    return;
}

sub disconnect {
    my $self = shift;
    if (my $tx = $self->_tx) {
        $self->_tx(undef);
        $tx->finish;
        $self->_fail_pending('disconnected before acknowledgement');
    }
    return $self;
}

sub is_connected {
    my $self = shift;
    my $tx = $self->_tx;
    return $tx && $tx->is_websocket ? 1 : 0;
}

package Mojo::Rennari::Client::Namespace;
use Mojo::Base -base;

sub new {
    my $self = shift->SUPER::new(@_);
    Scalar::Util::weaken($self->{client}) if ref $self->{client};
    return $self;
}

has 'client';
has 'name';

sub on {
    my ($self, $event, $cb) = @_;
    $self->client->_register($self->name, $event, $cb);
    return $self;
}

sub off {
    my ($self, $event) = @_;
    $self->client->_unregister($self->name, $event);
    return $self;
}

sub send {
    my ($self, $event, $payload) = @_;
    return $self->client->_send_frame($self->name, $event, $payload, undef);
}

sub emit_with_ack {
    my ($self, $event, $payload, $cb) = @_;
    return $self->client->_emit_with_ack($self->name, $event, $payload, $cb);
}

1;
__END__

=head1 NAME

Mojo::Rennari::Client - WebSocket event client for Mojo::Rennari

=head1 SYNOPSIS

  use Mojo::Rennari::Client;
  use Mojo::IOLoop;

  my $client = Mojo::Rennari::Client->new(url => 'ws://127.0.0.1:3999/ws');

  $client->on('connect' => sub {
      my ($c) = @_;
      $c->of('/chat')->send('hello' => { n => 1 });
  });

  $client->on('reply' => sub {
      my ($c, $payload) = @_;
      say "reply: $payload->{ok}";
  });

  my $chat = $client->of('/chat');
  $chat->on('hello_back' => sub {
      my ($c, $payload) = @_;
      say "chat: $payload->{got}{n}";
  });

  $client->connect;
  Mojo::IOLoop->timer(2 => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;

=head1 LOCAL EVENTS

These fire on the default namespace and do not correspond to wire events:

  connect       fired after the WebSocket upgrade completes
  disconnect    fired on close; receives { code, reason }
  error         fired on handshake failure or bad frame; receives a string
  ack_timeout   fired when an emit_with_ack exhausts its retries;
                receives { event, payload }
  recovered     fired on rennari_resumed; receives { offset }

=head1 CONNECTION OPTIONS

C<serializer> is C<msgpack> (default) or C<json> and must match the
server. C<headers> is a hash reference of additional handshake headers,
for example C<< {Authorization => "Bearer $token"} >>. The library
does not log the connection URL.

Outstanding acknowledgement callbacks receive an error if the
connection closes. The Perl client does not automatically reconnect.

=head1 LICENSE

Same terms as Perl itself.

=cut

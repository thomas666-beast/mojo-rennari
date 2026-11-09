package Mojo::Rennari::Client;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojo::IOLoop;
use Mojo::UserAgent;

our $VERSION = '0.002';

has 'url';
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
has 'session_id';
has 'last_offset' => -1;

sub on {
    my ($self, $event, $cb) = @_;
    return $self->of('/')->on($event, $cb);
}

sub of {
    my ($self, $name) = @_;
    $name //= '/';
    return $self->_namespaces->{$name} //= Mojo::Rennari::Client::Namespace->new(
        client => $self,
        name   => $name,
    );
}

sub _register {
    my ($self, $nsp, $event, $cb) = @_;
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
    $self->_mock_enabled;

    my $ua = $self->ua // Mojo::UserAgent->new;
    $self->ua($ua);

    my $max = $self->max_bytes;

    $ua->websocket($url => sub {
        my ($ua, $tx) = @_;

        unless ($tx->is_websocket) {
            my $code = $tx->res->code // '?';
            $self->_log(error => "rennari: handshake failed ($code)");
            $self->_fire('/', 'error', 'handshake failed');
            $cb->(undef, 'handshake failed') if $cb;
            return;
        }

        $self->_tx($tx);
        $self->_log(info => "rennari: connected to $url");

        for my $name (keys %{ $self->_namespaces }) {
            next if $name eq '/';
            $tx->send({binary => encode_frame('rennari_nsp', { name => $name })});
        }

        $tx->on(message => sub {
            my ($tx, $bytes) = @_;
            $self->_on_message($bytes, $max);
        });

        $tx->on(finish => sub {
            my ($tx, $code, $reason) = @_;
            $self->_log(info => "rennari: disconnected ($code)");
            $self->_tx(undef);
            $self->_fire('/', 'disconnect', { code => $code, reason => $reason });
        });

        $self->_fire('/', 'connect');
        $cb->($tx, undef) if $cb;
    });

    return $self;
}

sub _on_message {
    my ($self, $bytes, $max) = @_;

    my $frame = decode_frame($bytes, max_bytes => $max);
    unless ($frame) {
        $self->_log(warn => 'rennari: bad frame from server');
        $self->_fire('/', 'error', 'bad frame');
        return;
    }

    if (defined $frame->{o} && $frame->{o} > $self->last_offset) {
        $self->last_offset($frame->{o});
    }

    my $event = $frame->{e};
    my $data  = $frame->{d};

    if ($event eq 'rennari_session') {
        $self->session_id($data->{id});
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
            $pending->{done} = 1;
            Mojo::IOLoop->remove($pending->{timer}) if $pending->{timer};
            $pending->{cb}->($data) if $pending->{cb};
        }
        return;
    }

    my $nsp = $frame->{n} // '/';
    $self->_fire($nsp, $event, $data);
}

sub _send_frame {
    my ($self, $nsp, $event, $payload, $id) = @_;

    my $tx = $self->_tx // die 'send: not connected';
    my $bytes = encode_frame(
        $event, $payload, undef, $id, undef,
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

    my $attempts = 0;
    my $timeout  = $self->ack_timeout;
    my $max      = $self->retries;

    my $try;
    $try = sub {
        $attempts++;

        my $next = $self->_next_id + 1;
        $self->_next_id($next);
        my $id = $next;

        my $pending = { cb => $cb, attempts => $attempts };
        $self->_pending->{$id} = $pending;

        eval { $self->_send_frame($nsp, $event, $payload, $id) };
        if ($@) {
            delete $self->_pending->{$id};
            $cb->(undef, $@) if $cb;
            return;
        }

        $pending->{timer} = Mojo::IOLoop->timer($timeout => sub {
            return if $pending->{done};
            delete $self->_pending->{$id};
            if ($attempts > $max) {
                $self->_fire('/', 'ack_timeout', { event => $event, payload => $payload });
                $cb->(undef, "ack timeout for '$event'") if $cb;
                return;
            }
            $try->();
        });
    };

    $try->();
    return $self;
}

sub disconnect {
    my $self = shift;
    if (my $tx = $self->_tx) {
        $tx->finish;
        $self->_tx(undef);
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

=head1 LICENSE

Same terms as Perl itself.

=cut

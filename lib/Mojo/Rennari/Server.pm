package Mojo::Rennari::Server;
use Mojo::Base -base;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame);
use Mojo::Rennari::Connection;
use Mojo::Rennari::Namespace;

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
has 'mock'         => 0;
has 'force_mock'   => 0;
has 'max_bytes'    => 64 * 1024;
has 'logger';

has 'on_connect_cb';
has 'on_disconnect_cb';
has 'on_error_cb';

has '_namespaces'  => sub { {} };
has '_connections' => sub { {} };   # id -> { tx, identity, namespaces => { nsp => 1 } }
has '_next_id'     => 0;

has 'serializer' => 'msgpack';

sub namespace {
    my ($self, $name) = @_;
    $name //= '/';
    return $self->_namespaces->{$name} //= Mojo::Rennari::Namespace->new(name => $name, server => $self);
}

sub on {
    my $self = shift;
    return $self->namespace('/')->on(@_);
}

sub on_connect {
    my ($self, $cb) = @_;
    die 'on_connect: handler must be a code ref' unless ref $cb eq 'CODE';
    $self->on_connect_cb($cb);
    return $self;
}

sub on_disconnect {
    my ($self, $cb) = @_;
    die 'on_disconnect: handler must be a code ref' unless ref $cb eq 'CODE';
    $self->on_disconnect_cb($cb);
    return $self;
}

sub on_error {
    my ($self, $cb) = @_;
    die 'on_error: handler must be a code ref' unless ref $cb eq 'CODE';
    $self->on_error_cb($cb);
    return $self;
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

sub _fire {
    my ($self, $kind, @args) = @_;
    my $cb = $self->can("on_${kind}_cb")->($self);
    return unless $cb;
    eval { $cb->(@args) };
    $self->_log(error => "on_$kind died: $@") if $@;
    return;
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

sub websocket_route {
    my ($self, $c) = @_;

    my $mock = $self->_mock_enabled;
    my $serializer = $self->serializer;

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

    my $id   = ++$self->{_next_id};
    my $conn = Mojo::Rennari::Connection->new(
        server => $self,
        id     => $id,
    );

    $c->stash(rennari_id       => $id);
    $c->stash(rennari_identity => $identity);
    $c->stash(rennari          => $conn);

    $self->_connections->{$id} = {
        tx         => $c->tx,
        identity   => $identity,
        namespaces => {},
    };

    # default namespace attaches on connect
    my $default = $self->namespace('/');
    $default->attach($id);
    $self->_connections->{$id}{namespaces}{'/'} = 1;
    $c->stash(rennari_namespace => '/');
    $conn->namespace('/');

    my $max     = $self->max_bytes;
    my $is_mock = $mock;

    $self->_log(info => "rennari: connection opened ($identity->{id})");
    $self->_fire(connect => $c, $identity);

    $c->on(message => sub {
        my ($c, $bytes) = @_;
        my $serializer = $self->serializer;

        my $frame = decode_frame(
            $bytes,
            max_bytes  => $max,
            serializer => $serializer,
        );
        unless ($frame) {
            $self->_log(warn => "rennari: bad frame from $identity->{id}");
            $self->_fire(error => $c, 'bad_frame', undef);
            return $c->tx->finish(4002, 'bad frame');
        }

        my $event = $frame->{e};
        my $data  = $frame->{d};
        my $fid   = $frame->{id};

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
            $c->send({
                binary => encode_frame('rennari_nsp_ok',
                    { name => $name }, $serializer),
            });
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
            eval {
                $c->send({
                    binary => encode_frame('reply', $reply, $serializer),
                });
            };
            $self->_log(error => "rennari: send failed: $@") if $@;
        }

        if (defined $fid) {
            eval {
                $c->send({
                    binary => encode_frame('rennari_ack',
                        { id => $fid }, $serializer),
                });
            };
            $self->_log(error => "rennari: ack send failed: $@") if $@;
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
        }
        delete $self->_connections->{$id};
        $self->_fire(disconnect => $c, $identity);
    });

    return undef;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Server - WebSocket event server for Mojolicious

=head1 SYNOPSIS

  my $rennari = Mojo::Rennari::Server->new(auth_cb => sub { ... });

  # default namespace
  $rennari->on('smile' => sub { ... });

  # named namespace
  $rennari->namespace('/chat')->on('message' => sub {
      my ($c, $payload) = @_;
      $c->rennari->broadcast_to_room('lobby', 'chat', $payload);
  });

  websocket '/ws' => sub { $rennari->websocket_route(shift) };

=head1 NAMESPACES

Multiple logical channels multiplexed over one WebSocket connection,
like Socket.IO. The default namespace is C</>. Register more with
C<< $server->namespace($name) >>.

The client declares its namespace with a first frame
C<< { e => 'rennari_nsp', d => { name => '/chat' } } >>. The server
replies C<< { e => 'rennari_nsp_ok', d => { name => '/chat' } } >>.
If the client never sends one, it is on C</>.

Rooms are per-namespace. A room named C<lobby> in C</chat> is not the
same as C<lobby> in C</>.

=head1 LICENSE

Same terms as Perl itself.

=cut

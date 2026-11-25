# Server API

[Documentation home](README.md)

## Construction

```perl
my $rennari = Mojo::Rennari::Server->new(
    auth_cb => sub {
        my $c = shift;
        # Validate credentials here.
        return {id => 'demo', name => 'Demo'};
    },
    logger => $app->log,
);
```

The identity above is illustrative, not production authentication.

## Attributes

| Attribute | Default | Purpose |
| --- | --- | --- |
| auth_cb | unset | Authentication callback receiving a controller |
| serializer | msgpack | msgpack or json |
| max_bytes | 65536 | Maximum decoded-input byte length accepted by decode_frame |
| logger | unset | Object with requested logging methods; otherwise warnings |
| mock | 0 | Bypass normal auth and supply a generated mock identity |
| force_mock | 0 | Override production mock refusal |
| inactivity_timeout | 300 | Controller inactivity timeout in seconds |
| recovery | 0 | Enable session retention and offline direct-send buffering |
| recovery_window | 120 | Offline retention seconds |
| recovery_max_frames | 256 | Maximum buffered frames per session |
| recovery_max_bytes | 1048576 | Maximum buffered encoded bytes per session |

The recovery limits apply to each offline session, not aggregate process memory. The server does not validate every constructor value; validate configuration before passing it in.

## on

```perl
$rennari->on(event_name => sub {
    my ($c, $payload) = @_;
    return {ok => 1};
});
```

Registers in the default namespace. Returns the default Namespace object, not the Server object. Avoid chaining server-only methods after on().

## namespace

```perl
my $nsp = $rennari->namespace('/chat');
```

Returns or creates a Namespace object. Omitted or undefined name means `/`. Invalid names throw.

## Lifecycle registration

```perl
$rennari->on_connect(sub { my ($c, $identity) = @_; });
$rennari->on_disconnect(sub { my ($c, $identity) = @_; });
$rennari->on_error(sub { my ($c, $kind, $detail) = @_; });
```

Each registration returns the server and replaces its previous callback. Exceptions in lifecycle callbacks are caught and logged.

Error kinds in the supplied server include bad_frame, unknown_namespace, unknown_event and handler_error. Detail is context dependent and may be undefined.

## websocket_route

```perl
websocket '/ws' => sub {
    my $c = shift;
    $rennari->websocket_route($c);
};
```

Authenticates and configures the WebSocket event handlers. Accepted-controller stash entries include:

| Stash key | Meaning |
| --- | --- |
| rennari | Connection helper; also exposed as `$c->rennari` |
| rennari_id | Process-local connection id |
| rennari_identity | Authenticated identity hash reference |
| rennari_namespace | Namespace currently being handled |
| rennari_session | Recovery session id, if enabled |

## Default-namespace shortcuts

```perl
my $count = $rennari->broadcast(event => $payload);
my $room_count = $rennari->broadcast_to_room($room, event => $payload);
my $ids = $rennari->members_of($room);
my $rooms = $rennari->rooms_of($connection_id);
```

Broadcast counts indicate successful send attempts, not client receipt. rooms_of returns the union of names across the connection's namespaces. Other shortcuts here address `/`.

Methods beginning with `_` and internal hashes are implementation details, not recommended application interfaces.

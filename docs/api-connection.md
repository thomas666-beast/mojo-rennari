# Connection and namespace APIs

[Documentation home](README.md)

## Connection helper

Retrieve it inside a server callback:

```perl
my $connection = $c->rennari;
```

Attributes are server, id and namespace. The server sets namespace for the incoming frame; it is not a permanent user-selected routing context.

| Method | Result / behavior |
| --- | --- |
| join($room) | Join current namespace room; returns helper |
| leave($room) | Leave current namespace room; returns helper |
| rooms() | Array reference of current namespace's room names |
| members_of($room) | Array reference of room connection ids |
| send_to_self($event, $payload) | Direct send to this connection; success indicator |
| send_to($id, $event, $payload) | Direct send to another connection id; success indicator |
| broadcast($event, $payload) | Send to current namespace members; returns count |
| broadcast_to_room($room, $event, $payload) | Send to current namespace room; returns count |

Direct helper send_to routes through the server's connection records and does not itself enforce that the target has joined the sender's current namespace. Namespace->send_to does check namespace membership. Always validate the intended recipient and its authorization in application code.

Connection ids are process-local transient identifiers, not user ids. When retaining a helper for delayed work, its namespace may later change. Capture the intended namespace and id and use explicit routing rather than relying on mutable current-frame context.

## Server namespace

```perl
my $nsp = $rennari->namespace('/chat');
```

| Method | Result / behavior |
| --- | --- |
| on($event, $callback) | Register/replace handler; returns namespace |
| handler_for($event) | Callback or undef |
| send_to($id, $event, $payload) | Send only if target is a member; returns success indicator |
| broadcast($event, $payload) | Count successful send attempts |
| broadcast_to_room($room, $event, $payload) | Count successful send attempts |
| members_of($room) | Sorted connection id array reference |
| rooms_of($id) | Sorted room name array reference |
| join($id, $room) | Join if id is attached; namespace or undef |
| leave($id, $room) | Remove membership; returns namespace |

attach($id) and detach($id) manage connection membership; normally let the server call them. Detach also clears room memberships and removes empty rooms.

## Client namespace

```perl
my $chat = $client->of('/chat');
$chat->on(message => sub { my ($client, $payload) = @_; });
$chat->send(message => {text => 'Hello'});
$chat->off('message');
```

Named namespaces should be created before connecting. There is no public leave-namespace convenience method in the supplied client. Rooms are server-side application state, not client Namespace objects.

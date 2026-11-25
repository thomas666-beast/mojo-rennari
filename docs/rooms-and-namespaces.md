# Rooms and namespaces

[Documentation home](README.md)

## Namespaces separate event domains

The default namespace is `/`. Named namespaces have separate event handlers, member sets and rooms, all over one WebSocket connection.

Server registration:

```perl
my $chat = $rennari->namespace('/chat');
$chat->on(message => sub {
    my ($c, $payload) = @_;
    return {received => $payload};
});
```

Client registration, before connect:

```perl
my $chat = $client->of('/chat');
$chat->on(reply => sub {
    my ($client, $payload) = @_;
    # Process the /chat result.
});

$client->on(connect => sub {
    my ($client) = @_;
    $client->of('/chat')->send(message => {text => 'Hello'});
});
```

The Perl client requests joins for named namespaces already created with of() when the WebSocket connects. It queues those requests before firing the local connect event. It does not expose a namespace-ready callback: rennari_nsp_ok is consumed internally.

Creating a new namespace with of() after connect does not automatically send a join request in this implementation. Prefer registering all namespaces before connecting. The core supports an explicit rennari_nsp control frame, but the high-level client has no dedicated join method.

A frame for an unknown or unjoined namespace closes with 4005. Namespace registration is not access control; see [Authentication](authentication.md).

## Rooms group connections inside a namespace

Handler snippet:

```perl
$rennari->on(join_room => sub {
    my ($c, $payload) = @_;
    return {error => 'object required'} unless ref $payload eq 'HASH';
    my $room = $payload->{room};
    return {error => 'invalid room'}
        unless defined $room && !ref $room && $room =~ /\A[A-Za-z0-9_-]{1,64}\z/;

    # Check this authenticated user's access to $room here.
    $c->rennari->join($room);
    return {joined => $room};
});
```

The room validation above is example application policy. The core join method only requires a defined room with non-zero string length. Validate payload types and choose your own room-name policy.

## Send and inspect

```perl
$c->rennari->broadcast_to_room('lobby', message => {text => 'Hello'});
$c->rennari->leave('lobby');
my $rooms = $c->rennari->rooms;
my $ids   = $c->rennari->members_of('lobby');
```

A broadcast includes the sender if the sender is a member of its target namespace or room. There is no built-in exclude-sender option.

Namespace-level broadcasts return a count of successful send attempts, not receipt confirmations. Member and room listings are array references; connection ids are not authenticated user ids.

## Default server shortcuts

`$rennari->broadcast`, broadcast_to_room and members_of operate on `/`. Use `$rennari->namespace('/chat')` for another namespace.

`$rennari->rooms_of($id)` is different: it returns a sorted union of room names across that connection's joined namespaces, without preserving which namespace each room belongs to.

Disconnected connections are detached from namespace member and room sets. Recovery may restore those memberships later, but namespace and room broadcasts do not reach detached offline records. See [Recovery](recovery.md).

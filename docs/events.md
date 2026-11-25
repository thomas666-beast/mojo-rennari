# Sending and handling events

[Documentation home](README.md)

## Mental model

A client sends an event name and a payload. The server finds the callback registered for that event in that namespace. A callback may return data as a reply, explicitly send another named event, or do both.

Register a server handler:

```perl
$rennari->on(greet => sub {
    my ($c, $payload) = @_;
    return {error => 'payload must be an object'} unless ref $payload eq 'HASH';
    my $name = $payload->{name};
    return {error => 'name must contain 1 to 80 characters'}
        unless defined $name && !ref $name && length($name) && length($name) <= 80;
    return {message => "Hello, $name"};
});
```

Send from a connected client:

```perl
$client->send(greet => {name => 'Alice'});
```

Receive the result:

```perl
$client->on(reply => sub {
    my ($client, $payload) = @_;
    return unless ref $payload eq 'HASH';
    say $payload->{message} // $payload->{error} // 'Unexpected reply';
});
```

Register client handlers before connecting. Add new server registrations inside register_events in the generated application.

## Returning versus explicitly sending

Any defined server callback result becomes a `reply` event in the incoming namespace. This includes 0 and the empty string. Return undef when you do not want an automatic reply:

```perl
$rennari->on(ping => sub {
    my ($c, $payload) = @_;
    $c->rennari->send_to_self(pong => {got => $payload});
    return undef;
});
```

An explicit `return undef` matters: Perl otherwise returns the last expression, which may be the send method's success value and produce an unintended additional reply.

## There is no automatic request/result correlation

All automatic responses use the event name reply. The optional wire id is for acknowledgement, not a request identifier copied into the application result. For concurrent requests, put an application request key in the payload and copy it into the result, or use distinct response event names.

Do not put secrets into correlation keys. Validate incoming keys just like other fields.

## Handler errors

An unknown event closes a normal server connection with 4003. In mock mode it is logged and ignored. An exception in an application handler closes with 4004. A failed automatic reply also closes with 4004.

A returned `{error => ...}` is ordinary application data, not a thrown exception or a special protocol error. If an acknowledgement was requested, returning an error object can still result in an acknowledgement because the handler completed successfully.

## Synchronous callbacks

The server uses the immediate callback return value. It does not await a promise or treat an asynchronous callback's future completion as handler completion.

For asynchronous work, return undef and send an explicit event when it completes. Be aware that the connection helper's namespace can change when later frames arrive; capture the needed namespace and connection id before scheduling delayed work. Acknowledgement timing still reflects the immediate handler return, not the background operation.

## Registration rules

Only one callback is stored per event name in a namespace. Registering the same name replaces the previous callback. This also applies to the client's local lifecycle handlers. If you need several actions, call them from one handler rather than registering several handlers under the same name.

Reserve the rennari_ prefix for protocol control and avoid using the client's local lifecycle names for application events. See [Wire protocol](protocol.md).

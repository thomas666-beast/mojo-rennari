# Perl client API

[Documentation home](README.md)

## Construction

```perl
my $client = Mojo::Rennari::Client->new(
    url => $config->{url},
    serializer => $config->{serializer},
    headers => {'X-Rennari-App-Token' => $config->{TOKEN_APP}},
);
```

| Attribute | Default | Purpose |
| --- | --- | --- |
| url | unset | Required WebSocket URL |
| headers | empty hash reference | Handshake request headers |
| serializer | msgpack | Must match server |
| max_bytes | 65536 | Inbound frame byte limit |
| ack_timeout | 5 | Seconds per acknowledgement attempt |
| retries | 3 | Retries after initial acknowledged send |
| mock | 0 | Enable client mock policy check |
| force_mock | 0 | Override production mock refusal |
| logger | unset | Logger or fallback warnings |
| ua | unset | Custom Mojo::UserAgent; otherwise created on connect |
| session_id | unset | Last recognized recovery session id |
| last_offset | -1 | Highest processed inbound offset, subject to recovery control handling |

Client mock does not fake a server or suppress the network connection. Its implementation only checks whether mock use is allowed in the current environment.

## on and of

```perl
$client->on(event => sub { my ($client, $payload) = @_; });
my $nsp = $client->of('/chat');
$nsp->on(event => sub { my ($client, $payload) = @_; });
```

of returns a client Namespace helper. Top-level on delegates to `/` and returns that helper, not the top-level client. Registering an existing event replaces the handler.

The namespace helper supports on, off, send and emit_with_ack. Use `$client->of('/')->off('event')` to remove a default-namespace handler; the top-level client has no off method.

## connect

```perl
$client->connect(sub {
    my ($tx, $error) = @_;
    if (defined $error) {
        warn "$error
";
        return;
    }
    # The WebSocket is connected.
});
```

Returns the client. It throws if url is missing, callback type is invalid, headers is not a hash reference, serializer is unsupported, or a connection is already active/connecting.

On handshake success, it requests predeclared named namespaces, fires local connect, then calls the supplied callback. On handshake failure, it fires local error and calls the callback with an error. If you use both paths, make cleanup idempotent.

## send

```perl
$client->send(event => $payload);
$client->of('/chat')->send(event => $payload);
```

Requires an active connection and throws otherwise. A successful return means send was queued, not that the server received or processed the event. Use emit_with_ack where needed.

## emit_with_ack

```perl
$client->emit_with_ack(event => $payload, sub {
    my ($ack, $error) = @_;
});
```

Returns the client at top level. Success supplies an acknowledgement hash containing id; failure supplies undef and an error. See [Acknowledgements](acknowledgements.md).

## Local lifecycle events

| Name | Callback arguments after the client |
| --- | --- |
| connect | None |
| disconnect | Hash reference with code and reason |
| error | Error string |
| ack_timeout | Hash reference with event and payload |
| recovered | Hash reference with offset |

These use the default namespace. Do not reuse their names for default-namespace application messages.

Invalid server frames fire error but the core client's decode path does not itself close the connection. The generated client chooses to stop on error.

## disconnect and is_connected

```perl
$client->disconnect;
my $active = $client->is_connected;
```

disconnect finishes an active transaction and fails outstanding acknowledgement callbacks. It returns the client. is_connected reports whether a WebSocket transaction is currently present.

There is no automatic reconnect, heartbeat, complete high-level resume API or request/response promise API in this client.

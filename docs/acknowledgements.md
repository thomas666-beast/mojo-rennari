# Acknowledgements and retries

[Documentation home](README.md)

## Request an acknowledgement

Use this inside the connected-client path:

```perl
$client->emit_with_ack(save_note => {
    operation_id => 'application-generated-unique-key',
    text => 'Draft',
}, sub {
    my ($ack, $error) = @_;
    if (defined $error) {
        warn "Not acknowledged: $error
";
        return;
    }
    say "Acknowledged id=$ack->{id}";
});
```

The server must have a save_note handler. The same API is available through `$client->of('/notes')->emit_with_ack(...)` for a prejoined namespace.

## What an acknowledgement means

For a regular event with an id, the server sends rennari_ack after the callback returns without throwing and after attempting any automatic reply successfully.

It does not mean:

- The application's result was a business success.
- A database transaction was committed unless the handler actually did that synchronously.
- Background asynchronous work has finished.
- The event was delivered exactly once.

An application error returned as a normal payload can still be acknowledged. Read the application response separately.

## Timing and number of attempts

Client defaults:

| Option | Default |
| --- | --- |
| ack_timeout | 5 seconds per attempt |
| retries | 3 retries after the first send |

With those defaults, an event can be sent four times while connected. The timeout does not implement reconnect. A disconnect fails pending callbacks instead of carrying their retry timers across reconnection.

After the final acknowledgement timeout, the client emits the local ack_timeout event and calls the acknowledgement callback with an error. An initial send failure also calls the callback with an error.

## Duplicate-safe application design

Every retry reuses the same protocol id, but the server does not deduplicate ids. A request may have completed while its acknowledgement was lost.

For operations with side effects, include an application operation_id and implement durable duplicate detection keyed by the authenticated identity and that operation id. The duplicate check and side effect should form one consistent transaction in your application's storage. Do not rely on an in-memory flag for cross-process guarantees.

A missing acknowledgement means the outcome is uncertain, not that the handler never ran. Reconcile with application state rather than blindly treating the operation as failed.

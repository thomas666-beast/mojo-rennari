# Mojo::Rennari

Real-time event transport for Mojolicious, named after the Old Norse
*rennari* — "runner, messenger, envoy."

## What it is

A small, secure, MessagePack-framed WebSocket messaging layer for
Mojolicious applications. It deliberately does not implement the
Socket.IO protocol; it offers a cleaner, smaller API that does the
same job for applications that don't need Socket.IO's full feature set.

## Design decisions

- **Authentication before upgrade.** The auth callback runs during the
  HTTP request; a failed check returns 401 and no WebSocket is opened.
- **MessagePack framing.** Events are encoded as
  `{ e => 'name', d => payload }`. Compact on the wire, trivial to
  encode/decode from Perl and from JavaScript (`@msgpack/msgpack`).
- **Custom event handlers.** `$server->on('smile' => sub { ... })`.
- **`mock` mode**, optional on both server and client, for development.
  Refused automatically in `production` unless explicitly overridden.
- **Transport-agnostic client protocol.** A Perl client handler and a
  browser JavaScript client share the same frame format.

## Status

Work in progress. Built task by task; see the commit history.

## License

Same terms as Perl itself.

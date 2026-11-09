Rennari Protocol
================

Version 0.1
Status: stable, implemented in seven languages

This document is the normative specification. Implementations:

- Perl server        mojo-rennari
- JavaScript client  rennari-client-js
- JavaScript server  rennari-server-js
- Go client+server   rennari-go
- Python client+server rennari-py
- Rust client+server rennari-rs
- Java client+server rennari-java

If an implementation disagrees with this document, the implementation
is wrong.


1. TRANSPORT
------------

WebSocket, binary frames only. Text frames are not used and may be
ignored or rejected.

No subprotocol is negotiated. The endpoint path is chosen by the
application (commonly /ws). The protocol does not prescribe the URL.


2. AUTHENTICATION
-----------------

Authentication happens at the application layer, before the upgrade or
as the first message, depending on the implementation:

- Server implementations that accept an auth callback run it before the
  WebSocket upgrade and reject unauthenticated connections with HTTP 401.
- The protocol does not carry credentials in any frame. The application
  decides how a client proves its identity.

Once a connection is open and authenticated, the protocol does not
re-authenticate per message.


3. FRAME FORMAT
---------------

A frame is a serialized map. The wire format depends on the serializer
in use (see section 10):

    {
      "e":  <string>,     event name, required
      "d":  <any>,        payload, required
      "id": <integer>,    acknowledgement id, optional
      "o":  <integer>,    offset, optional
      "n":  <string>,     namespace, optional
    }

Constraints:

- "e" must match ^[A-Za-z0-9_.:-]{1,64}$
- "d" may be any value the serializer can represent
- "id" must be a non-negative decimal integer, at most 20 digits
- "o" must be a non-negative decimal integer
- "n" must match ^/[A-Za-z0-9_.:/-]{0,63}$ when present
- "n" is omitted when the namespace is "/"
- A frame that fails any constraint must be rejected by the receiver


4. BUILT-IN EVENTS
------------------

The protocol reserves event names that begin with "rennari_". They are
handled by the framework, not by application code.

Client to server:

    rennari_nsp     { "name": "/path" }
                    Switch to a namespace. The server replies with
                    rennari_nsp_ok or closes with 4005.

    rennari_resume  { "session_id": "<32 hex>", "offset": <int> }
                    Attempt to resume a previous session. The server
                    replies with rennari_resumed or rennari_resume_failed.

Server to client:

    rennari_session       { "id": "<32 hex>" }
                          Issued at handshake when recovery is enabled.

    rennari_nsp_ok        { "name": "/path" }
                          Confirms a namespace switch.

    rennari_resumed       { "offset": <int>, "session_id": "<32 hex>" }
                          Confirms a successful resume.

    rennari_resume_failed { "reason": "<string>" }
                          Resume failed. Current reasons: "unknown_session".

    rennari_ack           { "id": <int> }
                          Acknowledges a client event that carried "id".

    reply                 <any>
                          Sent when a handler returns a value.

Application events may use any name that does not begin with
"rennari_". The framework does not reserve any other prefix.


5. SERVER BEHAVIOR
------------------

On connection:

- The server assigns a connection id, internal to the server.
- If recovery is enabled, the server issues a session id and sends
  rennari_session as the first frame.
- The default namespace "/" is joined automatically.

On receiving a frame:

- Decode. If decoding fails, close with 4002.
- If the event is rennari_resume, handle resume and return.
- If the event is rennari_nsp, handle namespace switch and return.
- Look up the namespace named by "n" (or "/" if absent).
- If the connection has not joined that namespace, close with 4005.
- Look up the handler for the event in that namespace.
- If no handler and not in mock mode, close with 4003.
- Invoke the handler with (context, payload).
- If the handler returns a value, send { "e": "reply", "d": value }
  in the same namespace.
- If the frame carried "id", send { "e": "rennari_ack", "d": { "id": id } }
  in the default namespace.
- If the handler throws or panics, close with 4004.

On close:

- Remove the connection from all namespaces and rooms.
- If recovery is enabled, keep the session for recovery_window seconds
  with its namespaces, rooms, and buffered frames.


6. CLIENT BEHAVIOR
------------------

On connect:

- Open the WebSocket.
- Attach a message listener before any send.
- If recovery is enabled and a previous session id is known and not
  expired, send rennari_resume first.
- Declare all non-default namespaces the client has registered.

On receiving a frame:

- Decode. If decoding fails, drop the frame.
- If the frame has "o" and it is greater than the last seen offset,
  update the last seen offset.
- If the event is one of the built-in server events, handle it and
  return.
- Otherwise, dispatch to the handler registered for (namespace, event).

On emit:

- Send { "e": event, "d": payload, "n": namespace? }.
- If an ack is expected, include "id".


7. ROOMS
--------

Rooms are named groups of connections within a namespace.

- A room auto-creates on first join.
- A room disappears when its last member leaves.
- A connection may be in many rooms.
- The same room name in two namespaces is two different rooms.

The protocol does not define a join or leave message. Joining and
leaving are application concerns, invoked by handlers via the
implementation's context API. This is deliberate: the framework does
not impose policy on which connections may join which rooms.


8. ACKNOWLEDGEMENTS
-------------------

A client may attach "id" to any application event. The server
acknowledges after the handler returns successfully.

- On success: server sends rennari_ack with the same id.
- On handler failure: server closes with 4004. No ack is sent.

A client that expects an ack may resend the same frame with the same
"id" if no ack arrives within its timeout. This is at-least-once
delivery: the server may receive the same event more than once.
Applications that use retries must make their handlers idempotent.


9. RECOVERY
-----------

Optional. Enabled per server, per client.

When enabled:

- The server issues a session id at handshake (rennari_session).
- Every outbound frame carries "o", an increasing offset per connection.
- When a connection drops unexpectedly, the session is kept for
  recovery_window seconds (commonly 120).
- Outbound frames addressed to a disconnected session are buffered.
- On reconnect, the client sends rennari_resume with the session id and
  the highest "o" it has processed.
- The server replays buffered frames with "o" greater than the client's
  offset, re-attaches namespaces and rooms, and sends rennari_resumed.
- If the session is unknown, expired, or still attached to a live
  connection, the server sends rennari_resume_failed.

The offset is per session, not global. It resets when a session is
replaced by a fresh connection (i.e. after expiry or resume failure).

When recovery is disabled, no rennari_session is sent, no "o" field
appears on any frame, and any rennari_resume closes the connection
with 4006.


10. SERIALIZERS
---------------

Two serializers are defined:

- msgpack (default): MessagePack map, short keys as shown in section 3.
- json: JSON object, same keys.

The serializer is chosen per server and per client at construction
time. It is not negotiated. A client and server using different
serializers cannot communicate.

Both sides reject frames larger than a configured max_bytes (default
64 KiB) before decoding.


11. CLOSE CODES
---------------

The protocol uses the WebSocket application-private range, 4000-4999.
The following codes are defined:

- 4002  bad frame (decoder rejected the bytes)
- 4003  unknown event (no handler registered, not in mock mode)
- 4004  handler error (handler threw or panicked)
- 4005  unknown namespace, or frame for a namespace the connection
        has not joined
- 4006  recovery disabled but client sent rennari_resume

Other codes may be used by the WebSocket transport (1000-1015) or by
applications (4000-4999 not listed above).


12. MOCK MODE
-------------

Development-only mode, implemented consistently across servers:

- Skips authentication.
- Synthesizes an identity.
- Ignores unknown events instead of closing with 4003.
- May be refused when the environment signals production.

Mock mode is not part of the wire protocol. It changes server behavior
only, and never changes the frame format.


13. COMPATIBILITY
-----------------

Two implementations are compatible if:

- They accept and produce frames that satisfy section 3.
- They agree on the built-in events of section 4.
- They agree on the close codes of section 11.
- They use the same serializer.

The seven implementations listed at the top of this document are
compatible. Any future implementation that satisfies this document is
compatible with them.


14. CHANGE LOG
--------------

0.1  Initial specification.

- Frame format with e, d, id, o, n.
- Built-in events for namespace and recovery.
- Close codes 4002-4006.
- Two serializers: msgpack and json.

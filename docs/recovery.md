# Connection recovery

[Documentation home](README.md)

Recovery is optional, process-local state restoration. It is not a durable message queue, automatic client reconnection, or a guarantee that every missed message will be replayed.

## Enable it in application code

Add these validated options to the server constructor in build_server:

```perl
recovery            => 1,
recovery_window     => 120,
recovery_max_frames => 256,
recovery_max_bytes  => 1024 * 1024,
```

These are the default limits once recovery is enabled. Merely adding these keys to the starter's YAML will not wire them into the constructor.

Outside mock mode, auth_cb must return an identity with a stable non-empty scalar id. A resuming connection must authenticate as that same owner.

## Server session lifecycle

1. The server issues a private 32-character hexadecimal session id in rennari_session.
2. Outbound frames are assigned increasing offsets when recovery is enabled.
3. On disconnect, the server records namespace and room memberships, detaches the connection and retains an offline session.
4. Direct sends to the retained connection id can be buffered until the session resumes, expires or exceeds a limit.
5. A valid resume reattaches the session to the new connection, restores memberships and replays buffered entries whose offsets exceed the supplied offset.

The default expiry window is 120 seconds after disconnect. A successful resume cancels that expiry generation. Session state disappears on process exit or restart.

## Important delivery limits

Only frames sent while the connection is offline are buffered by the supplied server. Frames sent while it appeared online are not retained for replay, even if the client never received them.

Offline records are detached from namespace and room member sets. Namespace and room broadcasts therefore do not find them and do not populate their offline buffers. Do not describe recovery as reliable replay of all missed room broadcasts.

Exceeding either per-session limit invalidates the offline session. Sending to a new connection id is not the same as sending to a stable user identity; keep your own user-to-live-connection mapping where needed.

Replay send exceptions are logged, and the implementation clears the buffer after the replay loop. There is no replay receipt confirmation. Client offsets are not strictly checked against a replayable range. Treat this feature as best-effort state recovery, not an audit log or guaranteed delivery system.

## Perl client limitations

The client exposes session_id and last_offset and recognizes server recovery messages. It does not automatically reconnect or issue a resume request. Its connect method resets those attributes on each new connection, so any custom reconnection controller must retain the previous values separately.

The wire-level request is:

```text
{ e: "rennari_resume", d: { session_id: "previous-session-id", offset: previous_offset } }
```

A new socket first receives a newly announced throwaway session; on successful resume the server transfers the previous session and sends rennari_resumed. Implement and test this transition explicitly if you build a reconnection controller. The high-level client does not provide a complete ready-made controller or a resume-failed application event.

## Scaling

A session exists only in one server process. Sending a reconnect to a different worker cannot restore that process's in-memory state. Routing affinity may help reach the original worker, but does not provide persistence, shared broadcasts or failure recovery after that worker dies.

For dependable business delivery, use application persistence and an application-level resynchronization mechanism in addition to, or instead of, this feature.

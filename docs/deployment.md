# Deployment and security

[Documentation home](README.md)

## Before exposing an endpoint

- Replace the generated demo identity with real user authentication.
- Implement event, namespace-sensitive data and room authorization in the application.
- Use TLS and wss:// for credentials crossing a non-local network.
- Keep TOKEN_APP and user credentials out of source control, logs and URLs.
- Do not distribute a shared application secret to untrusted browser code.
- Validate payload types, lengths, identifiers and allowed operations.
- Apply connection, handshake and event rate limits at the appropriate application/proxy layers.
- Set transport/proxy frame and message limits as well as Rennari's decode limit.
- Test error paths, duplicate operations and disconnect cleanup.

These are deployment responsibilities; the supplied library does not implement all of them for you.

## Idle connections

The server sets an inactivity timeout of 300 seconds by default. The generated client has no automatic application heartbeat. If your application requires long-lived idle connections, implement and test a suitable heartbeat/timeout policy and align reverse-proxy idle timeouts with it.

## Reverse proxies

Configure your proxy to support WebSocket upgrades, forward the handshake headers your authentication uses, and enforce TLS externally or end to end as appropriate. Proxy products differ; this documentation does not provide a drop-in vendor configuration.

If browsers are introduced, design and validate their authentication and Origin policy explicitly. The supplied core server does not include a dedicated Origin allowlist callback.

## Multiple processes

Connections, namespaces, rooms, handler registrations and recovery sessions are held in each server process. A namespace broadcast reaches only the connections known to that process. The library has no shared adapter, distributed room registry or durable session backend in the supplied source.

A multi-worker deployment needs an application-level design for cross-worker broadcasts and delivery. Sticky routing alone does not make broadcast state shared or preserve sessions after process death.

## Memory and backpressure

Recovery caps are per session. There is no global retained-session byte cap in the supplied code. Normal outbound sends are queued on the transaction and are not equivalent to receiver confirmation. Review slow-consumer handling, transport buffers, connection counts and aggregate memory as part of load testing.

## Mock policy

The server refuses mock mode in production unless force_mock is set. Server production detection checks application mode and MOJO_MODE; the client checks MOJO_MODE. Never use force_mock to work around production authentication configuration.

## Operational signals

Log connection lifecycle and error kinds, but do not log authentication headers, TOKEN_APP, recovery session ids or raw sensitive payloads. Track handshake failures, close codes, acknowledgement timeouts and recovery failures in your own monitoring. No metrics backend is included.

On shutdown, expect in-memory connections and recovery state to be lost. Persist important business state separately.

# Scope, compatibility and documentation status

[Documentation home](README.md)

## Sources used

This documentation was prepared from the supplied Mojo::Rennari 0.003 modules: Rennari.pm, Client.pm, Connection.pm, Namespace.pm and Generator.pm; the Protocol.pm and Server.pm source and Makefile.PL pasted in the development conversation; and the revised YAML-based generator produced in that conversation.

The original uploaded generator still uses environment variables. These guides intentionally describe the revised generator's TOKEN_APP/YAML contract. Copy the revised generator into your distribution before publishing or following these starter instructions.

## Implemented capabilities

- Named events over binary WebSocket messages.
- MessagePack and JSON serialization, selected on both peers.
- Authentication callback before upgrade.
- Namespace-specific handlers, member sets and rooms.
- Direct sends, namespace broadcasts and room broadcasts.
- Perl client acknowledgements and retry timers.
- Optional in-memory server recovery with offline direct-send buffering.
- Lite and modular project generation.

## Not provided as complete features

- Socket.IO/Engine.IO compatibility.
- A supplied supported browser client implementation.
- Built-in user account storage or a production identity provider.
- Automatic per-room or per-event authorization.
- Automatic Perl client reconnect and complete resume orchestration.
- Exactly-once delivery or server-side duplicate suppression.
- Durable replay of all missed outbound frames.
- Cross-worker rooms, broadcasts or recovery storage.
- A built-in heartbeat, global rate limiter or metrics backend.
- Promise-aware server handler completion.

## Important implementation caveats

Client and server handlers replace earlier registrations with the same event name. The current Connection helper has mutable namespace context. Offline members are detached, so room/namespace broadcasts do not populate recovery buffers. Session recovery should therefore not be described as reliable replay of every missed event.

The generated application-level TOKEN_APP is a shared secret check, not a mandatory protocol field or proof of software origin. User authentication remains application work.

## Verification

The Markdown files and relative document links were checked during creation. Perl examples and generated application behavior still require execution in the project's supported dependency environment. Before a release, run your distribution tests, exercise both generator styles, verify authentication failures, and review examples against the exact code being shipped.

## License

The supplied distribution states the same terms as Perl itself. Preserve the distribution's license notices when packaging documentation and examples.

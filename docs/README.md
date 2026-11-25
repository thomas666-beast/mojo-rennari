# Mojo::Rennari documentation

A practical guide to building event-driven WebSocket applications with Perl and Mojolicious.

Rennari gives you named events, payloads, namespaces, rooms, acknowledgements and optional process-local connection recovery. It is not Socket.IO compatible.

## Start here

1. [Install Rennari](installation.md).
2. [Generate and run your first application](quickstart.md).
3. [Understand the generated files](project-structure.md).
4. [Add your own events](events.md).
5. [Replace demonstration authentication](authentication.md).

## Guides

- [Configuration](configuration.md): YAML, TOKEN_APP and library options.
- [Rooms and namespaces](rooms-and-namespaces.md): organize and target events.
- [Acknowledgements and retries](acknowledgements.md): delivery signals and duplicate handling.
- [Recovery](recovery.md): offline sessions and current limitations.
- [Testing](testing.md): protocol and application tests.
- [Deployment and security](deployment.md): production checklist.
- [Troubleshooting](troubleshooting.md): symptoms and checks.

## Reference

- [Server API](api-server.md)
- [Client API](api-client.md)
- [Connection and namespace APIs](api-connection.md)
- [Wire protocol](protocol.md)
- [Generator CLI](generator.md)
- [Examples](examples.md)
- [Scope and compatibility](scope.md)

## Documentation baseline

These documents describe library version 0.003 from the supplied source and the revised YAML-based generator developed alongside it. Install that revised generator before following the quick start: the older generator uses environment variables and a different starter.

Code blocks marked as handler snippets belong inside your existing application's registration code; they are not standalone programs. Example application data stays in Perl code. YAML is reserved for connection, protocol and credential settings.

The documentation has been checked for internal Markdown links, but the Perl examples have not been executed against an installed Mojolicious environment. See [Scope and compatibility](scope.md) for implementation caveats.

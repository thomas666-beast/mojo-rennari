# Configuration

[Documentation home](README.md)

## Starter configuration versus library options

The YAML format is a convention implemented by the revised generated application. Mojo::Rennari::Server and Mojo::Rennari::Client do not load YAML themselves.

Adding an arbitrary key to YAML does not automatically configure a library attribute. To expose an additional option, validate it in the starter and explicitly pass it to the constructor.

## Server YAML

```yaml
TOKEN_APP: CHANGE_ME
serializer: msgpack
```

## Client YAML

```yaml
url: ws://127.0.0.1:3000/ws
TOKEN_APP: CHANGE_ME
serializer: msgpack
```

| Key | Meaning |
| --- | --- |
| TOKEN_APP | Shared application access credential; same value on both sides |
| serializer | msgpack or json; defaults to msgpack in the starter |
| url | Client WebSocket endpoint, starting with ws:// or wss:// |

The token placeholder must be replaced with 32–256 characters matching `[A-Za-z0-9._~-]`. The loader requires a YAML mapping and uses YAML::PP with the JSON schema. Do not add YAML object tags or executable configuration.

Both serializers are carried in binary WebSocket messages by this implementation. Selecting json does not switch transport messages to WebSocket text frames.

## What does not belong here

Do not add example room names, sample messages, demo durations or a scripted sequence of events to the connection configuration. Keep these in editable example code. Add real application configuration later only when the application's requirements justify it.

## Server listen address

The generated server uses the Mojolicious launch command:

```sh
perl server.pl daemon -l http://127.0.0.1:3000
```

The revised starter does not read a listen address from YAML. If you change the listen address or port, change the client URL accordingly.

## Private files

The generator creates YAML files with mode 0600, subject to platform support and the process umask. Its .gitignore excludes server.yml and client.yml, including those in subdirectories. These protections do not remove a secret already committed to version control. Rotate a credential that has been disclosed.

The files are loaded at startup. Editing them does not implement live reload, active-connection revocation or credential rotation by itself.

See [Server API](api-server.md) and [Client API](api-client.md) for constructor options.

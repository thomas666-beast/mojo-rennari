# Quick start

[Documentation home](README.md)

This guide assumes the revised YAML-based generator is installed.

## 1. Generate a Lite application

```sh
mojo-rennari generate lite demo
cd demo
```

The generator creates server.pl, client.pl, server.yml, client.yml, cpanfile, .gitignore and README.md.

## 2. Configure application access

Edit server.yml:

```yaml
TOKEN_APP: CHANGE_ME
serializer: msgpack
```

Edit client.yml:

```yaml
url: ws://127.0.0.1:3000/ws
TOKEN_APP: CHANGE_ME
serializer: msgpack
```

Replace CHANGE_ME in both files with the same private, randomly generated token. The revised starter accepts 32–256 ASCII letters, numbers, periods, underscores, tildes or hyphens. Do not use the literal placeholder.

No token exports are needed. Do not put credentials into the URL.

## 3. Start the server

```sh
perl server.pl daemon -l http://127.0.0.1:3000
```

## 4. Start the client

In a second terminal, enter the same project directory:

```sh
perl client.pl
```

The example client connects, sends ping and whoami, and prints the pong and reply events. Other log lines may appear. It stays connected until disconnected or interrupted with Ctrl+C; there is no demonstration shutdown timer.

The server's default inactivity timeout is 300 seconds. An otherwise idle connection can therefore close even though the starter has no shutdown timer.

## 5. Replace the examples

Open server.pl and client.pl. Change their event callbacks and send calls to implement your application. Rooms, messages and business operations belong in that code, not in connection YAML.

The generated auth_cb still returns a demo identity. Replace that part before using real user accounts; TOKEN_APP alone does not authenticate individual users.

## Generate a modular application instead

```sh
mojo-rennari generate app MyApp
cd my_app
```

Edit server/server.yml and client/client.yml, then run in separate terminals:

```sh
perl server/script/server daemon -l http://127.0.0.1:3000
perl client/script/client
```

The same protocol and callbacks are used. Only the file organization changes.

Next: [Project structure](project-structure.md) and [Events](events.md).

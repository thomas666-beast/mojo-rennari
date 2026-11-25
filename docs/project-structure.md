# Project structure

[Documentation home](README.md)

## Lite

```text
demo/
  server.pl
  client.pl
  server.yml
  client.yml
  cpanfile
  .gitignore
  README.md
```

Use Lite when a pair of readable scripts is the clearest starting point. Each script contains configuration loading, event registration and startup logic. The server also contains authentication and the WebSocket route.

The revised Lite scripts resolve YAML relative to the scripts, not to the current working directory.

## Modular application

For the package MyApp:

```text
my_app/
  README.md
  cpanfile
  .gitignore
  server/
    server.yml
    script/server
    lib/MyApp/Server.pm
    lib/MyApp/Server/Events.pm
  client/
    client.yml
    script/client
    lib/MyApp/Client.pm
    lib/MyApp/Client/Events.pm
```

| File | Responsibility |
| --- | --- |
| Server.pm | Load server YAML, build Rennari, configure auth_cb, mount /ws |
| Server/Events.pm | Register server hooks and application handlers |
| Client.pm | Load client YAML, construct client, handle lifecycle |
| Client/Events.pm | Register incoming events and example sends on connect |
| script/server | Launch the Mojolicious application |
| script/client | Launch the Perl client |

The server resolves server.yml through the Mojolicious application home. The client runner passes a configuration path relative to its own location.

## Grow by responsibility

Start with Events.pm. When it becomes difficult to navigate, split related handlers into modules such as Server/Events/Chat.pm or Server/Events/Notifications.pm. Register them explicitly from Events.pm:

```perl
use MyApp::Server::Events::Chat ();

sub register_events {
    my ($rennari) = @_;
    MyApp::Server::Events::Chat::register_events($rennari);
}
```

This is an optional organization pattern, not an additional Rennari API or a requirement to build an event framework.

Keep domain rules in your application services when needed. Event handlers can validate the payload, check permission, call a service, and send or return the result.

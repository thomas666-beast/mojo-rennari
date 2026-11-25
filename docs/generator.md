# Generator command reference

[Documentation home](README.md)

## Commands

```sh
mojo-rennari generate lite [NAME]
mojo-rennari generate app [PACKAGE]
mojo-rennari --version
mojo-rennari help
```

help also accepts --help or -h; version accepts version or --version.

## Lite

```sh
mojo-rennari generate lite demo
```

Default name: rennari_lite. The name must begin with an ASCII letter and contain only letters, numbers, underscores or hyphens, with a maximum length of 80. The lite_app spelling is accepted as an alias.

## App

```sh
mojo-rennari generate app MyApp
mojo-rennari generate app Acme::Chat
```

Default package: RennariApp. Each `::`-separated component begins with an uppercase ASCII letter and contains only letters and numbers; total input length is at most 80.

The output root is derived by Mojo::Util::decamelize. For MyApp it is my_app. Module paths follow the package components.

## Existing destinations

The generator refuses to replace an existing destination. It does not merge templates into existing projects. Its writer attempts cleanup of newly written files and directories on failure.

Commit or back up your work before manually migrating an existing starter. Regenerating does not update an application in place.

## Exit statuses

| Status | Meaning |
| --- | --- |
| 0 | Success, help or version |
| 1 | Project creation failed |
| 2 | Invalid command, argument count or project/package name |

## Revised starter contract

The revised generator adds private server/client YAML files, .gitignore, dependency declarations and user-oriented README instructions to both styles. It uses TOKEN_APP in a handshake header, not exported token environment variables.

Its starter configuration has no room, message or duration keys. Example sends and callbacks live in Perl. Client/Events.pm is included in the modular starter so developers have an obvious place to add event behavior.

The older generator supplied with the original source does not follow this YAML contract. Install the revised Generator.pm before following these documents.

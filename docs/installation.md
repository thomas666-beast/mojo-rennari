# Installation

[Documentation home](README.md)

## Requirements

The supplied distribution declares:

| Component | Requirement |
| --- | --- |
| Perl | 5.020 or later |
| Mojolicious | 9.00 or later |
| Data::MessagePack | Required; no minimum version declared |
| Test::More | Required for distribution tests |
| YAML::PP | Required by the revised generated applications |

YAML::PP is a generated-application dependency, not a framing dependency. The revised generator writes it into the generated cpanfile.

## Install from your source checkout

From the distribution directory containing Makefile.PL:

```sh
perl Makefile.PL
make
make test
make install
```

Use your usual Perl dependency installer to install missing dependencies. For example, if cpanm is available:

```sh
cpanm Mojolicious Data::MessagePack YAML::PP
```

The commands above do not assume that a particular release is available from CPAN. Work from your own distribution when developing Rennari.

## Check the command

```sh
mojo-rennari --version
mojo-rennari help
```

If you are working before installation, run the distribution's command with its library path:

```sh
perl -Ilib script/mojo-rennari help
```

Use that command prefix in place of mojo-rennari when generating a project from the checkout.

## Generated application dependencies

Each new project contains a cpanfile. Install its declared dependencies using your normal dependency workflow. When developing a local, unpublished Rennari release, ensure that the local distribution is installed or otherwise available in Perl's module search path.

Next: [Quick start](quickstart.md).

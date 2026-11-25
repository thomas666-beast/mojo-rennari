# Testing

[Documentation home](README.md)

## Run the distribution tests

```sh
perl Makefile.PL
make test
```

The supplied Makefile.PL declares Test::More. The examples below are suggested tests to add; they are not a claim about which tests already exist in your distribution.

## Protocol unit test

Create a test such as t/protocol-basic.t:

```perl
use 5.020;
use strict;
use warnings;
use Test::More;
use Mojo::Rennari::Protocol qw(encode_frame decode_frame valid_event_name);

for my $serializer (qw(msgpack json)) {
    my $bytes = encode_frame('greet', {name => 'Alice'}, $serializer, 42, undef, '/chat');
    my $frame = decode_frame($bytes, serializer => $serializer);
    is($frame->{e}, 'greet', "$serializer event");
    is($frame->{d}{name}, 'Alice', "$serializer payload");
    is($frame->{id}, 42, "$serializer id");
    is($frame->{n}, '/chat', "$serializer namespace");
    ok(!defined decode_frame($bytes, serializer => $serializer, max_bytes => 1),
        "$serializer rejects oversized frame");
}

ok(!valid_event_name('bad event'), 'spaces rejected');
ok(!valid_event_name(''), 'empty event rejected');
done_testing;
```

## Application integration tests

Use Mojolicious's testing tools to cover the actual generated application. Test the handshake with matching TOKEN_APP and rejection with a missing or wrong token. A successful demo handshake does not test real user authentication until you replace the demo identity.

Test these behaviors explicitly:

- ping results in pong with the expected payload.
- whoami does not expose credentials.
- Invalid application payloads receive controlled application errors.
- Unknown events close with 4003 outside mock mode.
- A named namespace must be registered and joined.
- Room broadcasts remain inside the authorized room and namespace.
- Disconnect removes live membership.
- Handler exceptions produce 4004 without leaking secrets.
- Duplicate acknowledged requests do not duplicate important side effects.

## Recovery tests

Exercise same-owner resume, wrong-owner rejection, live-session rejection, expiry and both buffer limits. Separately verify that online-but-lost frames and offline room broadcasts are not replayed by the current implementation. Test process restarts and multiple workers rather than assuming a shared session store.

## Test without weakening production policy

Mock mode can help isolate development behavior, but it bypasses server authentication. Keep at least one test path with mock disabled and real credential validation. Do not set force_mock in deployment configuration.

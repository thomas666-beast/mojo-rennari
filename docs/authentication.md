# Authentication and application access

[Documentation home](README.md)

## Two different checks

TOKEN_APP answers: “Does this connection possess our shared application credential?”

User authentication answers: “Which user is this, and are their credentials valid?”

Neither check replaces authorization: “May this user perform this event or join this room?”

## Generated application check

The client sends:

```perl
headers => {
    'X-Rennari-App-Token' => $config->{TOKEN_APP},
}
```

The server checks this header in auth_cb using secure_compare. This is generated application policy, not a mandatory protocol field. The core server accepts whatever authentication policy your auth_cb implements.

A shared secret cannot prove that a client is an approved program. Anyone who obtains it can write another client. Do not ship this secret in browser JavaScript or a publicly distributed client and expect it to remain private.

## Add real user authentication

The following is a pattern to adapt, not a complete authentication backend. Here `$accounts` represents your own service, whose authenticate_bearer method you must implement:

```perl
auth_cb => sub {
    my $c = shift;

    my $app_token = $c->req->headers->header('X-Rennari-App-Token') // '';
    return undef unless secure_compare($app_token, $config->{TOKEN_APP});

    my $header = $c->req->headers->authorization // '';
    my ($bearer) = $header =~ /\ABearer (\S+)\z/;
    return undef unless defined $bearer;

    my $user = $accounts->authenticate_bearer($bearer);
    return undef unless $user;

    return {
        id      => "$user->{id}",
        user_id => $user->{id},
        name    => $user->{name},
    };
},
```

Return a hash reference for acceptance, or a false value for rejection. A truthy value that is not a hash reference is an authentication error. When recovery is enabled outside mock mode, the identity must include a stable, non-empty scalar id.

Server behavior before upgrade:

| Condition | HTTP status |
| --- | --- |
| Authentication rejected | 401 |
| auth_cb missing with mock disabled | 500 |
| auth_cb dies or returns an invalid accepted identity | 500 |
| Recovery identity lacks a valid id | 500 |

The accepted identity is available through `$c->stash('rennari_identity')`.

## Authorization happens in application code

Namespace joins are not automatically permission-checked. A registered namespace can be joined by an authenticated client that requests it. Room membership also has no built-in per-user permission policy.

Check access before joining a room, broadcasting private data, executing a command, or sending another user's information. Do not trust an incoming user_id as the authenticated identity.

## Browser clients

No supported browser client implementation is included in the supplied source. Do not assume browser WebSocket APIs can reproduce the Perl client's custom-header setup. A browser transport needs its own reviewed handshake and user-authentication design. Socket.IO clients cannot connect using the Rennari event protocol.

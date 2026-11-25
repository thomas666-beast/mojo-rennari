# Application examples

[Documentation home](README.md)

These are snippets to add to your generated event registration code, not complete standalone scripts. Send only after connecting. The examples do not require new YAML keys.

## A named notification

Server:

```perl
$rennari->on(subscribe => sub {
    my ($c, $payload) = @_;
    my $identity = $c->stash('rennari_identity');
    $c->rennari->send_to_self(welcome => {name => $identity->{name}});
    return undef;
});
```

Client registration:

```perl
$client->on(welcome => sub {
    my ($client, $payload) = @_;
    return unless ref $payload eq 'HASH';
    say 'Welcome, ' . ($payload->{name} // 'user');
});
```

Client send from its existing connect handler:

```perl
$client->send(subscribe => {});
```

## A public-room example

This policy allows every authenticated user into any room matching the example naming rule. It is not appropriate for private rooms without additional permission checks.

```perl
$rennari->on(chat => sub {
    my ($c, $payload) = @_;
    return {error => 'object required'} unless ref $payload eq 'HASH';
    my ($room, $text) = @{$payload}{qw(room text)};
    return {error => 'invalid room'}
        unless defined $room && !ref $room && $room =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    return {error => 'text must contain 1 to 2000 characters'}
        unless defined $text && !ref $text && length($text) && length($text) <= 2000;

    my $identity = $c->stash('rennari_identity');
    # Add room authorization HERE before joining or broadcasting.
    $c->rennari->join($room);
    $c->rennari->broadcast_to_room($room, chat => {
        room => $room, from => $identity->{name}, text => $text,
    });
    return undef;
});
```

Client:

```perl
$client->on(chat => sub {
    my ($client, $payload) = @_;
    return unless ref $payload eq 'HASH';
    say "$payload->{from}: $payload->{text}";
});

# Inside the connected path:
$client->send(chat => {room => 'lobby', text => 'Hello'});
```

## Correlate application results

Server:

```perl
$rennari->on(check_status => sub {
    my ($c, $payload) = @_;
    return {error => 'object required'} unless ref $payload eq 'HASH';
    my $key = $payload->{request_key};
    return {error => 'invalid request key'}
        unless defined $key && !ref $key && $key =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    return {request_key => $key, status => 'ready'};
});
```

Client sends an application key and reads it from reply. This key is separate from the wire acknowledgement id. The example status is static; replace it with a real authorized application operation.

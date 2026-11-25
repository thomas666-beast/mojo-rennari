# Wire protocol reference

[Documentation home](README.md)

## Transport and serialization

Rennari uses WebSocket binary messages. Each message contains one serialized map, encoded with Data::MessagePack by default or Mojo::JSON when configured as json. Both peers must agree on the serializer; there is no negotiation handshake for it.

This is a Rennari protocol, not Socket.IO framing or Engine.IO.

## Map fields

```text
{ e: event_name, d: payload, id: optional_ack_id,
  o: optional_outbound_offset, n: optional_namespace }
```

| Field | Meaning |
| --- | --- |
| e | Required validated event name |
| d | Required payload field; its value can be null |
| id | Optional acknowledgement id |
| o | Optional recovery offset |
| n | Optional namespace; omission means `/` |

Unknown extra map fields are not rejected by the current decoder. The protocol validates the envelope, not your payload's application schema.

## Validation

- Event: 1–64 characters from `[A-Za-z0-9_.:-]`.
- Namespace: `/` followed by 0–63 characters from `[A-Za-z0-9_.:/-]`.
- Id: 1–20 decimal digits before numeric coercion.
- Offset: one or more decimal digits, with no explicit digit-count limit in the validator.
- Default decode maximum: 65536 encoded bytes.

Ids and offsets are coerced to numbers. Validation is not a portable arbitrary-precision guarantee: avoid relying on 20-digit ids round-tripping exactly across runtimes. Interoperable JavaScript implementations should keep integer values within a range their number representation handles exactly.

The encoder validates names and optional ids/offsets but does not enforce the decoder's byte-size limit. Configure compatible receiver limits and constrain payloads in your application.

## Control events

| Event | Direction | Payload |
| --- | --- | --- |
| rennari_ack | Server → client | `{id}` |
| rennari_nsp | Client → server | `{name}` |
| rennari_nsp_ok | Server → client | `{name}` |
| rennari_session | Server → client | `{id}` recovery session |
| rennari_resume | Client → server | `{session_id, offset}` |
| rennari_resumed | Server → client | `{offset, session_id}` |
| rennari_resume_failed | Server → client | `{reason: "unknown_session"}` |

Treat the rennari_ prefix as reserved application naming space. The current event-name validator does not reserve it for you. Control requests are processed before ordinary namespace routing and do not receive the regular event acknowledgement path.

## Close codes

| Code | Reason |
| --- | --- |
| 4002 | Invalid incoming frame |
| 4003 | Unknown event in normal mode |
| 4004 | Handler exception or failed automatic reply |
| 4005 | Missing, invalid, unknown or unjoined namespace |
| 4006 | Resume requested while recovery disabled |

Authentication failures occur before WebSocket upgrade and use HTTP responses instead. See [Authentication](authentication.md).

## Protocol helper API

```perl
use Mojo::Rennari::Protocol qw(
    encode_frame decode_frame
    valid_event_name valid_id valid_namespace_name
);

my $bytes = encode_frame('notice', {text => 'Hello'}, 'msgpack', undef, undef, '/chat');
my $frame = decode_frame($bytes, serializer => 'msgpack', max_bytes => 65536);
```

encode_frame arguments are event, payload, serializer, id, offset, namespace. Serializer defaults to msgpack. Default namespace `/` is omitted on encoding. Invalid encoder input throws.

decode_frame returns undef for malformed input, oversize bytes or invalid envelope fields. An unsupported serializer throws instead of returning undef. valid_offset exists as a fully qualified helper but is not in EXPORT_OK.

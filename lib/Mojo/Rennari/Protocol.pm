package Mojo::Rennari::Protocol;
use Mojo::Base -strict;
use Data::MessagePack;
use Mojo::JSON qw(encode_json decode_json);
use Exporter 'import';

our $VERSION = '0.002';

our @EXPORT_OK = qw(
    encode_frame decode_frame
    valid_event_name valid_id valid_namespace_name
);

use constant DEFAULT_MAX_BYTES => 64 * 1024;
use constant MAX_EVENT_LEN     => 64;

my $EVENT_RE = qr/\A[A-Za-z0-9_.:-]{1,64}\z/;
my $NSP_RE   = qr{\A/[A-Za-z0-9_.:/-]{0,63}\z};
my $mp       = Data::MessagePack->new->utf8;

sub valid_event_name {
    my ($name) = @_;
    return 0 unless defined $name && !ref $name;
    return $name =~ $EVENT_RE ? 1 : 0;
}

sub valid_id {
    my ($id) = @_;
    return 0 if !defined $id || ref $id;
    return $id =~ /\A[0-9]{1,20}\z/ ? 1 : 0;
}

sub valid_namespace_name {
    my ($name) = @_;
    return 0 unless defined $name && !ref $name;
    return $name =~ $NSP_RE ? 1 : 0;
}

sub _check_serializer {
    my ($s) = @_;
    $s //= 'msgpack';
    die "unsupported serializer '$s'"
        unless $s eq 'msgpack' || $s eq 'json';
    return $s;
}

# encode_frame($event, $payload, $serializer, $id, $offset, $namespace)
sub encode_frame {
    my ($event, $payload, $serializer, $id, $offset, $nsp) = @_;
    die 'encode_frame: invalid event name'
        unless valid_event_name($event);
    my $s = _check_serializer($serializer);
    my $frame = { e => $event, d => $payload };
    if (defined $id) {
        die 'encode_frame: invalid id' unless valid_id($id);
        $frame->{id} = $id + 0;    # coerce to number
    }
    if (defined $offset) {
        die 'encode_frame: invalid offset' unless $offset =~ /\A[0-9]+\z/;
        $frame->{o} = $offset + 0;
    }
    # the default namespace is implied and omitted from the wire
    if (defined $nsp && $nsp ne '/') {
        die 'encode_frame: invalid namespace'
            unless valid_namespace_name($nsp);
        $frame->{n} = $nsp;
    }
    return $s eq 'json' ? encode_json($frame) : $mp->pack($frame);
}

sub decode_frame {
    my ($bytes, %opts) = @_;
    return undef unless defined $bytes && !ref $bytes && length $bytes;

    my $serializer = _check_serializer($opts{serializer});
    my $max        = $opts{max_bytes} // DEFAULT_MAX_BYTES;
    return undef if length($bytes) > $max;

    my $frame;
    if ($serializer eq 'json') {
        $frame = eval { decode_json($bytes) };
    }
    else {
        $frame = eval { $mp->unpack($bytes) };
    }
    return undef if $@;

    return undef unless ref $frame eq 'HASH';
    return undef unless valid_event_name($frame->{e});
    return undef unless exists $frame->{d};

    if (exists $frame->{o}) {
        return undef unless $frame->{o} =~ /\A[0-9]+\z/;
        $frame->{o} += 0;
    }

    if (exists $frame->{id}) {
        return undef unless valid_id($frame->{id});
        $frame->{id} += 0;
    }

    if (exists $frame->{n}) {
        return undef unless valid_namespace_name($frame->{n});
    }

    return $frame;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Protocol - MessagePack or JSON framing with optional ids

=head1 SYNOPSIS

  use Mojo::Rennari::Protocol qw(encode_frame decode_frame);

  my $bytes = encode_frame('smile', { ok => 1 });              # no id
  my $bytes = encode_frame('smile', { ok => 1 }, undef, 42);   # id 42
  my $bytes = encode_frame('hi', {}, undef, undef, undef, '/chat');

  my $frame = decode_frame($bytes);
  # { e => 'smile', d => { ok => 1 }, id => 42 }

=head1 DESCRIPTION

Wire format is a map:

  { e => $event_name, d => $payload, id => $id?, o => $offset?, n => $namespace? }

The optional C<id> is used for acknowledgement. When a frame has an id,
the server replies with C<< { e => 'rennari_ack', d => { id => $id } } >>
after the handler returns successfully. If the handler dies, no ack is
sent, and the client's retry logic (in the JavaScript client) resends
the frame.

The optional C<n> names the namespace the frame belongs to. When absent
it is C</>. Both sides route frames by C<n>, so the namespace is never
connection state.

Duplicate delivery is possible with retries. The framework does not
deduplicate; the application should treat retried events as idempotent
if it uses retries.

=head1 SECURITY

Ids are validated to be decimal digits only, 1 to 20 characters. No
negative, no fraction, no string payload. Namespace names must start with
C</> and be at most 64 characters of C<[A-Za-z0-9_.:/-]>. Malformed ids or
namespaces cause the whole frame to be rejected.

=cut

package Mojo::Rennari::Protocol;
use Mojo::Base -strict;
use Data::MessagePack;
use Mojo::JSON qw(encode_json decode_json);
use Exporter 'import';

our $VERSION = '0.001';

our @EXPORT_OK = qw(encode_frame decode_frame valid_event_name valid_id);

use constant DEFAULT_MAX_BYTES => 64 * 1024;
use constant MAX_EVENT_LEN     => 64;

my $EVENT_RE = qr/\A[A-Za-z0-9_.:-]{1,64}\z/;
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

sub _check_serializer {
    my ($s) = @_;
    $s //= 'msgpack';
    die "unsupported serializer '$s'"
        unless $s eq 'msgpack' || $s eq 'json';
    return $s;
}

sub encode_frame {
    my ($event, $payload, $serializer, $id) = @_;
    die 'encode_frame: invalid event name'
        unless valid_event_name($event);
    my $s = _check_serializer($serializer);
    my $frame = { e => $event, d => $payload };
    if (defined $id) {
        die 'encode_frame: invalid id' unless valid_id($id);
        $frame->{id} = $id + 0;    # coerce to number
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

    if (exists $frame->{id}) {
        return undef unless valid_id($frame->{id});
        $frame->{id} += 0;
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

  my $frame = decode_frame($bytes);
  # { e => 'smile', d => { ok => 1 }, id => 42 }

=head1 DESCRIPTION

Wire format is a map:

  { e => $event_name, d => $payload, id => $id? }

The optional C<id> is used for acknowledgement. When a frame has an id,
the server replies with C<< { e => 'rennari_ack', d => { id => $id } } >>
after the handler returns successfully. If the handler dies, no ack is
sent, and the client's retry logic (in the JavaScript client) resends
the frame.

Duplicate delivery is possible with retries. The framework does not
deduplicate; the application should treat retried events as idempotent
if it uses retries.

=head1 SECURITY

Ids are validated to be decimal digits only, 1 to 20 characters. No
negative, no fraction, no string payload. Malformed ids cause the whole
frame to be rejected.

=cut

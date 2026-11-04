package Mojo::Rennari::Protocol;
use Mojo::Base -strict;
use Data::MessagePack;
use Mojo::JSON qw(encode_json decode_json);
use Exporter 'import';

our $VERSION = '0.001';

our @EXPORT_OK = qw(encode_frame decode_frame valid_event_name);

use constant DEFAULT_MAX_BYTES => 64 * 1024;
use constant MAX_EVENT_LEN     => 64;

my $EVENT_RE = qr/\A[A-Za-z0-9_.:-]{1,64}\z/;
my $mp       = Data::MessagePack->new->utf8;

sub valid_event_name {
    my ($name) = @_;
    return 0 unless defined $name && !ref $name;
    return $name =~ $EVENT_RE ? 1 : 0;
}

sub _check_serializer {
    my ($s) = @_;
    $s //= 'msgpack';
    die "unsupported serializer '$s'"
        unless $s eq 'msgpack' || $s eq 'json';
    return $s;
}

sub encode_frame {
    my ($event, $payload, $serializer) = @_;
    die 'encode_frame: invalid event name'
        unless valid_event_name($event);
    my $s = _check_serializer($serializer);
    my $frame = { e => $event, d => $payload };
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
    return $frame;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Protocol - MessagePack or JSON framing

=head1 SYNOPSIS

  use Mojo::Rennari::Protocol qw(encode_frame decode_frame);

  my $bytes = encode_frame('smile', { ok => 1 });           # msgpack (default)
  my $bytes = encode_frame('smile', { ok => 1 }, 'json');   # json

  my $frame = decode_frame($bytes);                          # msgpack
  my $frame = decode_frame($bytes, serializer => 'json');    # json

=head1 DESCRIPTION

Wire format is a single map:

  { e => $event_name, d => $payload }

The serializer is chosen per call. C<msgpack> is the default; C<json>
is available for environments where MessagePack is inconvenient.
MessagePack is better for binary payloads; JSON only handles text and
numbers cleanly.

Decoding is defensive. Malformed input, wrong shape, invalid event name,
or frames larger than C<max_bytes> (default 64 KiB) return C<undef>.
C<decode_frame> never dies on untrusted input.

The serializer is a per-server choice, not a per-connection one. A
server started with C<serializer =E<gt> 'msgpack'> only parses
MessagePack; a server with C<serializer =E<gt> 'json'> only parses
JSON. Mismatched frames fail to decode, same as any other malformed
input.

=cut

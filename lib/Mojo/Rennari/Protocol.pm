package Mojo::Rennari::Protocol;
use Mojo::Base -strict;
use Data::MessagePack;
use Exporter 'import';

our $VERSION = '0.001';

our @EXPORT_OK = qw(encode_frame decode_frame valid_event_name);

# 64 KiB default. A real-time event frame should be tiny; anything
# larger is almost certainly a bug or an attack.
use constant DEFAULT_MAX_BYTES => 64 * 1024;

# Event names: 1..64 chars, [A-Za-z0-9_.:-]. Deliberately narrow so
# names are safe in logs, URLs, and handler dispatch tables.
use constant MAX_EVENT_LEN => 64;
my $EVENT_RE = qr/\A[A-Za-z0-9_.:-]{1,64}\z/;

my $mp = Data::MessagePack->new->utf8;

sub valid_event_name {
    my ($name) = @_;
    return 0 unless defined $name && !ref $name;
    return $name =~ $EVENT_RE ? 1 : 0;
}

sub encode_frame {
    my ($event, $payload) = @_;
    die 'encode_frame: invalid event name'
        unless valid_event_name($event);
    return $mp->pack({ e => $event, d => $payload });
}

sub decode_frame {
    my ($bytes, %opts) = @_;
    return undef unless defined $bytes && !ref $bytes && length $bytes;

    my $max = $opts{max_bytes} // DEFAULT_MAX_BYTES;
    return undef if length($bytes) > $max;

    my $frame = eval { $mp->unpack($bytes) };
    return undef if $@;
    return undef unless ref $frame eq 'HASH';
    return undef unless valid_event_name($frame->{e});
    return undef unless exists $frame->{d};

    return $frame;
}

1;
__END__

=head1 NAME

Mojo::Rennari::Protocol - MessagePack framing for Mojo::Rennari

=head1 SYNOPSIS

  use Mojo::Rennari::Protocol qw(encode_frame decode_frame);

  my $bytes = encode_frame('smile', { ok => 1 });
  my $frame = decode_frame($bytes);
  # { e => 'smile', d => { ok => 1 } }

=head1 DESCRIPTION

Wire format is a single MessagePack map:

  { e => $event_name, d => $payload }

The event name is validated on both encode and decode: 1 to 64
characters from C<[A-Za-z0-9_.:-]>. Anything else is rejected. This
keeps event names safe to log, route, and interpolate.

Decoding is defensive. Malformed MessagePack, non-map frames, missing
keys, or frames larger than C<max_bytes> (default 64 KiB) all return
C<undef>. C<decode_frame> never dies on untrusted input.

=head1 FUNCTIONS

=head2 encode_frame

  my $bytes = encode_frame($event, $payload);

Dies on an invalid event name. The payload may be any structure
MessagePack can encode.

=head2 decode_frame

  my $frame = decode_frame($bytes, max_bytes => 32768);

Returns C<< { e => ..., d => ... } >> or C<undef>. Optional
C<max_bytes> overrides the 64 KiB default.

=head2 valid_event_name

  valid_event_name('smile');   # 1
  valid_event_name("bad\n");   # 0

=cut

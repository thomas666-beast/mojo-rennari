use 5.020;
use strict;
use warnings;
use Test::More;
use Data::MessagePack;

use Mojo::Rennari::Protocol qw(encode_frame decode_frame valid_event_name);

# --- valid_event_name -------------------------------------------------
ok  valid_event_name('smile'),              'plain name ok';
ok  valid_event_name('chat.message'),       'dot ok';
ok  valid_event_name('ns:event'),           'colon ok';
ok  valid_event_name('a-b_c.1:2'),          'mixed chars ok';
ok  valid_event_name('a' x 64),             '64 chars ok';
ok !valid_event_name('a' x 65),             '65 chars rejected';
ok !valid_event_name(''),                   'empty rejected';
ok !valid_event_name(undef),                'undef rejected';
ok !valid_event_name("bad\n"),              'newline rejected';
ok !valid_event_name('with space'),         'space rejected';
ok !valid_event_name('ünïcode'),            'non-ASCII rejected';
ok !valid_event_name({}),                   'ref rejected';

# --- encode_frame -----------------------------------------------------
my $bytes = encode_frame('smile', { ok => 1, n => [1,2,3] });
ok defined $bytes && length $bytes, 'encode produced bytes';

my $plain = Data::MessagePack->new->utf8->unpack($bytes);
is_deeply $plain, { e => 'smile', d => { ok => 1, n => [1,2,3] } },
    'wire shape is {e,d}';

eval { encode_frame('', {}) };
like $@, qr/invalid event name/, 'encode rejects empty event';
eval { encode_frame("bad\n", {}) };
like $@, qr/invalid event name/, 'encode rejects bad event';

# --- decode_frame round-trip -----------------------------------------
is_deeply decode_frame($bytes), { e => 'smile', d => { ok => 1, n => [1,2,3] } },
    'round-trip';

# undefined payload is still a valid frame
my $undef_payload = Data::MessagePack->new->utf8->pack({ e => 'ping', d => undef });
is_deeply decode_frame($undef_payload), { e => 'ping', d => undef },
    'undefined payload round-trips';

# --- decode_frame rejections -----------------------------------------
is decode_frame(undef),  undef, 'undef input rejected';
is decode_frame(''),     undef, 'empty input rejected';
is decode_frame('garbage'), undef, 'garbage rejected';

my $not_a_map = Data::MessagePack->new->utf8->pack([1,2,3]);
is decode_frame($not_a_map), undef, 'non-map rejected';

my $no_e = Data::MessagePack->new->utf8->pack({ d => 1 });
is decode_frame($no_e), undef, 'missing e rejected';

my $bad_e = Data::MessagePack->new->utf8->pack({ e => "x\ny", d => 1 });
is decode_frame($bad_e), undef, 'invalid event name rejected';

my $no_d = Data::MessagePack->new->utf8->pack({ e => 'ok' });
is decode_frame($no_d), undef, 'missing d rejected';

# --- size limit -------------------------------------------------------
my $big_payload = 'x' x 1000;
my $big = encode_frame('smile', $big_payload);
ok length($big) > 200, 'big frame is actually big';
is decode_frame($big, max_bytes => 100), undef, 'max_bytes enforced';
isnt decode_frame($big, max_bytes => 100_000), undef, 'large max allows it';

done_testing;

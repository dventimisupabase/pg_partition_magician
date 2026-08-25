-- Extends the text_time codec (tests/86) with what cuid v1 alone didn't need: a configurable alphabet
-- (Crockford base32 for ULID, base62 for KSUID -- neither is the plain contiguous 0-9a-z convention),
-- a numeric (not bigint) intermediate so KSUID's 160-bit whole-payload encoding doesn't overflow, and
-- discard_bits + a custom epoch so a timestamp that is the TOP bits of a wider encoded value (KSUID),
-- rather than the whole decoded field (cuid, ULID), can still be expressed.
create extension if not exists pgtap;

select plan(9);

-- ---- custom alphabet: Crockford base32 (ULID's), skips I/L/O/U ----
select is(
  pgpm._radix_decode('J', 32, '0123456789ABCDEFGHJKMNPQRSTVWXYZ'),
  18::numeric, 'radix_decode: Crockford base32 J = 18 (I is skipped, so J follows H at 17)'
);
select is(
  pgpm._radix_encode(18, 32, 1, '0123456789ABCDEFGHJKMNPQRSTVWXYZ'),
  'J', 'radix_encode: 18 in Crockford base32 = J'
);

-- ---- custom alphabet: base62 (KSUID's), digits then A-Z then a-z ----
select is(
  pgpm._radix_decode('a', 62, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'),
  36::numeric, 'radix_decode: base62 lowercase a = 36 (after 0-9 and A-Z)'
);

-- ---- numeric, not bigint: a value that overflows a 64-bit bigint (max ~9.2e18) must still round-trip ----
select is(
  pgpm._radix_encode(10::numeric^20, 10, 21),
  '100000000000000000000', 'radix_encode: 10^20 (21 digits, past bigint range) encodes without overflow'
);
select is(
  pgpm._radix_decode('100000000000000000000', 10),
  10::numeric^20, 'radix_decode: decodes the same 10^20 value back exactly'
);

-- ---- discard_bits + custom epoch: a timestamp that is the TOP bits of a WIDER encoded value ----
-- 4 hex digits = 16 bits; discard the low 8, custom epoch 2000-01-01, unit seconds.
-- 0x0105 >> 8 = 1 -- one second after the epoch, and the discarded low byte (0x05) must not matter.
select is(
  pgpm._text_time_to_ts('0105', '', 4, 16, 's', null, 8, timestamptz '2000-01-01 00:00:00+00'),
  timestamptz '2000-01-01 00:00:01+00',
  'text_time_to_ts: discard_bits drops the low byte, only the top 8 bits count'
);
select is(
  pgpm._ts_to_text_time(timestamptz '2000-01-01 00:00:01+00', '', 4, 16, 's', null, 8, timestamptz '2000-01-01 00:00:00+00'),
  '0100', 'ts_to_text_time: shifts the epoch count left by discard_bits before encoding'
);

-- ---- realistic KSUID scale: whole 27-char base62 string, discard the low 128 bits, custom epoch ----
select is(
  pgpm._text_time_to_ts(
    pgpm._ts_to_text_time(timestamptz '2026-01-01 00:00:00+00', '', 27, 62,
      's', '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'),
    '', 27, 62, 's', '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'),
  timestamptz '2026-01-01 00:00:00+00',
  'KSUID-scale round trip: encode then decode a 160-bit-wide value returns the exact same instant'
);

-- an alphabet with fewer characters than the declared radix is refused, not silently misdecoded
select throws_ok(
  $$ select pgpm._radix_decode('5', 10, '01234') $$,
  NULL, NULL,
  'radix_decode refuses when the alphabet length does not match the declared radix'
);

select * from finish();

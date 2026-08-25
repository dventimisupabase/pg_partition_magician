-- The text_time control kind (scoped in issue discussion, not yet wired into transmute): a general
-- adapter for opaque TEXT ids whose value is <constant prefix> + <fixed-width base-N encoded epoch>,
-- covering classic cuid (prefix 'c', 8 base36 digits, ms) and future formats (KSUID, ULID-as-text,
-- TypeID, ...) via the same 4 numbers: prefix, width, radix, unit. This file proves the codec layer in
-- isolation, exactly as tests/39 proves _uuid_to_ts/_ts_to_uuid before anything else depends on them.
--
-- The width is deliberately tiny (2 base36 digits, ceiling 1295ms after the epoch) so the overflow
-- boundary is hand-verifiable rather than a magic far-future constant.
create extension if not exists pgtap;

select plan(10);

-- ---- _radix_decode / _radix_encode: the bottom primitive, base-N <-> bigint, lowercase 0-9a-z ----

select is(pgpm._radix_decode('z', 36), 35::numeric, 'radix_decode: single digit z (base36) = 35');
select is(pgpm._radix_decode('10', 36), 36::numeric, 'radix_decode: 10 (base36) = 36 (Horner, not concatenation)');
select is(pgpm._radix_encode(35, 36, 1), 'z', 'radix_encode: 35 (base36), width 1 = z');
select is(pgpm._radix_encode(36, 36, 2), '10', 'radix_encode: 36 (base36), width 2 = 10, zero-padded');

select throws_ok(
  $$ select pgpm._radix_encode(1296, 36, 2) $$,
  '22003', NULL,
  'radix_encode refuses rather than truncates when the value needs more digits than the width'
);

select throws_ok(
  $$ select pgpm._radix_decode('g', 16) $$,
  '22P02', NULL,
  'radix_decode refuses a character that is not a valid digit for the given radix (g >= 16)'
);

-- ---- _ts_to_text_time / _text_time_to_ts: the timestamp-shaped wrapper ----

select is(
  pgpm._ts_to_text_time(timestamptz '1970-01-01 00:00:01.295+00', 'c', 2, 36, 'ms'),
  'czz', 'ts_to_text_time: 1295ms since epoch, prefix c, width 2 (base36) = czz (the encodable ceiling)'
);

select is(
  pgpm._text_time_to_ts('czz', 'c', 2, 36, 'ms'),
  timestamptz '1970-01-01 00:00:01.295+00',
  'text_time_to_ts: czz decodes back to the exact same instant (round trip)'
);

select throws_ok(
  $$ select pgpm._ts_to_text_time(timestamptz '1970-01-01 00:00:01.296+00', 'c', 2, 36, 'ms') $$,
  '22003', NULL,
  'ts_to_text_time refuses one ms past the ceiling, not silently wraps to a smaller/misordered value'
);

select throws_ok(
  $$ select pgpm._text_time_to_ts('xzz', 'c', 2, 36, 'ms') $$,
  '22P02', NULL,
  'text_time_to_ts refuses a value that does not start with the declared prefix'
);

select * from finish();

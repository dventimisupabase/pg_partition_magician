-- How the Parquet writer represents a `timestamp` (without time zone) column (issue #465).
--
-- A timestamptz is an instant and encodes the same in every session. A `timestamp` is a wall clock
-- with no instant of its own, and the writer used to push it through `::timestamptz`, which reads
-- the wall clock in the SESSION zone: the same partition archived by the pg_cron worker (cluster
-- default zone) and by an operator's `call pgpm.maintain()` from a differently-zoned psql carried
-- different instants for the same rows, while the NDJSON path (row_to_json) preserved the wall
-- clock either way. The writer now encodes the wall clock read as if it were UTC, Parquet's
-- representation of a naive timestamp, and annotates the leaf LogicalType
-- TIMESTAMP(isAdjustedToUTC=false, MICROS) beside the legacy TIMESTAMP_MICROS ConvertedType, the
-- pair pyarrow itself writes for a naive timestamp. Readers that know logical types give the wall
-- clock back as a naive timestamp; older ones see TIMESTAMP_MICROS and show it labelled UTC.
--
-- Two negatives live here ("the zone did not leak into the bytes", "the leaf is not the UTC-adjusted
-- one"), and each is paired with a witness that the condition it denies was present: the two sessions
-- really ran in different zones (read back from current_setting, not assumed from the SET), and the
-- session-zone cast the old writer used really does move these wall clocks, by two DIFFERENT offsets
-- (EST and EDT), so a compensating error cannot make the two files agree by accident. The encoded
-- values are asserted by identity against hand-computed microsecond epochs, never against each other.
-- The independent-reader half (pyarrow and DuckDB decoding the wall clock) lives in
-- scripts/verify_parquet.py, which pgTAP cannot reach.
select plan(18);

create table public.naive14 (
  id   int4 primary key,          -- the key archive._pq_to_parquet_range needs to tiebreak on
  ts   timestamp not null,        -- a wall clock
  tstz timestamptz not null       -- an instant
);
insert into public.naive14 (id, ts, tstz) values
  (1, '2024-01-15 12:00:00', '2024-01-15 18:30:00+00'),   -- New York is on EST here (UTC-5)
  (2, '2024-07-15 12:00:00', '2024-07-15 18:30:00+00');   -- and on EDT here (UTC-4)

-- The expected microsecond epochs, pinned as literals so the test does not derive them from anything
-- the writer might share:
--   ts   row 1: 2024-01-15 12:00:00 read as UTC = 1705320000 s    row 2: 2024-07-15 12:00:00 = 1721044800 s
--   tstz row 1: 2024-01-15 18:30:00+00          = 1705343400 s    row 2: 2024-07-15 18:30:00+00 = 1721068200 s
-- and what the old writer produced for ts under New York (12:00 EST = 17:00 UTC, 12:00 EDT = 16:00 UTC):
--   1705338000 s and 1721059200 s, five and four hours late.

create temp table pq14 (label text primary key, zone text not null, bytes bytea not null);

-- ---------------------------------------------------------------------------
-- Session one: America/New_York
-- ---------------------------------------------------------------------------

set timezone = 'America/New_York';

select is(current_setting('TimeZone'), 'America/New_York',
  'witness: the first archive session runs in America/New_York');

select is(
  (select array_agg((extract(epoch from ts::timestamptz) * 1000000)::int8 order by id) from public.naive14),
  array[1705338000000000, 1721059200000000]::int8[],
  'witness: in that zone the session-zone cast the old writer used moves the two wall clocks by five and four hours, so the zone has something to leak');

insert into pq14 values ('whole_ny', current_setting('TimeZone'), archive._pq_to_parquet('public.naive14', false));
insert into pq14 values ('range_ny', current_setting('TimeZone'), archive._pq_to_parquet_range('public.naive14', 'id', '1', '3', false));

-- ---------------------------------------------------------------------------
-- Session two: UTC
-- ---------------------------------------------------------------------------

set timezone = 'UTC';

select is(current_setting('TimeZone'), 'UTC',
  'witness: the second archive session runs in UTC');

select is(
  (select array_agg((extract(epoch from ts::timestamptz) * 1000000)::int8 order by id) from public.naive14),
  array[1705320000000000, 1721044800000000]::int8[],
  'witness: in UTC the same cast leaves them where they are, so the two sessions would have disagreed');

insert into pq14 values ('whole_utc', current_setting('TimeZone'), archive._pq_to_parquet('public.naive14', false));
insert into pq14 values ('range_utc', current_setting('TimeZone'), archive._pq_to_parquet_range('public.naive14', 'id', '1', '3', false));

select is(
  (select count(distinct zone)::int from pq14), 2,
  'witness: the four files were written from two different session zones');

-- ---------------------------------------------------------------------------
-- The bytes do not depend on the session
-- ---------------------------------------------------------------------------

select is(
  (select bytes from pq14 where label = 'whole_ny'),
  (select bytes from pq14 where label = 'whole_utc'),
  'archive._pq_to_parquet writes byte-identical files from the New York and UTC sessions');

select is(
  (select bytes from pq14 where label = 'range_ny'),
  (select bytes from pq14 where label = 'range_utc'),
  'and so does archive._pq_to_parquet_range');

-- ---------------------------------------------------------------------------
-- What the bytes are: the wall clock read as UTC, and the instant untouched
-- ---------------------------------------------------------------------------

-- Where the pages sit. p_compress => false and every column NOT NULL, so a page is exactly its PLAIN
-- values: PAR1, then per column a page header and the page; id is 2 x 4 bytes, ts and tstz 2 x 8.
select 4 + length(archive._pq_build_page_header(2, 8)) + 8 + length(archive._pq_build_page_header(2, 16)) as ts_off \gset
select :ts_off + 16 + length(archive._pq_build_page_header(2, 16)) as tstz_off \gset

select is(
  (select substring(bytes from :ts_off + 1 for 16) from pq14 where label = 'whole_utc'),
  archive._pq_plain_int64(1705320000000000) || archive._pq_plain_int64(1721044800000000),
  'the ts page is the two wall clocks read as UTC: 1705320000000000 and 1721044800000000 microseconds');

select is(
  (select substring(bytes from :ts_off + 1 for 16) from pq14 where label = 'range_utc'),
  archive._pq_plain_int64(1705320000000000) || archive._pq_plain_int64(1721044800000000),
  'and the range encoder''s ts page is the same two values');

select is(
  (select substring(bytes from :tstz_off + 1 for 16) from pq14 where label = 'whole_utc'),
  archive._pq_plain_int64(1705343400000000) || archive._pq_plain_int64(1721068200000000),
  'the tstz page is unchanged: the two instants themselves, 1705343400000000 and 1721068200000000');

-- The literal means what the comment says it means, and it is what NDJSON emits for the same row.
select is(to_timestamp(1705320000) at time zone 'UTC', '2024-01-15 12:00:00'::timestamp,
  '1705320000 s read as UTC is the wall clock row 1 holds');

select is((select row_to_json(n)->>'ts' from public.naive14 n where id = 1), '2024-01-15T12:00:00',
  'which is the wall clock row_to_json (the NDJSON path) emits for it, so the two formats now agree');

-- ---------------------------------------------------------------------------
-- The annotation: a naive TIMESTAMP, beside the legacy ConvertedType
-- ---------------------------------------------------------------------------

-- Thrift compact protocol, by hand. SchemaElement fields: 1 type=INT64 (15 04), 3 repetition=REQUIRED
-- (25 00), 4 name (18 <len> <utf8>), 6 converted_type=TIMESTAMP_MICROS (25 14), then for ts only 10
-- logicalType (4c) = union LogicalType field 8 TIMESTAMP (8c) { 1 isAdjustedToUTC=false (12),
-- 2 unit (1c) = union TimeUnit field 2 MICROS (2c) {} (00) } (00) } (00) } (00), and the element's own
-- stop (00).
select is(
  archive._pq_build_schema_leaf('ts', 2, 10, false, p_logical_type => archive._pq_logical_timestamp_micros(false)),
  '\x150425001802747325144c8c121c2c0000000000'::bytea,
  'the ts leaf carries LogicalType TIMESTAMP(isAdjustedToUTC=false, MICROS) after ConvertedType TIMESTAMP_MICROS');

select is(
  archive._pq_build_schema_leaf('tstz', 2, 10, false),
  '\x1504250018047473747a251400'::bytea,
  'and a tstz leaf is byte-for-byte what it was: ConvertedType TIMESTAMP_MICROS alone, an instant');

select cmp_ok(
  (select position('\x150425001802747325144c8c121c2c0000000000'::bytea in bytes) from pq14 where label = 'whole_utc'),
  '>', 0,
  'archive._pq_to_parquet''s footer carries that ts leaf');

select cmp_ok(
  (select position('\x150425001802747325144c8c121c2c0000000000'::bytea in bytes) from pq14 where label = 'range_utc'),
  '>', 0,
  'and so does archive._pq_to_parquet_range''s');

select cmp_ok(
  (select position('\x1504250018047473747a251400'::bytea in bytes) from pq14 where label = 'whole_utc'),
  '>', 0,
  'the tstz leaf is in the footer unchanged');

-- The old ts leaf (ConvertedType alone, which readers take as isAdjustedToUTC=true) is gone. Its witness
-- is the presence assertion above: the ts leaf IS in the footer, just not this one.
select is(
  (select position('\x1504250018027473251400'::bytea in bytes) from pq14 where label = 'whole_utc'), 0,
  'and the old ts leaf, which labelled the wall clock a UTC-adjusted instant, is not');

reset timezone;
select * from finish();

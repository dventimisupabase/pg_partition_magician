-- from_hypertable_copy spliced each chunk's range_start/range_end with a bare %L (issue #459).
--
-- timescaledb_information.chunks renders EVERY time dimension's bounds as timestamptz: the slice's
-- raw microseconds handed to _timescaledb_functions.to_timestamp(bigint), for a timestamp (no tz)
-- or date dimension exactly as for a timestamptz one. `%L` of that value renders the instant in the
-- SESSION TimeZone ('2024-01-01 09:00:00+09' under Asia/Tokyo), and when the untyped literal is
-- then coerced to a `timestamp` column the offset is DISCARDED. Every chunk range shifts by the UTC
-- offset. East of UTC the oldest chunk's first N hours fall below the union of the ranges and no
-- chunk copies them; the cutover's `> max(dest)` catch-up cannot reach rows below its watermark, so
-- they are gone after the migration (540 of 2880 rows in the hunt). West of UTC the last chunk's
-- tail is missed by the copy and rescued only by the catch-up, by accident. A `date` dimension
-- round-trips east of UTC by luck (a positive offset never crosses midnight) and loses its last day
-- west of it.
--
-- The chunk's own CHECK constraint is the authority on what it holds, and for the oldest naive
-- chunk it reads `ts >= '2024-01-01 00:00:00'::timestamp without time zone`: nine hours before what
-- the view shows in a Tokyo session. That disagreement is the condition for the defect, so it is
-- witnessed here explicitly, alongside the session zone itself, before and after each copy. The
-- copy runs in this session, so the zone asserted after it is the zone its literals were rendered
-- in. Row assertions are by IDENTITY (which rows), not by count alone: the hunt saw 540 rows vanish,
-- and a count is invariant under compensating errors.
--
-- Autocommit, disposable-db: from_hypertable_copy commits per chunk, so it is called bare.
set timezone = 'Asia/Tokyo';
select plan(41);

-- The dimension CHECK constraint of a hypertable's OLDEST chunk, as pg_get_constraintdef renders it.
-- Timescale names its dimension constraints constraint_N; a fixture here carries no other CHECK.
create function t19_oldest_chunk_check(p_ht text) returns text language sql as $$
  select pg_get_constraintdef(c.oid)
    from timescaledb_information.chunks ch
    join pg_namespace n on n.nspname = ch.chunk_schema
    join pg_class k on k.relnamespace = n.oid and k.relname = ch.chunk_name
    join pg_constraint c on c.conrelid = k.oid and c.contype = 'c' and c.conname like 'constraint_%'
   where ch.hypertable_name = p_ht
   order by ch.range_start limit 1
$$;

-- How the chunks view renders the oldest chunk's range_start in THIS session.
create function t19_oldest_range_start(p_ht text) returns text language sql as $$
  select range_start::text from timescaledb_information.chunks
   where hypertable_name = p_ht order by range_start limit 1
$$;

-- ================= PART A: timestamp (no tz) dimension, Asia/Tokyo (UTC+9), copy then cutover =================
--
-- The issue's fixture: 2880 one-minute rows from 2024-01-01 00:00 to 2024-01-02 23:59 on daily chunks,
-- so two chunks whose CHECKs begin at naive midnight. v = minute index, so a row's identity is its v.
create table t19_tokyo (ts timestamp not null, v int not null);
do $$ begin perform create_hypertable('t19_tokyo', 'ts', chunk_time_interval => interval '1 day'); end $$;
insert into t19_tokyo select timestamp '2024-01-01' + (g || ' minutes')::interval, g from generate_series(0, 2879) g;
create table t19_tokyo_snap as select * from t19_tokyo;   -- fidelity baseline for after the cutover

select is(current_setting('TimeZone'), 'Asia/Tokyo',
  'WITNESS A: the session TimeZone is Asia/Tokyo before the copy');
select is((select count(*)::int from t19_tokyo), 2880, 'setup A: the source holds 2880 rows');
select is((select min(ts) from t19_tokyo), timestamp '2024-01-01 00:00:00',
  'setup A: the source begins at wall-clock midnight');
select is((select count(*)::int from timescaledb_information.chunks where hypertable_name = 't19_tokyo'),
  2, 'setup A: two daily chunks');
select is(t19_oldest_range_start('t19_tokyo'), '2024-01-01 09:00:00+09',
  'WITNESS A: the chunks view renders the oldest chunk''s range_start with a +09 offset in this session');
select ok(t19_oldest_chunk_check('t19_tokyo') like '%''2024-01-01 00:00:00''::timestamp without time zone%',
  'WITNESS A: the chunk''s own CHECK begins at naive 2024-01-01 00:00:00, nine hours before the view''s rendering');

call pgpm.from_hypertable_copy('t19_tokyo', 'ts');

select is(current_setting('TimeZone'), 'Asia/Tokyo',
  'WITNESS A: the session TimeZone was still Asia/Tokyo when the copy returned');
select is((select count(*)::int from t19_tokyo_pgpm_dest), 2880, 'A: all 2880 rows were copied');
select is((select count(distinct ts)::int from t19_tokyo_pgpm_dest), 2880, 'A: and none twice');
select is((select min(ts) from t19_tokyo_pgpm_dest), (select min(ts) from t19_tokyo),
  'A: the destination''s min(ts) is the source''s: the first nine hours were not lost');
select results_eq(
  'select ts, v from t19_tokyo_pgpm_dest order by ts limit 10',
  'select ts, v from t19_tokyo order by ts limit 10',
  'IDENTITY A: the first 10 rows of the destination are the first 10 rows of the source');
select results_eq(
  'select ts, v from t19_tokyo_pgpm_dest order by ts desc limit 10',
  'select ts, v from t19_tokyo order by ts desc limit 10',
  'IDENTITY A: the last 10 rows of the destination are the last 10 rows of the source');
-- The exact rows the defect lost: the 540 minutes below 09:00 on the first day.
select results_eq(
  'select v from t19_tokyo_pgpm_dest where ts < timestamp ''2024-01-01 09:00:00'' order by v',
  'select g from generate_series(0, 539) g',
  'IDENTITY A: the 540 rows of the first nine hours, v = 0..539, are all present');
select ok(rows_equal('t19_tokyo', 't19_tokyo_pgpm_dest'),
  'A: full rowset identity, EXCEPT empty in both directions');

-- End to end: the cutover carries whatever the copy produced, so the migrated table must hold the lot.
call pgpm.from_hypertable_cutover('t19_tokyo', 'ts', interval '1 month', p_paused => false);

select is((select relkind::text from pg_class where oid = 't19_tokyo'::regclass), 'p',
  'A: the table migrated to a native partitioned table');
select is((select count(*)::int from t19_tokyo), 2880, 'A: 2880 rows after the migration');
select ok(rows_equal('t19_tokyo', 't19_tokyo_snap'),
  'A: the migrated table is row-for-row the pre-migration snapshot');

-- ================= PART B: timestamp (no tz) dimension, America/Los_Angeles (UTC-8 in January) =================
--
-- West of UTC the shift goes the other way: the view renders the oldest chunk as beginning at
-- 16:00 on the PREVIOUS calendar day, and the LAST chunk's final eight hours fall above the union
-- of the shifted ranges. The hunt saw those rows come back only through the cutover's catch-up;
-- this asserts them present after the COPY, which is what the catch-up must not be needed for.
set timezone = 'America/Los_Angeles';

create table t19_la (ts timestamp not null, v int not null);
do $$ begin perform create_hypertable('t19_la', 'ts', chunk_time_interval => interval '1 day'); end $$;
insert into t19_la select timestamp '2024-01-01' + (g || ' minutes')::interval, g from generate_series(0, 2879) g;

select is(current_setting('TimeZone'), 'America/Los_Angeles',
  'WITNESS B: the session TimeZone is America/Los_Angeles before the copy');
select is(t19_oldest_range_start('t19_la'), '2023-12-31 16:00:00-08',
  'WITNESS B: the chunks view renders the oldest chunk''s range_start with a -08 offset, on the previous calendar day');
select ok(t19_oldest_chunk_check('t19_la') like '%''2024-01-01 00:00:00''::timestamp without time zone%',
  'WITNESS B: the chunk''s own CHECK still begins at naive 2024-01-01 00:00:00');

call pgpm.from_hypertable_copy('t19_la', 'ts');

select is(current_setting('TimeZone'), 'America/Los_Angeles',
  'WITNESS B: the session TimeZone was still America/Los_Angeles when the copy returned');
select is((select count(*)::int from t19_la_pgpm_dest), 2880, 'B: all 2880 rows were copied');
select is((select count(distinct ts)::int from t19_la_pgpm_dest), 2880, 'B: and none twice');
select results_eq(
  'select ts, v from t19_la_pgpm_dest order by ts limit 10',
  'select ts, v from t19_la order by ts limit 10',
  'IDENTITY B: the first 10 rows of the destination are the first 10 rows of the source');
select results_eq(
  'select ts, v from t19_la_pgpm_dest order by ts desc limit 10',
  'select ts, v from t19_la order by ts desc limit 10',
  'IDENTITY B: the last 10 rows of the destination are the last 10 rows of the source');
-- The exact rows the westward defect misses: the 480 minutes from 16:00 on the last day.
select results_eq(
  'select v from t19_la_pgpm_dest where ts >= timestamp ''2024-01-02 16:00:00'' order by v',
  'select g from generate_series(2400, 2879) g',
  'IDENTITY B: the 480 rows of the last eight hours, v = 2400..2879, are present after the copy alone');
select ok(rows_equal('t19_la', 't19_la_pgpm_dest'),
  'B: full rowset identity, EXCEPT empty in both directions');

-- ================= PART C: date dimension, America/Los_Angeles =================
--
-- `'2023-12-31 16:00:00-08'::date` is 2023-12-31, so west of UTC every chunk range slides one day
-- early and the last day is copied by no chunk. Asymmetric fixture: day k holds k+1 rows, so a lost
-- day and a duplicated day can never cancel into the right total.
create table t19_date (d date not null, v int not null);
do $$ begin perform create_hypertable('t19_date', 'd', chunk_time_interval => interval '1 day'); end $$;
insert into t19_date select date '2024-01-01' + k, 10 * k + g
  from generate_series(0, 4) k cross join lateral generate_series(1, k + 1) g;

select is((select count(*)::int from timescaledb_information.chunks where hypertable_name = 't19_date'),
  5, 'setup C: five daily chunks holding 15 rows');
select is(t19_oldest_range_start('t19_date'), '2023-12-31 16:00:00-08',
  'WITNESS C: the chunks view renders the oldest date chunk''s range_start on the previous calendar day in this session');
select ok(t19_oldest_chunk_check('t19_date') like '%''2024-01-01''::date%',
  'WITNESS C: the chunk''s own CHECK begins at 2024-01-01');

call pgpm.from_hypertable_copy('t19_date', 'd');

select is((select count(*)::int from t19_date_pgpm_dest), 15, 'C: all 15 rows were copied');
select results_eq(
  'select d, v from t19_date_pgpm_dest order by d, v',
  'select d, v from t19_date order by d, v',
  'IDENTITY C: the destination is the source, row for row');
select results_eq(
  'select v from t19_date_pgpm_dest where d = date ''2024-01-05'' order by v',
  'select g from generate_series(41, 45) g',
  'IDENTITY C: the last day''s five rows, v = 41..45, are present');

-- ================= PART D: timestamptz dimension, Asia/Tokyo (invariant, not a discriminator) =================
--
-- The one dimension type the old splice handled correctly, because a timestamptz literal carries
-- its offset. Pinned so the typed rendering keeps preserving the instant exactly.
set timezone = 'Asia/Tokyo';

create table t19_tz (ts timestamptz not null, v int not null);
do $$ begin perform create_hypertable('t19_tz', 'ts', chunk_time_interval => interval '1 day'); end $$;
insert into t19_tz select timestamptz '2024-01-01 00:00:00+09' + (g || ' hours')::interval, g from generate_series(0, 47) g;

select is(current_setting('TimeZone'), 'Asia/Tokyo', 'WITNESS D: the session TimeZone is Asia/Tokyo');
select is((select count(*)::int from timescaledb_information.chunks where hypertable_name = 't19_tz'),
  3, 'setup D: 48 hourly rows from Tokyo midnight straddle three UTC-aligned daily chunks');

call pgpm.from_hypertable_copy('t19_tz', 'ts');

select is((select count(*)::int from t19_tz_pgpm_dest), 48, 'D: all 48 rows were copied');
select results_eq(
  'select ts, v from t19_tz_pgpm_dest order by ts limit 10',
  'select ts, v from t19_tz order by ts limit 10',
  'IDENTITY D: the first 10 rows of the destination are the first 10 rows of the source');
select results_eq(
  'select ts, v from t19_tz_pgpm_dest order by ts desc limit 10',
  'select ts, v from t19_tz order by ts desc limit 10',
  'IDENTITY D: the last 10 rows of the destination are the last 10 rows of the source');
select ok(rows_equal('t19_tz', 't19_tz_pgpm_dest'),
  'D: full rowset identity, EXCEPT empty in both directions');

-- ================= PART E: a dimension the bounds cannot be rendered for is refused, leaving nothing =================
--
-- An integer dimension has NULL range_start/range_end in the chunks view (it reports the *_integer
-- columns instead), so the old predicate `i >= NULL` copied nothing and handed the cutover an empty
-- destination to rename into place. The refusal must come before the copy creates anything: the
-- destination skeleton is committed early, and a refusal after it strands an empty <rel>_pgpm_dest
-- that a later cutover would happily swap in. The message is matched only on its pgpm prefix so a
-- refusal moved earlier, into the preflight, still satisfies it; the load-bearing assertion is the
-- absence of the destination.
create table t19_int (i bigint not null, v int not null);
do $$ begin perform create_hypertable('t19_int', 'i', chunk_time_interval => 100); end $$;
insert into t19_int select g, g from generate_series(1, 250) g;

select throws_like(
  $$ call pgpm.from_hypertable_copy('t19_int', 'i') $$,
  'pg_partition_magician:%',
  'E: the copy refuses an integer dimension');
select ok(to_regclass('public.t19_int_pgpm_dest') is null,
  'E: and left no destination behind for a cutover to find');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

-- from_hypertable migrated to ZERO rows and reported success (issue #458), in two shapes that share one
-- root cause. The online copy bounds every chunk with `where <p_control> >= range_start and < range_end`
-- read from timescaledb_information.chunks. That predicate partitions the table only when p_control IS
-- the hypertable's time dimension AND that dimension is a timestamp type. Preflight checked neither; it
-- only checked that the column exists.
--
--   * An INTEGER-TIME dimension (bigint/integer/smallint): range_start and range_end are NULL for every
--     chunk (the bounds live in range_start_integer), so every chunk copied `t >= NULL and t < NULL`,
--     which is nothing; the cutover then dropped the hypertable and transmute refused the int8 column,
--     AFTER the irreversible drop. End state: no hypertable, a plain table with 0 rows, no pgpm config.
--   * A p_control that is a time column but NOT the dimension: the chunk ranges are ranges of the
--     dimension, so a copy bounded on some other column keeps only the rows whose other-column value
--     happens to fall inside one of them, and here that is none. Migration reported success on a
--     partitioned table with 0 rows.
--
-- Both are refused up front now, by from_hypertable_preflight and by every procedure that can reach the
-- copy or the cutover: from_hypertable_copy, from_hypertable and from_hypertable_cutover (which is
-- guarded in its own right, because an older copy or a hand-made destination can put a
-- <rel>_pgpm_dest in place without the copy phase ever having refused).
--
-- WHAT THE HARNESS ALLOWS, and why the assertions look the way they do. run_timescale fails the track
-- on any `ERROR:` line, so every call is wrapped by throws_like, and a procedure that reaches its own
-- COMMIT inside a function context raises `invalid transaction termination`. So a run that WRONGLY
-- proceeds cannot be observed committing: it dies at its first COMMIT and rolls back, landing in the
-- same end state as a correct refusal. The discriminating assertions are therefore the refusals' own
-- messages; the state assertions after them are invariants, not discriminators, and are marked so.
--
-- WITNESSES. Every refusal here is a negative ("did not migrate"), which an execution where nothing
-- happened at all also satisfies. So each fixture first proves the condition being refused is really
-- present: that the dimension really is integer-typed with its bounds in range_start_integer, and that
-- p_control really differs from the dimension while still existing as a time column (so the column-
-- exists check alone would have let it through, which is how it shipped).
select plan(30);

-- ================= PART A: an INTEGER-TIME dimension =================

create table it18 (t bigint not null, v int);
select create_hypertable('it18', 't', chunk_time_interval => 100);
insert into it18 select g, g from generate_series(1, 1000) g;

select is(
  (select column_name || ' ' || column_type::text from timescaledb_information.dimensions
    where hypertable_name = 'it18' and dimension_number = 1),
  't bigint', 'WITNESS: the fixture''s time dimension is t, typed bigint');
select is(
  (select count(range_start) || ' typed, ' || count(range_start_integer) || ' integer, of ' || count(*)
     from timescaledb_information.chunks where hypertable_name = 'it18'),
  '0 typed, 11 integer, of 11',
  'WITNESS: every chunk bound lives in range_start_integer and range_start is NULL, which is the column the copy reads');
select is((select count(*)::int from it18), 1000, 'setup: the source holds its 1000 rows');

select throws_like(
  $$ select pgpm.from_hypertable_preflight('it18', 't') $$,
  '%integer-time hypertables are not supported%',
  'preflight refuses the integer-time dimension');
select throws_like(
  $$ call pgpm.from_hypertable_copy('it18', 't') $$,
  '%integer-time hypertables are not supported%',
  'from_hypertable_copy refuses it before creating anything');
select throws_like(
  $$ call pgpm.from_hypertable('it18', 't', interval '1 day') $$,
  '%integer-time hypertables are not supported%',
  'from_hypertable refuses it');

-- The cutover is the irreversible step, and it did not run preflight at all: it only required that a
-- destination exist. A destination left by a copy run under an older version, or made by hand, is
-- enough to reach the DROP. p_predrain => false so no COMMIT is reachable before the refusal for an
-- unrelated reason (the pre-drain commits per batch).
create table it18_pgpm_dest (like it18);
select throws_like(
  $$ call pgpm.from_hypertable_cutover('it18', 't', interval '1 day', p_predrain => false) $$,
  '%integer-time hypertables are not supported%',
  'from_hypertable_cutover refuses it in its own right, even with a destination in place');
drop table it18_pgpm_dest;

-- Invariants (a wrongly proceeding mutant rolls back at its COMMIT and lands here too).
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'it18'),
  1, 'it18 is still a hypertable');
select is((select count(*)::int from it18), 1000, 'with all 1000 of its rows');
select is((select string_agg(t || '=' || v, ',' order by t) from it18 where t in (1, 500, 1000)),
  '1=1,500=500,1000=1000', 'sample by identity: the first, middle and last rows are intact');
select ok(to_regclass('public.it18_pgpm_dest') is null,
  'no destination table was left behind: the refusal landed before any copy work');

-- The refusal is an allowlist (timestamptz, timestamp, date), not a check for bigint specifically.
create table si18 (t integer not null, v int);
select create_hypertable('si18', 't', chunk_time_interval => 100);
select is(
  (select column_type::text from timescaledb_information.dimensions
    where hypertable_name = 'si18' and dimension_number = 1),
  'integer', 'WITNESS: si18''s dimension is typed integer');
select throws_like(
  $$ select pgpm.from_hypertable_preflight('si18', 't') $$,
  '%integer-time hypertables are not supported%',
  'preflight refuses an integer (int4) dimension the same way');

-- ================= PART B: p_control is a time column that is NOT the dimension =================

create table wc18 (ts timestamptz not null, created_at timestamptz not null, v int);
select create_hypertable('wc18', 'ts', chunk_time_interval => interval '1 day');
insert into wc18
  select now() - (g || ' hours')::interval, now() - (g || ' hours')::interval - interval '30 days', g
    from generate_series(1, 48) g;

select is(
  (select column_name::text from timescaledb_information.dimensions
    where hypertable_name = 'wc18' and dimension_number = 1),
  'ts', 'WITNESS: the dimension is ts, not created_at');
select is(
  (select format_type(atttypid, atttypmod) from pg_attribute
    where attrelid = 'wc18'::regclass and attname = 'created_at' and not attisdropped),
  'timestamp with time zone',
  'WITNESS: created_at exists and is a time column, so a column-exists check alone passes it');
select is(
  (select count(*)::int from wc18
    where created_at >= (select min(range_start) from timescaledb_information.chunks
                          where hypertable_name = 'wc18')),
  0, 'WITNESS: no created_at value falls inside any chunk''s ts range, so a copy bounded on it would move nothing');
select is((select count(*)::int from wc18), 48, 'setup: the source holds its 48 rows');

select throws_like(
  $$ select pgpm.from_hypertable_preflight('wc18', 'created_at') $$,
  '%on column created_at -- its time dimension is ts%',
  'preflight refuses a p_control that is not the dimension, naming the actual dimension column');
select throws_like(
  $$ call pgpm.from_hypertable_copy('wc18', 'created_at') $$,
  '%on column created_at -- its time dimension is ts%',
  'from_hypertable_copy refuses it before creating anything');
select throws_like(
  $$ call pgpm.from_hypertable('wc18', 'created_at', interval '1 month', p_paused => false) $$,
  '%on column created_at -- its time dimension is ts%',
  'from_hypertable refuses it (the exact call that used to report success on 0 rows)');
create table wc18_pgpm_dest (like wc18);
select throws_like(
  $$ call pgpm.from_hypertable_cutover('wc18', 'created_at', interval '1 month', p_predrain => false) $$,
  '%on column created_at -- its time dimension is ts%',
  'from_hypertable_cutover refuses it in its own right, even with a destination in place');
drop table wc18_pgpm_dest;

select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'wc18'),
  1, 'wc18 is still a hypertable');
select is((select count(*)::int from wc18), 48, 'with all 48 of its rows');
select is((select string_agg(v || ':' || (ts - created_at)::text, ',' order by v) from wc18 where v in (1, 24, 48)),
  '1:30 days,24:30 days,48:30 days',
  'sample by identity: the first, middle and last rows are intact with both time columns');
select ok(to_regclass('public.wc18_pgpm_dest') is null,
  'no destination table was left behind');
select is((select count(*)::int from pgpm.config), 0,
  'nothing was handed to transmute: pgpm.config is empty');

-- ================= PART C: positive controls =================
--
-- The refusal must not over-reach: the same hypertable passes on its dimension column, and all three
-- supported dimension types pass. A refusal that never lets anything through would satisfy every
-- assertion above.

select lives_ok(
  $$ select pgpm.from_hypertable_preflight('wc18', 'ts') $$,
  'positive control: the same hypertable passes preflight when p_control is its dimension');

create table tt18 (t timestamp not null, v int);
select create_hypertable('tt18', 't', chunk_time_interval => interval '1 day');
select lives_ok(
  $$ select pgpm.from_hypertable_preflight('tt18', 't') $$,
  'positive control: a timestamp (without time zone) dimension passes');

create table dd18 (d date not null, v int);
select create_hypertable('dd18', 'd', chunk_time_interval => interval '7 days');
select lives_ok(
  $$ select pgpm.from_hypertable_preflight('dd18', 'd') $$,
  'positive control: a date dimension passes');

-- A column that does not exist at all keeps its own message; the dimension check comes after it.
select throws_like(
  $$ select pgpm.from_hypertable_preflight('wc18', 'nope') $$,
  '%column nope not found on%',
  'a column that does not exist still gets the not-found message, not the dimension one');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

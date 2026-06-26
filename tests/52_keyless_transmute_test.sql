-- Keyless support. A table with neither a primary key nor a unique constraint can still be transmuted:
-- pgpm partitions it on the control column with no key synthesized (faithful to a keyless source, e.g.
-- the plain hypertable shape un-hypertabled by from_hypertable). The one requirement is that the control
-- column be NOT NULL (a partition key cannot be null, and pgpm never scans to enforce it). A nullable
-- control column on a keyless table is refused up front, leaving the table intact.
create extension if not exists pgtap;

begin;
select plan(8);

-- (A) keyless table (no PK, no unique constraint), control NOT NULL
create table public.kl (ts timestamptz not null, device int, val float8);
insert into public.kl (ts, device, val)
  select date_trunc('month', now()) - interval '3 months' + (g || ' days')::interval, g, random()
  from generate_series(1, 40) g;

select lives_ok(
  $$ select pgpm.transmute('public.kl', 'ts', interval '1 month', p_paused => false) $$,
  'transmute accepts a keyless table (no primary key, no unique constraint)');
select is(
  (select relkind::text from pg_class where oid = 'public.kl'::regclass),
  'p', 'the keyless table is now partitioned');
select is(
  (select count(*)::int from pg_constraint where conrelid = 'public.kl'::regclass and contype in ('p', 'u')),
  0, 'no primary key or unique constraint was synthesized (faithful to the keyless source)');
select is(
  (select attnotnull from pg_attribute where attrelid = 'public.kl'::regclass and attname = 'ts'),
  true, 'the control column is NOT NULL');
select is((select count(*)::int from public.kl), 40, 'all rows conserved through the parent');
-- the monolith holds the history as one coarse child, queryable through the parent
select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.kl'::regclass and attached),
  1, 'the history is attached as a single monolith child');

-- (B) keyless table with a NULLABLE control column -> refuse (NOT NULL required, never a scan)
create table public.kl_null (ts timestamptz, v int);   -- nullable control
insert into public.kl_null select now() - (g || ' days')::interval, g from generate_series(1, 10) g;
select throws_like(
  $$ select pgpm.transmute('public.kl_null', 'ts', interval '1 month') $$,
  'pg_partition_magician:%NOT NULL%',
  'a keyless table with a nullable control column is refused, naming NOT NULL');
select is(
  (select relkind::text from pg_class where oid = 'public.kl_null'::regclass),
  'r', 'the nullable-control keyless table is left intact');

select * from finish();
rollback;

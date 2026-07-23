-- archive.configure()/archive.unconfigure()/archive.schedule()/archive.unschedule(): the
-- operator interface wrapping archive.config and pg_cron. archive.schedule()/unschedule()
-- reuse pgpm.schedule()/unschedule()'s own cron.schedule_in_database mechanics verbatim (proven
-- happy-path coverage against a real job in tests/31_schedule_test.sql, run against the 'postgres'
-- database where pg_cron's own cron.database_name is pinned); this disposable-db-per-file track
-- can only exercise the guard, since pg_cron's extension can only ever be created in whichever one
-- database cron.database_name names -- never in a throwaway database like this one.
select plan(13);

select mk_archive_table('a7', 60, 10, 20);   -- a small managed table; this file archives nothing
create table public.a7_unmanaged (id bigint);   -- NOT pgpm-managed, for the guard check below

select throws_like(
  $$ select archive.configure('public.a7_unmanaged', 'test-bucket') $$,
  '%is not managed%',
  'archive.configure refuses a table pgpm does not manage');

select archive.configure('public.a7', 'bucket-one', p_region => 'us-west-2',
  p_boundary_rule => 'partition_aligned', p_drop_trigger => 'gate_only', p_format => 'ndjson_single');

select is(
  (select bucket from archive.config where parent_table = 'public.a7'::regclass), 'bucket-one',
  'configure() sets bucket');
select is(
  (select region from archive.config where parent_table = 'public.a7'::regclass), 'us-west-2',
  'configure() sets region');
select is(
  (select boundary_rule from archive.config where parent_table = 'public.a7'::regclass), 'partition_aligned',
  'configure() sets boundary_rule');
select is(
  (select drop_trigger from archive.config where parent_table = 'public.a7'::regclass), 'gate_only',
  'configure() sets drop_trigger');
select is(
  (select format from archive.config where parent_table = 'public.a7'::regclass), 'ndjson_single',
  'configure() sets format');

-- re-configuring is an upsert, not a duplicate row or an error.
select archive.configure('public.a7', 'bucket-two',
  p_boundary_rule => 'byte_budget', p_drop_trigger => 'self_driving');

select is(
  (select count(*)::int from archive.config where parent_table = 'public.a7'::regclass), 1,
  're-configuring updates the existing row, not a second one');
select is(
  (select bucket from archive.config where parent_table = 'public.a7'::regclass), 'bucket-two',
  're-configuring overwrites the previous settings');
select is(
  (select boundary_rule from archive.config where parent_table = 'public.a7'::regclass), 'byte_budget',
  're-configuring can flip the boundary rule');

select archive.unconfigure('public.a7');

select is(
  (select count(*)::int from archive.config where parent_table = 'public.a7'::regclass), 0,
  'unconfigure() removes the config row');

select lives_ok($$ select archive.unconfigure('public.a7') $$, 'unconfigure() is idempotent');

-- archive.schedule()/unschedule(): pg_cron cannot be created in this throwaway database (its
-- extension enforces cron.database_name, pinned to 'postgres' -- see the file header), so this
-- exercises the guard rather than a real job.
select throws_like(
  $$ select archive.schedule() $$,
  '%pg_cron is not installed%',
  'schedule() raises a clear error when pg_cron is not available, rather than failing obscurely');

select is(archive.unschedule(), 0, 'unschedule() is a no-op (0) when pg_cron is not available');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

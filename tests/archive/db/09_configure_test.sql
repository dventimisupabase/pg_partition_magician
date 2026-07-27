-- archive.configure/archive.unconfigure: the operator interface for archive.config, restoring what
-- issue #240 collaterally deleted (the old paced worker's archive.configure/unconfigure/schedule/
-- unschedule) but for the CURRENT architecture -- connection settings only, no scheduling knob
-- (pgpm.maintain()'s own schedule already drives archiving; see pgpm.set_archive_fn for the
-- archive_fn switch, a separate call on purpose since archive.config serves both the archive_fn
-- strategies and the synchronous functions, while archive_fn only matters for the former).
begin;
select plan(9);

select mk_archive_table('c09', 100, 1000);

create table public.unmanaged09 (id int);

select throws_like(
  $$ select archive.configure('public.unmanaged09', 'my-bucket') $$,
  '%is not managed by pgpm%',
  'archive.configure refuses a table pgpm does not manage');

select archive.configure('public.c09', 'my-bucket');

select is(
  (select bucket from archive.config where parent_table = 'public.c09'::regclass),
  'my-bucket', 'archive.configure inserts a row with the given bucket');

select is(
  (select region from archive.config where parent_table = 'public.c09'::regclass),
  'us-east-1', 'archive.configure applies the documented default region');

select archive.configure('public.c09', 'other-bucket', p_region => 'eu-west-1', p_compress => true);

select is(
  (select count(*)::int from archive.config where parent_table = 'public.c09'::regclass),
  1, 'calling archive.configure again upserts the same row rather than duplicating it');

select is(
  (select bucket from archive.config where parent_table = 'public.c09'::regclass),
  'other-bucket', 'the upsert overwrites the bucket');

select is(
  (select region from archive.config where parent_table = 'public.c09'::regclass),
  'eu-west-1', 'the upsert overwrites the region');

select ok(
  (select compress from archive.config where parent_table = 'public.c09'::regclass),
  'the upsert overwrites compress');

select archive.unconfigure('public.c09');

select is(
  (select count(*)::int from archive.config where parent_table = 'public.c09'::regclass),
  0, 'archive.unconfigure deletes the row');

select lives_ok(
  $$ select archive.unconfigure('public.c09') $$,
  'archive.unconfigure is idempotent -- calling it again on an already-unconfigured table is a no-op');

select * from finish();
rollback;

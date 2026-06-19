-- Drives the drain to completion and verifies windows attach and DEFAULT empties.
-- Uses drain_all() (synchronous, ignores the pause flag) so the test does not
-- depend on the pg_cron clock.
create extension if not exists pgtap;

begin;
select plan(4);

select cmp_ok(
  (select count(*) from partition_migration.windows where state = 'pending')::int,
  '>', 0,
  'there are pending windows before draining'
);

select cmp_ok(
  partition_migration.drain_all(5000),
  '>', 0,
  'drain_all performed at least one batch'
);

select is(
  (select count(*) from partition_migration.windows where state <> 'attached')::int,
  0,
  'every window reached the attached state'
);

select is(
  (select count(*) from public.messages_default)::int,
  0,
  'the DEFAULT partition is fully drained'
);

select * from finish();
rollback;

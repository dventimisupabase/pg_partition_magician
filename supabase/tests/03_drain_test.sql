-- Drives the drain to completion and verifies the DEFAULT empties.
-- Uses drain_all (synchronous, ignores pause) so it doesn't depend on pg_cron.
create extension if not exists pgtap;

begin;
select plan(3);

select cmp_ok(
  (select closed_rows from pgpm.check_default('public.messages'))::int,
  '>', 0,
  'closed-interval rows exist in the DEFAULT before draining'
);

select cmp_ok(
  pgpm.drain_all('public.messages', p_include_open => true),
  '>', 0,
  'drain_all performed at least one batch'
);

select is(
  (select count(*) from public.messages_default)::int,
  0,
  'DEFAULT fully drained (open/current month included)'
);

select * from finish();
rollback;

-- Verifies the default-scan-skip optimization: closed intervals attach via the
-- exclusion-CHECK path, the open/current interval uses a write-safe plain attach,
-- and no temporary exclusion constraints linger on the default.
create extension if not exists pgtap;

begin;
select plan(3);

select pgpm.drain_all('public.messages', p_include_open => true);

select is(
  (select count(*) from pgpm.log where action = 'drain_attach' and method = 'plain')::int,
  1,
  'exactly one plain attach -- the open/current month'
);

select cmp_ok(
  (select count(*) from pgpm.log where action = 'drain_attach' and method = 'check_skip')::int,
  '>', 0,
  'closed months attached via the scan-skipping check_skip path'
);

select is(
  (select count(*) from pg_constraint
    where conrelid = 'public.messages_default'::regclass and conname ~ '_excl$')::int,
  0,
  'temporary exclusion CHECK constraints were dropped after attach'
);

select * from finish();
rollback;

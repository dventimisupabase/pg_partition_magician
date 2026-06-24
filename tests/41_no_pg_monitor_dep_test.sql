-- Regression test for issue #98. The adaptive ambient (consumer-priority) signal no longer depends on
-- pg_monitor. It reads pg_locks (lock-wait pressure) and pg_stat_database (read-I/O latency) -- both
-- fully visible to any role -- instead of cross-role wait_event in pg_stat_activity, which pg_monitor
-- masks for other roles. So pgpm's only runtime dependency is pg_cron again, and adaptive feathering's
-- consumer signal works under a plain, unprivileged role.
create extension if not exists pgtap;

begin;
select plan(4);

-- the lock-wait sensor reads pg_locks (visible to any role) and returns a non-negative count
select cmp_ok(pgpm._ambient_lock_waiters(), '>=', 0::int,
              'the lock-wait sensor works (pg_locks is visible to any role, no pg_monitor)');

-- the I/O-latency term derives ms/block from pg_stat_database deltas (pure spot-check)
select is(pgpm._ambient_io_latency(100, 1000, 300, 1100), 2.0::numeric,
          'the I/O-latency term computes ms/block from pg_stat_database deltas');

-- the clincher: NO pgpm function reads wait_event from pg_stat_activity -- the one access that needed
-- pg_monitor for cross-role visibility -- so the consumer-priority signal needs no elevated role
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'pgpm' and p.prosrc ~* 'pg_stat_activity' and p.prosrc ~* 'wait_event'),
  0, 'no pgpm function depends on cross-role wait_event (pg_monitor) visibility');

-- and the old pg_monitor-dependent sensor is gone entirely
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'pgpm' and p.proname = '_ambient_io_waiters'),
  0, 'the pg_monitor-dependent _ambient_io_waiters() has been removed');

select * from finish();
rollback;

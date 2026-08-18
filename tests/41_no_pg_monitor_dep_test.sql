-- pgpm's only runtime dependency is pg_cron: no function needs an elevated role.
--
-- This began as a regression test for issue #98, when the adaptive ambient sensors were rewritten to read
-- pg_locks and pg_stat_database (visible to any role) instead of cross-role wait_event in
-- pg_stat_activity, which pg_monitor masks. Those sensors are gone with the closed loop they fed (#304),
-- so the two assertions that called them went with them. What survives is the claim that never depended on
-- them: NO pgpm function reads cross-role wait_event, whatever else changes.
create extension if not exists pgtap;

select plan(2);

-- the clincher: NO pgpm function reads wait_event from pg_stat_activity -- the one access that needs
-- pg_monitor for cross-role visibility -- so pgpm runs under a plain, unprivileged role
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'pgpm' and p.prosrc ~* 'pg_stat_activity' and p.prosrc ~* 'wait_event'),
  0, 'no pgpm function depends on cross-role wait_event (pg_monitor) visibility');

-- the whole ambient/feathering sensor family is gone, not merely unused: nothing emits the signal they
-- measured, so a retained sensor would report on a mechanism that no longer exists
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'pgpm'
       and (p.proname like '\_ambient%' or p.proname like '\_feather%'
            or p.proname in ('_wal_sustainable_bps', '_forced_checkpoints', '_aimd_next',
                             'feathering_validation'))),
  0, 'the adaptive-feathering sensor family is removed entirely');

select * from finish();

-- pg_flight_recorder correlation, PGFR PRESENT: impact_report correlates pgpm's window against
-- PGFR telemetry, and feathering_validation cross-checks each backoff reason against what PGFR
-- independently sampled. Requires a real vendored PGFR install (run by ./test.sh observe); the
-- PGFR-absent gate lives in the main suite (tests/65_observe_no_pgfr_test.sql). Determinism: we
-- replace the snapshot table with three synthetic rows so the checkpoint/WAL deltas are exact (no
-- reliance on cron or real checkpoints). One forced checkpoint occurs between the -4min and -1min
-- rows.
begin;
select plan(8);

create table public.t (id bigint);

-- Controlled snapshot timeline. ckpt_requested goes 10 -> 10 -> 11, so exactly one
-- forced checkpoint lands between -4min and -1min; wal_bytes climbs 1.0 -> 1.5 -> 4.0 MB.
delete from pgfr_record.snapshots;
insert into pgfr_record.snapshots
  (pg_version, captured_at, ckpt_timed, ckpt_requested, wal_bytes, temp_bytes, temp_files,
   ckpt_write_time, ckpt_sync_time, ckpt_buffers) values
  (150000, now() - interval '8 min', 5, 10, 1000000, 0, 0, 0, 0, 0),
  (150000, now() - interval '4 min', 5, 10, 1500000, 0, 0, 0, 0, 0),
  (150000, now() - interval '1 min', 5, 11, 4000000, 0, 0, 0, 0, 0);

-- pgpm operations spanning the window, with two 'wal' backoffs:
--   -5min tick is a PHANTOM (no forced checkpoint in its lead-up [-7,-5] => delta 0)
--   -2min tick is REAL    (the forced checkpoint is in its lead-up [-4,-2] => delta 1)
insert into pgpm.log (parent_table, action, rows, method, at) values
  ('public.t'::regclass, 'transmute',    null, null,             now() - interval '7 min'),
  ('public.t'::regclass, 'drain_move',   1000, null,             now() - interval '6 min'),
  ('public.t'::regclass, 'drain_budget', 2500, 'wal',            now() - interval '5 min'),
  ('public.t'::regclass, 'drain_budget', 1250, 'wal',            now() - interval '2 min'),
  ('public.t'::regclass, 'regrain',          1, 'copy_swap_drop', now() - interval '1.5 min');

select is( pgpm._observe_has_pgfr(), true,
           'PGFR present: _observe_has_pgfr() is true' );
select is( (select rows_moved from pgpm.observe_window('public.t'::regclass)), 1000::bigint,
           'observe_window: rows_moved' );
select is( (select wal_backoffs from pgpm.observe_window('public.t'::regclass)), 2::bigint,
           'observe_window: two wal backoffs' );

-- impact_report sections (ok() + the LIKE operator; pgTAP like() needs typed args).
select ok( pgpm.impact_report('public.t'::regclass) like '%impact report for%',
           'impact_report: has the header' );
select ok( pgpm.impact_report('public.t'::regclass) like '%forced checkpoints: 1%',
           'impact_report: reports the one forced checkpoint in the window' );
select ok( pgpm.impact_report('public.t'::regclass) like '%WAL generated:%',
           'impact_report: reports WAL generated' );

-- feathering_validation corroborates per tick, ordered by time: phantom then real.
select is( (select array_agg(wal_signal_confirmed order by tick_at)
              from pgpm.feathering_validation('public.t'::regclass)),
           array[false, true],
           'feathering_validation: phantom wal backoff unconfirmed, real one confirmed' );
select is( (select count(*) from pgpm.feathering_validation('public.t'::regclass)), 2::bigint,
           'feathering_validation: one row per backoff tick' );

select * from finish();
rollback;

-- pg_flight_recorder correlation, PGFR PRESENT: impact_report correlates pgpm's window against PGFR
-- telemetry. It also used to assert feathering_validation corroborated each backoff tick, seeded from
-- synthetic `drain_budget` rows -- input the system has not produced since #288 removed the drain and its
-- adaptive feathering, so those assertions tested the analyser against data manufactured for them. Both
-- the function and the assertions are gone (#304). Requires a real vendored PGFR install (run by
-- ./test.sh observe); the
-- PGFR-absent gate lives in the main suite (tests/65_observe_no_pgfr_test.sql). Determinism: we
-- replace the snapshot table with three synthetic rows so the checkpoint/WAL deltas are exact (no
-- reliance on cron or real checkpoints). One forced checkpoint occurs between the -4min and -1min
-- rows.
begin;
select plan(5);

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
insert into pgpm.log (parent_table, action, rows, method, at) values
  ('public.t'::regclass, 'transmute',    null, null,              now() - interval '7 min'),
  ('public.t'::regclass, 'regrain_copy', 1000, null,              now() - interval '6 min'),
  ('public.t'::regclass, 'regrain',         1, 'copy_swap_drop',  now() - interval '1.5 min');

select is( pgpm._observe_has_pgfr(), true,
           'PGFR present: _observe_has_pgfr() is true' );
select is( (select rows_copied from pgpm.observe_window('public.t'::regclass)), 1000::bigint,
           'observe_window: rows_copied' );

-- impact_report sections (ok() + the LIKE operator; pgTAP like() needs typed args).
select ok( pgpm.impact_report('public.t'::regclass) like '%impact report for%',
           'impact_report: has the header' );
select ok( pgpm.impact_report('public.t'::regclass) like '%forced checkpoints: 1%',
           'impact_report: reports the one forced checkpoint in the window' );
select ok( pgpm.impact_report('public.t'::regclass) like '%WAL generated:%',
           'impact_report: reports WAL generated' );


select * from finish();
rollback;

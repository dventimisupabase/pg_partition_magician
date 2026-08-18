-- pg_flight_recorder correlation, PGFR ABSENT (issue #157/observe fold): the pure-pgpm window
-- summary must work standalone, and the PGFR-delegating functions must refuse with a clear
-- pgpm-prefixed error (the "PGFR is never a dependency" contract). The PGFR-present correlation
-- itself needs a real vendored PGFR install and lives in its own track (tests/observe/,
-- ./test.sh observe).
create extension if not exists pgtap;

select plan(6);

create table public.t (id bigint);

-- A small synthetic operation log: a transmute, a regrain that copied rows, and a retention drop.
--
-- It used to seed `drain_move` and `drain_budget` rows too, and assert observe_window counted them. That
-- was the shape #304 removed: those actions have not been written since #288 took the drain and its
-- adaptive feathering, so the assertions proved the ANALYSER worked while manufacturing input the system
-- could no longer produce. A green suite said nothing about whether the feature existed.
insert into pgpm.log (parent_table, action, rows, method, at) values
  ('public.t'::regclass, 'transmute',    null, null,              now() - interval '5 min'),
  ('public.t'::regclass, 'regrain_copy', 1000, null,              now() - interval '4 min'),
  ('public.t'::regclass, 'regrain',         1, 'copy_swap_drop',  now() - interval '2 min'),
  ('public.t'::regclass, 'retain_drop',  null, null,              now() - interval '1 min');

select is( pgpm._observe_has_pgfr(), false,
           'PGFR absent: _observe_has_pgfr() is false' );

-- observe_window is pure pgpm.log and works with no PGFR.
select is( (select rows_copied from pgpm.observe_window('public.t'::regclass)), 1000::bigint,
           'observe_window: rows copied by a regrain are counted' );
select is( (select regrains from pgpm.observe_window('public.t'::regclass)), 1::bigint,
           'observe_window: the completed regrain is counted' );
select is( (select retains  from pgpm.observe_window('public.t'::regclass)), 1::bigint,
           'observe_window: the retention drop is counted' );

-- The PGFR-delegating function refuses cleanly (raises, SQLSTATE P0001).
select throws_ok( $$ select pgpm.impact_report('public.t'::regclass) $$, 'P0001',
                  null, 'impact_report refuses without PGFR' );

-- feathering_validation is gone with the signal it analysed (#304).
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pgpm' and p.proname = 'feathering_validation'),
  0, 'feathering_validation is removed, not merely inert' );

select * from finish();

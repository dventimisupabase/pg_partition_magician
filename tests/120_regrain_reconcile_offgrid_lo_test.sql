-- regrain's reconcile locates the fine child by RANGE, never by re-rendering its name (issue #446).
--
-- THE DEFECT. regrain_step clamps the first sub-range to the coarse child's own lo when that lo is off
-- the target grid (a 7000 target on a child starting at 20000; a weekly target on a monthly monolith,
-- which set_regrain accepts) and names the fine child from the clamped value: [20000, 21000) becomes
-- _p20000. _regrain_reconcile re-derived the sub-range from grid_floor(ctl) with no clamp, rendered
-- _p14000, found no such relation, took that for "skipped as aged", logged regrain_reconcile_aged and
-- DELETED the captured keys anyway. The swap then dropped the source: every UPDATE in that sub-range
-- reverted, every DELETE came back, every INSERT vanished.
--
-- The fixture in (A) is the issue's, and its DML is three-way asymmetric (one UPDATE, one DELETE, one
-- INSERT, all inside the clamped sub-range) so no two effects can cancel into a passing row count; every
-- assertion is by identity. Every negative ("no aged row", "20700 is absent") is paired with a witness
-- that the condition it denies was present: the lo really is off the target grid, the child the old
-- derivation would have looked for really does not exist, the delta really held the four captured keys,
-- and the reconcile really consumed them into the child the swap later attached.
--
-- (B) keeps the genuinely aged path: a captured key in a sub-range regrain_step skipped as aged is still
-- discarded and counted, because the decision is now made by the retention horizon, not by a relation's
-- absence. (C) is the other half of that: a missing child for a sub-range that is NOT aged raises and
-- keeps the key, rather than discarding it under the aged label. (D) shows the same two derivations
-- disagree on the time grid, which is why the lookup is by range for every control kind.
create extension if not exists pgtap;
set time zone 'UTC';
select plan(41);

-- drive regrain_step to the swap, one tick at a time, and return the swap's status
create or replace function pg_temp.finish_regrain(p_parent regclass, p_child name, p_step text, p_batch int)
returns text language plpgsql as $$
declare s text; n int := 0;
begin
  loop
    s := pgpm.regrain_step(p_parent, p_child, p_step, p_batch);
    exit when s like 'swapped:%';
    n := n + 1;
    if n > 200 then raise exception 'regrain did not converge (last status %)', s; end if;
  end loop;
  return s;
end $$;

-- ============ (A) the issue's fixture: coarse [20000, 60000) on a 10000 grid, regrained to 7000 ============
-- ids 20000, 20100, ..., 59900: sparse, so the clamped first sub-range [20000, 21000) has a free slot to
-- INSERT into (20050) and holds 10 rows, fewer than the batch, so one copy tick completes it.
create table public.rfa (id bigint primary key, payload text);
insert into public.rfa select 20000 + 100 * g, 'orig' from generate_series(0, 399) g;
call pgpm.transmute('public.rfa', 'id', 10000);
select pgpm.obtain('public.rfa');
insert into public.rfa values (65000, 'frontier');   -- past hi = 60000: the monolith is frozen

select is(
  (select child_name from pgpm.part where parent_table = 'public.rfa'::regclass and attached
    order by lo::numeric limit 1),
  'rfa_p0000000000000020000_to_0000000000000060000'::name,
  'GUARD: the monolith is [20000, 60000), as this file assumes');
select is(pgpm._grid_floor('id', '7000', '0', '20000', 'UTC'), '14000',
  'LIVENESS: 20000 is off the 7000 grid (its grid floor is 14000), so the first sub-range is clamped');

select is(pgpm.regrain_step('public.rfa', 'rfa_p0000000000000020000_to_0000000000000060000', '7000', 500),
  'prepared', 'tick 1 installs capture');
select is(pgpm.regrain_step('public.rfa', 'rfa_p0000000000000020000_to_0000000000000060000', '7000', 500),
  'copied:10', 'tick 2 copies the whole clamped first sub-range [20000, 21000): 10 rows');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rfa'::regclass), '21000',
  'and the cursor advances past it, so its keys are eligible for reconcile');
select is(
  (select child_name from pgpm.part where parent_table = 'public.rfa'::regclass and not attached and lo = '20000'),
  'rfa_p0000000000000020000'::name,
  'the fine child is named from the CLAMPED lo (20000, not the grid floor 14000)');
select is(
  (select hi from pgpm.part where parent_table = 'public.rfa'::regclass and child_name = 'rfa_p0000000000000020000'),
  '21000', 'and pgpm.part records its bounds as [20000, 21000)');
select ok(to_regclass('public.rfa_p0000000000000014000') is null,
  'LIVENESS: the child a grid-floor derivation would look for (_p14000) does not exist, and never will');

-- committed DML inside the already-copied, clamped sub-range: one UPDATE, one DELETE, one INSERT
update public.rfa set payload = 'updated' where id = 20600;
delete from public.rfa where id = 20700;
insert into public.rfa values (20050, 'inserted');
select is((select count(*)::int from public.rfa_pgpm_regrain_delta), 4,
  'LIVENESS: the delta holds the four captured keys (the UPDATE writes OLD and NEW; one DELETE; one INSERT)');

select is(pgpm.regrain_step('public.rfa', 'rfa_p0000000000000020000_to_0000000000000060000', '7000', 500),
  'reconciled:4', 'tick 3 reconciles them');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rfa'::regclass and action = 'regrain_reconcile_aged'),
  0, 'nothing was treated as aged: no regrain_reconcile_aged row (no retention policy, so no aged range exists)');
select is(
  (select rows from pgpm.log where parent_table = 'public.rfa'::regclass and action = 'regrain_reconcile'),
  4::bigint, 'WITNESS: the regrain_reconcile row says all 4 captured keys were consumed');
-- and they landed in the fine child the swap will attach, by identity, before the swap
select is((select payload from public.rfa_p0000000000000020000 where id = 20050), 'inserted',
  'before the swap: 20050 (the INSERT) is in the fine child with its payload');
select is((select payload from public.rfa_p0000000000000020000 where id = 20600), 'updated',
  'before the swap: 20600 carries the updated payload in the fine child');
select ok(not exists (select 1 from public.rfa_p0000000000000020000 where id = 20700),
  'before the swap: 20700 (the DELETE) is gone from the fine child');

select is(pg_temp.finish_regrain('public.rfa', 'rfa_p0000000000000020000_to_0000000000000060000', '7000', 500),
  'swapped:7', 'the regrain completes: 7 fine children ([20000,21000), 5 full 7000 ranges, [56000,60000))');

select is((select payload from public.rfa where id = 20050), 'inserted',
  'after the swap: 20050, inserted mid-regrain, is present with its payload');
select is((select payload from public.rfa where id = 20600), 'updated',
  'after the swap: 20600 carries the updated payload, not the original');
select ok(not exists (select 1 from public.rfa where id = 20700),
  'after the swap: 20700, deleted mid-regrain, stays deleted');
select is((select payload from public.rfa where id = 20500), 'orig',
  'control: an untouched neighbour in the same sub-range is still there with its original payload');
select is(
  (select c.relname from pg_inherits i join pg_class c on c.oid = i.inhrelid
    where i.inhparent = 'public.rfa'::regclass and c.relname = 'rfa_p0000000000000020000'),
  'rfa_p0000000000000020000'::name,
  'WITNESS: the attached fine child is the one pgpm.part recorded, by name');
select is(
  (select child_oid from pgpm.part where parent_table = 'public.rfa'::regclass and child_name = 'rfa_p0000000000000020000'),
  'public.rfa_p0000000000000020000'::regclass::oid,
  'and by oid: pgpm.part.child_oid is the attached relation');
select ok(
  (select attached from pgpm.part where parent_table = 'public.rfa'::regclass and child_name = 'rfa_p0000000000000020000'),
  'and pgpm.part marks it attached');
select is((select count(*)::int from public.rfa), 401,
  'row count: 400 originals, minus the DELETE, plus the INSERT, plus the frontier row');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rfa'::regclass and action = 'regrain_reconcile_aged'),
  0, 'still no regrain_reconcile_aged row after the swap''s residual reconcile');

-- ============ (B) the genuinely aged path is kept: decided by the horizon, not by a missing relation ============
-- retain 900 against a frontier of 1000: the horizon is 100, so [0, 50) and [50, 100) are aged and
-- regrain_step advances over them without materializing a child (tests/106 pins that skip). A backdated
-- change into one of them has nowhere to land and goes with the source at the swap: discarded, counted.
create table public.rfb (id bigint primary key, payload text);
insert into public.rfb select g, 'x' from generate_series(1, 200) g;
call pgpm.transmute('public.rfb', 'id', 50, p_retain => 900);
select pgpm.obtain('public.rfb');
insert into public.rfb values (1000, 'frontier');

select is(pgpm.regrain_step('public.rfb', 'rfb_p0000000000000000000_to_0000000000000000250', '50', 30),
  'prepared', 'aged: tick 1 installs capture');
select is(pgpm.regrain_step('public.rfb', 'rfb_p0000000000000000000_to_0000000000000000250', '50', 30),
  'copied:30', 'aged: tick 2 advances over the aged sub-ranges and copies the first batch of [100, 150)');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rfb'::regclass and action = 'regrain_aged'),
  2, 'LIVENESS: two sub-ranges ([0, 50) and [50, 100)) were skipped as aged, so no child exists for them');

delete from public.rfb where id = 10;   -- a backdated change in [0, 50): captured, eligible (10 < cursor 100)
select is((select count(*)::int from public.rfb_pgpm_regrain_delta), 1,
  'LIVENESS: the backdated DELETE is captured');
select is(pgpm.regrain_step('public.rfb', 'rfb_p0000000000000000000_to_0000000000000000250', '50', 30),
  'reconciled:1', 'aged: tick 3 consumes it');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rfb'::regclass
    and action = 'regrain_reconcile_aged' and lo = '0' and hi = '50'),
  1, 'and says so: one regrain_reconcile_aged row naming the aged sub-range [0, 50) the key fell in');
select is((select count(*)::int from public.rfb_pgpm_regrain_delta), 0,
  'the delta is clear: the key was consumed, not left to wedge the swap gate');

-- ============ (C) a missing child for a sub-range that is NOT aged raises, and keeps the key ============
-- The one legitimate reason for a sub-range to have no fine child is that regrain_step skipped it as aged.
-- Anything else is captured DML with nowhere to land, and discarding it under the aged label is the data
-- loss (A) is about. Induce it: the copied fine child for [0, 100) disappears out from under pgpm.
create table public.rfc (id bigint primary key, payload text);
insert into public.rfc select g * 10, 'x' from generate_series(1, 250) g;   -- 10, 20, ..., 2500
call pgpm.transmute('public.rfc', 'id', 1000);
select pgpm.obtain('public.rfc');
insert into public.rfc values (20000, 'frontier');

select is(pgpm.regrain_step('public.rfc', 'rfc_p0000000000000000000_to_0000000000000003000', '100', 50),
  'prepared', 'not aged: tick 1 installs capture');
select is(pgpm.regrain_step('public.rfc', 'rfc_p0000000000000000000_to_0000000000000003000', '100', 50),
  'copied:9', 'not aged: tick 2 copies [0, 100), ids 10..90, and the cursor moves to 100');
drop table public.rfc_p0000000000000000000;
delete from pgpm.part where parent_table = 'public.rfc'::regclass and child_name = 'rfc_p0000000000000000000';
delete from public.rfc where id = 20;   -- captured, eligible (20 < cursor 100), and with nowhere to land
select is((select count(*)::int from public.rfc_pgpm_regrain_delta), 1,
  'LIVENESS: the change is captured, in a sub-range that is below the cursor and NOT below any horizon');

select throws_like(
  $$ select pgpm.regrain_step('public.rfc', 'rfc_p0000000000000000000_to_0000000000000003000', '100', 50) $$,
  'pg_partition_magician: internal error reconciling%no fine child%not below the retention horizon%',
  'the tick refuses: a missing child for a sub-range that is not aged is not an aged range');
select is((select count(*)::int from public.rfc_pgpm_regrain_delta), 1,
  'and the captured key is still in the delta: nothing was discarded');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rfc'::regclass and action = 'regrain_reconcile_aged'),
  0, 'and it was not logged as aged');

-- ============ (D) the time grid has the same hazard: a monthly monolith regrained weekly ============
-- The clamped first sub-range of a child starting 2024-03-01 on a weekly grid anchored at 2000-01-01 is
-- [2024-03-01, 2024-03-02), and regrain_step names it from the clamped lo. A name derived from the grid
-- floor alone is a different child that never exists. This is why the lookup is by range for every kind.
select is(pgpm._grid_floor('time', '1 week', '2000-01-01 00:00:00+00', '2024-03-01 00:00:00+00', 'UTC')::timestamptz,
  '2024-02-24 00:00:00+00'::timestamptz,
  'time: 2024-03-01 is off the weekly grid (its grid floor is 2024-02-24), so the first sub-range is clamped');
select is(pgpm._part_name('rfh', 'time', '1 week', '2024-03-01 00:00:00+00', '2024-03-02 00:00:00+00', 'UTC'),
  'rfh_p2024_03_01'::name,
  'time: regrain_step names the clamped first sub-range [2024-03-01, 2024-03-02) rfh_p2024_03_01');
select is(pgpm._part_name('rfh', 'time', '1 week', '2024-02-24 00:00:00+00', '2024-03-02 00:00:00+00', 'UTC'),
  'rfh_p2024_02_24'::name,
  'time: a grid-floor derivation renders rfh_p2024_02_24, a child that never exists: the two disagree');

select * from finish();

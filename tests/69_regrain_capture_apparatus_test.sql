-- The change-capture apparatus behind regrain's reconcile (issue #267). tests/68 pins the CONTRACT, which
-- any correct implementation must satisfy however it is built; this file pins the specific design, so it
-- is the one to change if the mechanism is ever replaced.
--
-- Shape under test: the delta table and its trigger function are PER PARENT and persistent, named from the
-- parent (stable -- naming from the child would break, since #266's fix renames the source mid-flight);
-- only the trigger on the source child is per regrain. Lifecycle therefore reduces to rows, not relations.
create extension if not exists pgtap;
select plan(15);

create or replace function pg_temp.mk(p_rel text) returns void language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_rel);
  execute format('insert into public.%I select g*10, ''x'' from generate_series(1, 250) g', p_rel);
  perform pgpm.transmute(format('public.%I', p_rel)::regclass, 'id', 1000);
  execute format('insert into public.%I values (900000, ''frontier'')', p_rel);
end $$;

-- ======================= the prepare tick =======================
-- Capture must be installed and committed before ANY copy reads the source, or changes made during the
-- first batch are lost. It gets its own tick so CREATE TRIGGER's SHARE ROW EXCLUSIVE is an O(1) hold
-- rather than one spanning a copy batch.
select pg_temp.mk('ca1');

select is(
  pgpm.regrain_step('public.ca1','ca1_p0000000000000000000_to_0000000000000003000','100',50),
  'prepared', 'the first tick prepares: it installs capture and copies nothing');

select ok(
  pgpm._regrain_capture_active('public.ca1', 'ca1_p0000000000000000000_to_0000000000000003000'),
  'the source child carries the capture trigger after the prepare tick');

select ok(
  to_regclass('public.ca1_pgpm_regrain_delta') is not null,
  'the per-parent delta table exists, named from the parent (not the child, which can be renamed)');

select is(
  (select regrain_cursor from pgpm.config where parent_table = 'public.ca1'::regclass), '0',
  'prepare also sets the cursor, so "cursor null => no child carries capture" holds from tick one');

select ok(
  pgpm.regrain_step('public.ca1','ca1_p0000000000000000000_to_0000000000000003000','100',50) like 'copied:%',
  'the second tick copies');

-- ======================= capture has no gap =======================
-- A change committed between the prepare tick and the first copy is still reconciled. CREATE TRIGGER takes
-- SHARE ROW EXCLUSIVE, which conflicts with ROW EXCLUSIVE, so nothing can slip past uncaptured.
select pg_temp.mk('ca2');
select pgpm.regrain_step('public.ca2','ca2_p0000000000000000000_to_0000000000000003000','100',50);  -- prepared
delete from public.ca2 where id = 20;                                        -- after prepare, before any copy

select cmp_ok(
  (select count(*) from public.ca2_pgpm_regrain_delta), '>', 0::bigint,
  'a change made after prepare but before the first copy is captured');

do $$ declare s text; n int := 0; begin
  loop s := pgpm.regrain_step('public.ca2','ca2_p0000000000000000000_to_0000000000000003000','100',50);
    exit when s like 'swapped:%'; n := n + 1; if n > 500 then raise exception 'no convergence'; end if; end loop;
end $$;

select ok(not exists(select 1 from public.ca2 where id = 20),
  'and it is honoured: the row deleted in the prepare/copy gap stays deleted');

select is((select count(*) from public.ca2_pgpm_regrain_delta), 0::bigint,
  'the delta is cleared at the swap, so status shows no phantom backlog');

-- ======================= the janitor reaps an abandoned regrain =======================
-- Turning auto-regrain off mid-flight leaves capture installed with nobody reconciling it. maintain's
-- per-tick sweep tears it down, exactly as _enforce_write_blocks does for write blocks.
select pg_temp.mk('ca3');
select pgpm.set_regrain('public.ca3', '100');
select pgpm.regrain_step('public.ca3','ca3_p0000000000000000000_to_0000000000000003000','100',50);
select pgpm.regrain_step('public.ca3','ca3_p0000000000000000000_to_0000000000000003000','100',50);
update pgpm.config set regrain_cursor = null where parent_table = 'public.ca3'::regclass;   -- abandoned
select pgpm._enforce_regrain_capture('public.ca3');

select ok(
  not pgpm._regrain_capture_active('public.ca3', 'ca3_p0000000000000000000_to_0000000000000003000'),
  'the janitor removes capture left by an abandoned regrain');

select cmp_ok(
  (select count(*) from pgpm.log
    where parent_table = 'public.ca3'::regclass and action = 'regrain_capture_orphan'),
  '>', 0::bigint, 'and says so in pgpm.log rather than doing it silently');

-- ======================= regrain_cancel =======================
-- The operator's deliberate escape. It must DROP the in-flight copies: keeping them would let a later
-- regrain resume from copies made before the cancel and therefore never reconciled, which is this bug.
select pg_temp.mk('ca4');
select pgpm.regrain_step('public.ca4','ca4_p0000000000000000000_to_0000000000000003000','100',50);
select pgpm.regrain_step('public.ca4','ca4_p0000000000000000000_to_0000000000000003000','100',50);
select pgpm.regrain_cancel('public.ca4');

select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.ca4'::regclass and not attached),
  0, 'regrain_cancel drops every in-flight copy: none may survive to be resumed from');

select is((select count(*)::int from public.ca4), 251,
  'and the parent is untouched: the source still holds every row');

-- ======================= one regrain per parent =======================
-- config.regrain_cursor and the change-capture delta are both PER PARENT, so a second concurrent regrain
-- would reset the first one's cursor and truncate its delta at prepare, discarding captured changes it had
-- not applied yet. That is the same class of loss this apparatus exists to prevent, so it is refused.
create table public.ca5 (id bigint primary key, payload text);
insert into public.ca5 select g, 'x' from generate_series(1, 2500) g;
select pgpm.transmute('public.ca5', 'id', 1000, p_obtain => 3);
select pgpm.obtain('public.ca5');
insert into public.ca5 values (900000, 'frontier');
select pgpm.regrain_step('public.ca5','ca5_p0000000000000000000_to_0000000000000003000','100',500);
select pgpm.regrain_step('public.ca5','ca5_p0000000000000000000_to_0000000000000003000','100',500);

select throws_ok(
  $$ select pgpm.regrain_step('public.ca5','ca5_p0000000000000003000','100',500) $$,
  'P0001', NULL, 'a second regrain on another child of the same parent is refused');

select ok(
  exists(select 1 from pgpm.part
          where parent_table = 'public.ca5'::regclass and child_name = 'ca5_p0000000000000003000'),
  'and the refusal mutates nothing: the refused child is not even renamed');

select ok(
  pgpm._regrain_capture_active('public.ca5', 'ca5_p0000000000000000000_to_0000000000000003000'),
  'the in-flight regrain keeps its capture: the refused one did not disturb it');

select * from finish();

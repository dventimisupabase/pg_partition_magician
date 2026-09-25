-- Turning auto-regrain off mid-flight abandons the run it started (issue #516).
--
-- set_regrain(parent, null) used to write regrain_to and nothing else. maintain dispatches regrain_step
-- only while regrain_to is set, so the run in flight was never driven again, and _enforce_regrain_capture
-- keeps capture on the child whose range covers config.regrain_cursor, which nothing cleared, so it was
-- never swept either. The capture trigger kept taxing every write into the source and filling a delta
-- nobody drained, the not-yet-attached copies stayed on disk, and TRUNCATE of the parent stayed refused as
-- "a regrain is in flight", indefinitely, until the operator found regrain_cancel. The reference promised
-- maintain would sweep it; the runbook promised the run would complete; the code did neither.
--
-- Now set_regrain(parent, null), when it actually turns auto-regrain OFF (regrain_to was set) and a regrain
-- is in flight, abandons that run through regrain_cancel, the one teardown path: capture trigger and
-- TRUNCATE guard off every child, delta cleared, copies dropped with their part rows, cursor null, one
-- regrain_cancel log row. The source child still holds every row, so only the copy work is lost. A call
-- that finds auto-regrain already off changes nothing, so it cannot cancel an operator-driven regrain.
--
-- Every negative below ("no capture", "no copies", "nothing logged") is paired with a witness that the
-- thing was really there, or really in flight, first. Rows are asserted by WHICH ids are present.
create extension if not exists pgtap;

select plan(44);

-- ======================================================================================================
-- (A) auto-regrain on and mid-flight; turning it off abandons the run (F3-05, F9-05)
-- ======================================================================================================
create table public.sro (id bigint primary key, payload text);
insert into public.sro select g*10, 'x' from generate_series(1, 299) g;        -- ids 10..2990, monolith [0,3000)
call pgpm.transmute('public.sro', 'id', 1000, p_regrain_batch => 50);
insert into public.sro values (20000, 'frontier');                             -- the monolith is frozen
select pgpm.set_regrain('public.sro', '100');
select pgpm.resume('public.sro');
call pgpm.maintain('public.sro');    -- prepare: installs capture, copies nothing
call pgpm.maintain('public.sro');    -- one copy microbatch: [0,100) holds 9 rows < 50, so the sub-range completes
select child_name as mon from pgpm.part
 where parent_table = 'public.sro'::regclass and attached order by lo::numeric limit 1 \gset

select is((select regrain_to from pgpm.config where parent_table = 'public.sro'::regclass), '100',
  'LIVENESS (A): auto-regrain is on');
select ok(pgpm._regrain_capture_active('public.sro', :'mon'),
  'LIVENESS (A): capture is installed on the source');
select is(
  (select array_agg(tgname::text order by tgname) from pg_trigger
    where tgrelid = format('public.%I', :'mon')::regclass and not tgisinternal),
  array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
  'LIVENESS (A): the capture trigger and the TRUNCATE guard both sit on the source');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.sro'::regclass), '100',
  'LIVENESS (A): the cursor sits at the end of the first copied sub-range: the run is in flight');
select is(
  (select array_agg(action order by id) from pgpm.log
    where parent_table = 'public.sro'::regclass and action in ('regrain_prepare', 'regrain_copy')),
  array['regrain_prepare', 'regrain_copy'],
  'LIVENESS (A): one prepare tick and one copy tick ran');
select is(
  (select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
    where parent_table = 'public.sro'::regclass and not attached),
  array['0-100'],
  'LIVENESS (A): exactly one not-yet-attached fine copy is recorded, for the first sub-range');
select child_name as copy_a from pgpm.part where parent_table = 'public.sro'::regclass and not attached \gset
select isnt(to_regclass(format('public.%I', :'copy_a')), null,
  'LIVENESS (A): and it is a real relation on disk');
update public.sro set payload = 'y' where id = 10;                             -- a change the trigger sees
select is(pgpm._regrain_delta_count('public.sro'), 2::bigint,
  'LIVENESS (A): the capture trigger is live: the update landed old + new in the delta');
select throws_like($$ truncate public.sro $$, '%a regrain is in flight%',
  'LIVENESS (A): while the run is in flight, TRUNCATE of the parent is refused');

select lives_ok($$ select pgpm.set_regrain('public.sro', null) $$,
  '(A) set_regrain(null) mid-flight goes through');

select is((select regrain_to from pgpm.config where parent_table = 'public.sro'::regclass), null,
  '(A) auto-regrain is off');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.sro'::regclass), null,
  '(A) the cursor is cleared: no run is in flight');
select is(
  (select coalesce(array_agg(p.child_name::text order by p.child_name), '{}') from pgpm.part p
    where p.parent_table = 'public.sro'::regclass and pgpm._regrain_capture_active('public.sro', p.child_name)),
  '{}'::text[],
  '(A) no child of the parent carries capture');
select is(
  (select coalesce(array_agg(tgname::text order by tgname), '{}') from pg_trigger
    where tgrelid = format('public.%I', :'mon')::regclass and not tgisinternal),
  '{}'::text[],
  '(A) the source carries neither the capture trigger nor the TRUNCATE guard');
select is(
  (select coalesce(array_agg(child_name::text order by child_name), '{}') from pgpm.part
    where parent_table = 'public.sro'::regclass and not attached),
  '{}'::text[],
  '(A) no not-yet-attached copy is recorded');
select is(to_regclass(format('public.%I', :'copy_a')), null,
  '(A) and the copy relation is gone from disk: the transient space is back');
select is(pgpm._regrain_delta_count('public.sro'), 0::bigint,
  '(A) the delta is cleared');
select is(
  (select array_agg(action order by id) from pgpm.log
    where parent_table = 'public.sro'::regclass and action in ('regrain_cancel', 'regrain_capture_orphan')),
  array['regrain_cancel'],
  '(A) the abandonment is on the record as regrain_cancel, exactly once, and not as a janitor sweep');
select is((select rows from pgpm.log where parent_table = 'public.sro'::regclass and action = 'regrain_cancel'), 1::bigint,
  '(A) and it reports the one copy it dropped');
select is(
  (select array_agg(id order by id) from public.sro),
  (select array_agg(x order by x) from (select (g*10)::bigint from generate_series(1, 299) g union all select 20000::bigint) t(x)),
  '(A) the parent still holds exactly its 300 rows: the source was never touched');
select is((select payload from public.sro where id = 10), 'y',
  '(A) including the change made mid-flight, which lives in the source');

-- maintain keeps ticking with auto-regrain off: the run must neither restart nor be swept again
select max(id) as after_cancel from pgpm.log where parent_table = 'public.sro'::regclass \gset
call pgpm.maintain('public.sro');
call pgpm.maintain('public.sro');
call pgpm.maintain('public.sro');
select is(
  (select coalesce(array_agg(action order by id), '{}') from pgpm.log
    where parent_table = 'public.sro'::regclass and id > :after_cancel
      and action in ('regrain_prepare', 'regrain_copy', 'regrain_reconcile', 'regrain_capture_orphan', 'regrain_cancel', 'skip_regrain')),
  '{}'::text[],
  '(A) three later ticks did no regrain work and swept nothing: there was nothing left to do');
select ok(not pgpm._regrain_capture_active('public.sro', :'mon'),
  '(A) capture is still off after the ticks');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.sro'::regclass), null,
  '(A) and the cursor is still clear');
select lives_ok($$ truncate public.sro $$,
  '(A) TRUNCATE of the parent is no longer refused: nothing is in flight');

-- ======================================================================================================
-- (B) turning auto-regrain off with nothing in flight cancels nothing and logs nothing
-- ======================================================================================================
create table public.sro2 (id bigint primary key, payload text);
insert into public.sro2 select g, 'b' || g from generate_series(1, 7) g;
call pgpm.transmute('public.sro2', 'id', 1000);
select pgpm.set_regrain('public.sro2', '100');

select is((select regrain_to from pgpm.config where parent_table = 'public.sro2'::regclass), '100',
  'LIVENESS (B): auto-regrain is on');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.sro2'::regclass), null,
  'LIVENESS (B): but no run is in flight (no tick has run)');
select is(
  (select coalesce(array_agg(p.child_name::text order by p.child_name), '{}') from pgpm.part p
    where p.parent_table = 'public.sro2'::regclass and pgpm._regrain_capture_active('public.sro2', p.child_name)),
  '{}'::text[],
  'LIVENESS (B): and no child carries capture');

select lives_ok($$ select pgpm.set_regrain('public.sro2', null) $$,
  '(B) set_regrain(null) with nothing in flight goes through');
select is((select regrain_to from pgpm.config where parent_table = 'public.sro2'::regclass), null,
  '(B) auto-regrain is off');
select is(
  (select coalesce(array_agg(action order by id), '{}') from pgpm.log
    where parent_table = 'public.sro2'::regclass and action in ('regrain_cancel', 'regrain_capture_orphan')),
  '{}'::text[],
  '(B) and nothing was cancelled or swept: no regrain_cancel row for a run that never existed');

-- ======================================================================================================
-- (C) auto-regrain already off; an operator-driven regrain is in flight; the call leaves it alone
-- ======================================================================================================
create table public.sro3 (id bigint primary key, payload text);
insert into public.sro3 select g*10, 'x' from generate_series(1, 299) g;
call pgpm.transmute('public.sro3', 'id', 1000, p_regrain_batch => 50);
insert into public.sro3 values (20000, 'frontier');
select child_name as mon3 from pgpm.part
 where parent_table = 'public.sro3'::regclass and attached order by lo::numeric limit 1 \gset

select is((select regrain_to from pgpm.config where parent_table = 'public.sro3'::regclass), null,
  'LIVENESS (C): auto-regrain is off');
select is(pgpm.regrain_step('public.sro3', :'mon3', '100', 50), 'prepared',
  'LIVENESS (C): an operator-driven regrain installs capture');
-- #266 may have renamed the source to its transitional name; re-read it
select child_name as mon3 from pgpm.part
 where parent_table = 'public.sro3'::regclass and attached order by lo::numeric limit 1 \gset
select is(pgpm.regrain_step('public.sro3', :'mon3', '100', 50), 'copied:9',
  'LIVENESS (C): and copies its first sub-range: the run is in flight');
select ok(pgpm._regrain_capture_active('public.sro3', :'mon3'),
  'LIVENESS (C): capture is on the source');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.sro3'::regclass), '100',
  'LIVENESS (C): the cursor marks the run in flight');

select lives_ok($$ select pgpm.set_regrain('public.sro3', null) $$,
  '(C) set_regrain(null) with auto-regrain already off goes through');

select ok(pgpm._regrain_capture_active('public.sro3', :'mon3'),
  '(C) the operator''s run keeps its capture: a call that turned nothing off cancelled nothing');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.sro3'::regclass), '100',
  '(C) its cursor is untouched');
select is(
  (select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
    where parent_table = 'public.sro3'::regclass and not attached),
  array['0-100'],
  '(C) its copy is still recorded');
select is(
  (select coalesce(array_agg(action order by id), '{}') from pgpm.log
    where parent_table = 'public.sro3'::regclass and action in ('regrain_cancel', 'regrain_capture_orphan')),
  '{}'::text[],
  '(C) and no regrain_cancel row was written against it');
select is(pgpm.regrain('public.sro3', :'mon3', '100'), 30,
  '(C) the operator''s run then completes: the monolith swaps into 30 fine children');
select is(
  (select array_agg(lo::numeric order by lo::numeric) from pgpm.part
    where parent_table = 'public.sro3'::regclass and attached and hi::numeric <= 3000),
  (select array_agg((g*100)::numeric) from generate_series(0, 29) g),
  '(C) exactly the 30 fine children [0,100) .. [2900,3000) are attached where the monolith was');
select is(
  (select array_agg(id order by id) from public.sro3),
  (select array_agg(x order by x) from (select (g*10)::bigint from generate_series(1, 299) g union all select 20000::bigint) t(x)),
  '(C) and the parent holds exactly its 300 rows after the swap');

select * from finish();

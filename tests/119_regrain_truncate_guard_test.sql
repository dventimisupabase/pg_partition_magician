-- TRUNCATE during a regrain is refused (issue #449).
--
-- Change capture is an AFTER ... FOR EACH ROW trigger on the source child (tests/69). TRUNCATE fires no
-- row trigger, so a truncate of the source mid-regrain leaves the delta empty, and TRUNCATE parent never
-- reaches the standalone copies (they are not partitions until the swap). The swap then attaches copies of
-- every row the operator just removed: 9,999 rows back from the dead in the hunt that found this.
--
-- Rather than capture it, pgpm refuses it: a BEFORE TRUNCATE statement trigger on the source child,
-- installed and removed alongside the row trigger, raises while the regrain is in flight. BEFORE, so the
-- whole statement fails before anything is truncated. TRUNCATE parent cascades to the source as a
-- partition and fires the partition's own statement trigger, so both spellings are refused. ENABLE
-- ALWAYS, so session_replication_role = replica cannot skip it. Every refusal below is paired with the
-- witness that the condition it denies was present: the copy child held rows a swap would have
-- resurrected, and the source held the rows a truncate would have removed.
create extension if not exists pgtap;
select plan(26);

-- a PROCEDURE, not a function: it calls transmute, which commits
create or replace procedure pg_temp.mk(p_rel text) language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_rel);
  execute format('insert into public.%I select g*10, ''x'' from generate_series(1, 250) g', p_rel);
  call pgpm.transmute(format('public.%I', p_rel)::regclass, 'id', 1000);
  execute format('insert into public.%I values (20000, ''frontier'')', p_rel);   -- sentinel past hi: frozen
end $$;

-- ======================= (A) the guard is live while a regrain is in flight =======================
call pg_temp.mk('tg');

select is(pgpm.regrain_step('public.tg', 'tg_p0000000000000000000_to_0000000000000003000', '100', 50),
  'prepared', 'tick 1 installs capture (prepared)');
select is(pgpm.regrain_step('public.tg', 'tg_p0000000000000000000_to_0000000000000003000', '100', 50),
  'copied:9', 'tick 2 copies [0, 100): the nine rows 10..90');

select child_name as copy1 from pgpm.part
  where parent_table = 'public.tg'::regclass and not attached \gset
select is(:'copy1'::text, 'tg_p0000000000000000000'::text,
  'GUARD: the first fine child is named as this file assumes');

select is((select array_agg(id order by id) from public.tg_p0000000000000000000),
  (select array_agg((g*10)::bigint order by g) from generate_series(1, 9) g),
  'WITNESS: the copy holds ids 10..90, so there are copied rows for a swap to resurrect');
select is((select array_agg(id order by id) from public.tg_p0000000000000000000_to_0000000000000003000),
  (select array_agg((g*10)::bigint order by g) from generate_series(1, 250) g),
  'WITNESS: the source holds ids 10..2500 before the truncate');

select is(
  (select pg_get_triggerdef(t.oid) from pg_trigger t
    where t.tgrelid = 'public.tg_p0000000000000000000_to_0000000000000003000'::regclass
      and t.tgname = 'pgpm_regrain_truncate_guard'),
  'CREATE TRIGGER pgpm_regrain_truncate_guard BEFORE TRUNCATE ON public.tg_p0000000000000000000_to_0000000000000003000 FOR EACH STATEMENT EXECUTE FUNCTION pgpm._regrain_truncate_guard()',
  'the prepare tick installs a BEFORE TRUNCATE statement trigger on the source beside the row trigger');
select is(
  (select t.tgenabled from pg_trigger t
    where t.tgrelid = 'public.tg_p0000000000000000000_to_0000000000000003000'::regclass
      and t.tgname = 'pgpm_regrain_truncate_guard'),
  'A', 'and it is ENABLE ALWAYS');

select throws_like(
  $$ truncate public.tg $$,
  'pg_partition_magician: cannot TRUNCATE public.tg_p0000000000000000000_to_0000000000000003000 -- a regrain is in flight on it%pgpm.regrain_cancel(%tg)%',
  'TRUNCATE parent is refused: it cascades to the source as a partition and the guard fires there, naming the source and the parent to cancel');
select throws_like(
  $$ truncate public.tg_p0000000000000000000_to_0000000000000003000 $$,
  'pg_partition_magician: cannot TRUNCATE public.tg_p0000000000000000000_to_0000000000000003000 -- a regrain is in flight on it%pgpm.regrain_cancel(%tg)%',
  'TRUNCATE of the source child directly is refused the same way');

-- ENABLE ALWAYS is what makes this one hold: an ordinary trigger is skipped in replica mode, and a truncate
-- that slipped past there would be the same resurrection.
set session_replication_role = replica;
select throws_like(
  $$ truncate public.tg $$,
  'pg_partition_magician: cannot TRUNCATE public.tg_p0000000000000000000_to_0000000000000003000 -- a regrain is in flight on it%',
  'the refusal survives session_replication_role = replica');
reset session_replication_role;

select is((select array_agg(id order by id) from public.tg_p0000000000000000000_to_0000000000000003000),
  (select array_agg((g*10)::bigint order by g) from generate_series(1, 250) g),
  'nothing was truncated: the source still holds ids 10..2500 (the guard is BEFORE, not AFTER)');
select is((select array_agg(id order by id) from public.tg_p0000000000000000000),
  (select array_agg((g*10)::bigint order by g) from generate_series(1, 9) g),
  'and the copy is untouched');

-- ======================= (B) regrain_cancel lifts the refusal =======================
select is(pgpm.regrain_cancel('public.tg'), 1, 'regrain_cancel drops the one in-flight copy');
select is((select count(*)::int from pg_trigger where tgname = 'pgpm_regrain_truncate_guard'), 0,
  'and removes the TRUNCATE guard with the row trigger: none remains anywhere');
select lives_ok($$ truncate public.tg $$, 'so TRUNCATE parent succeeds once the regrain is cancelled');
select ok(not exists (select 1 from public.tg), 'and it truncated: the parent is empty');

-- ======================= (C) a completed regrain lifts it too =======================
call pg_temp.mk('tg2');
select is(pgpm.regrain_step('public.tg2', 'tg2_p0000000000000000000_to_0000000000000003000', '100', 50),
  'prepared', 'tg2: tick 1 prepared');
select ok(exists (select 1 from pg_trigger t
    where t.tgrelid = 'public.tg2_p0000000000000000000_to_0000000000000003000'::regclass
      and t.tgname = 'pgpm_regrain_truncate_guard'),
  'WITNESS: tg2''s source carries the guard while the regrain is in flight');

do $$ declare s text; n int := 0; begin
  loop s := pgpm.regrain_step('public.tg2', 'tg2_p0000000000000000000_to_0000000000000003000', '100', 50);
    exit when s like 'swapped:%'; n := n + 1; if n > 500 then raise exception 'no convergence'; end if; end loop;
end $$;

select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.tg2'::regclass
     and action = 'regrain' and method = 'copy_swap_drop'),
  1, 'WITNESS: the swap ran (one regrain / copy_swap_drop row)');
select is((select count(*)::int from pg_trigger where tgname = 'pgpm_regrain_truncate_guard'), 0,
  'after the swap no guard remains anywhere: it went with the dropped source');
select lives_ok($$ truncate public.tg2 $$, 'TRUNCATE parent succeeds after a completed regrain');
select ok(not exists (select 1 from public.tg2), 'and it truncated: the parent is empty');

-- ======================= (D) the janitor reaps the guard with the row trigger =======================
-- An abandoned regrain (cursor nulled mid-flight) leaves capture installed with nobody reconciling it;
-- maintain's per-tick sweep tears it down (tests/69), and the guard must go with it, or the table would
-- refuse TRUNCATE forever with no regrain to protect.
call pg_temp.mk('tg3');
select pgpm.regrain_step('public.tg3', 'tg3_p0000000000000000000_to_0000000000000003000', '100', 50);
select pgpm.regrain_step('public.tg3', 'tg3_p0000000000000000000_to_0000000000000003000', '100', 50);
select ok(exists (select 1 from pg_trigger t
    where t.tgrelid = 'public.tg3_p0000000000000000000_to_0000000000000003000'::regclass
      and t.tgname = 'pgpm_regrain_truncate_guard'),
  'WITNESS: tg3''s source carries the guard before the abandonment');
update pgpm.config set regrain_cursor = null where parent_table = 'public.tg3'::regclass;   -- abandoned
select pgpm._enforce_regrain_capture('public.tg3');

select ok(not pgpm._regrain_capture_active('public.tg3', 'tg3_p0000000000000000000_to_0000000000000003000'),
  'the janitor removed the row trigger');
select is((select count(*)::int from pg_trigger t
    where t.tgrelid = 'public.tg3_p0000000000000000000_to_0000000000000003000'::regclass
      and t.tgname = 'pgpm_regrain_truncate_guard'),
  0, 'and the TRUNCATE guard with it');
select lives_ok($$ truncate public.tg3 $$, 'so TRUNCATE succeeds on the reaped table');

select * from finish();

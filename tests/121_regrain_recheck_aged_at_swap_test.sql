-- regrain's aged-skip decision is re-checked at the swap, and never fires on a sub-range that already has
-- a fine child (issue #448).
--
-- As the cursor passes a sub-range entirely below the retention horizon, regrain_step skips it
-- (regrain_aged) and advances; the decision used to survive only as the advanced cursor. Two things
-- then went wrong, one per section below.
--
--   (a) Retention loosened mid-regrain. set_retain(parent, null) before the swap: the policy now says
--       keep, the rows are still visible through the attached source, and the swap's DROP took them
--       (39,999 rows in the hunt that found this). The swap now walks every sub-range of the source on
--       the target grid and REFUSES, naming the range, when one that will not be attached is no longer
--       below the current horizon. The source stays attached and the run stays resumable: put retain
--       back and the next tick swaps.
--   (b) A sub-range partially copied in tick N whose range ages before tick N+1. The skip fired on it
--       anyway, and the swap attached its half-full child. The skip now never fires on a sub-range that
--       already has a fine child: the copy is finished instead, and the partition is attached whole.
--
-- Every negative here is paired with a witness that the condition it denies was present: the
-- regrain_aged rows for the ranges in question, the child's row count mid-copy, the horizon's position.
create extension if not exists pgtap;
select plan(37);

-- ==================== (a) retain loosened after four sub-ranges were skipped as aged ====================
-- 1000 rows over a step of 250: monolith [0, 1250), five sub-ranges. Frontier sentinel 5000 with retain
-- 4000 puts the horizon at 1000, so [0, 250) .. [750, 1000) are aged and only [1000, 1250) is copied.
create table public.rl121 (id bigint primary key, payload text);
insert into public.rl121 select g, 'x' from generate_series(1, 1000) g;
call pgpm.transmute('public.rl121', 'id', 250, p_retain => 4000, p_regrain_batch => 1000);
select pgpm.obtain('public.rl121');
insert into public.rl121 values (5000, 'frontier');

select child_name as amono from pgpm.part
  where parent_table = 'public.rl121'::regclass and attached order by lo::numeric limit 1 \gset
select is(:'amono'::text, 'rl121_p0000000000000000000_to_0000000000000001250'::text,
  'GUARD (a): the monolith is [0, 1250), five sub-ranges of 250, as this file assumes');
select is((select pgpm._retain_boundary(c) from pgpm.config c where c.parent_table = 'public.rl121'::regclass),
  '1000', 'GUARD (a): the horizon sits at 1000, so exactly four sub-ranges are aged');

select is(pgpm.regrain_step('public.rl121', :'amono', '250'), 'prepared', '(a) tick 1 installs capture');
select is(pgpm.regrain_step('public.rl121', :'amono', '250'), 'copied:1',
  '(a) tick 2 advances over the aged sub-ranges and copies [1000, 1250) (one row, id 1000)');

-- LIVENESS: the four skips this section is about actually happened, on exactly these ranges.
select is(
  (select array_agg(lo || '..' || hi order by lo::numeric) from pgpm.log
    where parent_table = 'public.rl121'::regclass and action = 'regrain_aged'),
  array['0..250', '250..500', '500..750', '750..1000'],
  'LIVENESS (a): four regrain_aged rows, for [0,250) [250,500) [500,750) [750,1000), by identity');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rl121'::regclass), '1250',
  '(a) the cursor is at hi: the next tick is the swap');
select is((select array_agg(id order by id) from public.rl121 where id in (1, 250, 500, 750, 999)),
  array[1, 250, 500, 750, 999]::bigint[],
  '(a) before the swap the aged rows are still served through the source (sample by identity)');

-- The operator loosens retention to keep-forever while the swap is still ahead.
select lives_ok($$ select pgpm.set_retain('public.rl121', null) $$,
  '(a) set_retain(parent, null) mid-regrain is allowed (it warns, it does not refuse)');

-- THE assertion: the swap tick refuses rather than dropping rows the policy now says to keep.
select throws_like(
  $$ select pgpm.regrain_step('public.rl121', 'rl121_p0000000000000000000_to_0000000000000001250', '250') $$,
  '%pg_partition_magician: refusing to swap%[0, 250)%retention was loosened mid-regrain%',
  '(a) the swap refuses, naming the first sub-range that would be discarded but is no longer aged');

select ok((select attached from pgpm.part where parent_table = 'public.rl121'::regclass and child_name = :'amono'),
  '(a) after the refusal the source is still attached');
select is((select array_agg(id order by id) from public.rl121 where id in (1, 250, 500, 750, 999)),
  array[1, 250, 500, 750, 999]::bigint[],
  '(a) and every sampled aged row is still visible through the parent, by identity');
select is((select count(*)::int from public.rl121 where id < 1000), 999,
  '(a) all 999 rows below the old horizon survive');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rl121'::regclass), '1250',
  '(a) the cursor is untouched, so the run stays resumable rather than restarting');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rl121'::regclass
     and action = 'regrain' and method = 'copy_swap_drop'),
  0, '(a) no swap was recorded (the refusal above is the witness that one was attempted)');

-- A longer retain, not just null: 4500 puts the horizon at 500, so [0,250) and [250,500) are still aged
-- and [500,750) is the first sub-range the swap would wrongly discard. The refusal names THAT one.
select lives_ok($$ select pgpm.set_retain('public.rl121', '4500') $$, '(a) set_retain to a longer value is allowed');
select throws_like(
  $$ select pgpm.regrain_step('public.rl121', 'rl121_p0000000000000000000_to_0000000000000001250', '250') $$,
  '%pg_partition_magician: refusing to swap%[500, 750)%',
  '(a) with the horizon at 500 the refusal names [500, 750), the first skipped range no longer below it');

-- Restoring the policy the skips were made under lets the swap through, and its outcome is the
-- documented one: the aged rows go with the source.
select lives_ok($$ select pgpm.set_retain('public.rl121', '4000') $$, '(a) set_retain back to the original value');
select is(pgpm.regrain_step('public.rl121', :'amono', '250'), 'swapped:1',
  '(a) with the original retain restored the very next tick swaps');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rl121'::regclass
     and action = 'regrain' and method = 'copy_swap_drop'),
  1, 'WITNESS (a): the swap ran (one regrain / copy_swap_drop row)');
select is((select array_agg(id order by id) from public.rl121 where id < 1250), array[1000]::bigint[],
  '(a) after the legitimate swap only the copied row remains below 1250: the aged rows went with the source');

-- ==================== (b) a partially copied sub-range that ages between ticks ====================
-- Same monolith, batch 100 (smaller than the 249 rows of [0, 250)). Retain 4900 against frontier 5000
-- puts the horizon at 0, so nothing is aged at first; a second sentinel at 5500 moves it to 500.
create table public.rp121 (id bigint primary key, payload text);
insert into public.rp121 select g, 'x' from generate_series(1, 1000) g;
call pgpm.transmute('public.rp121', 'id', 250, p_retain => 4900, p_regrain_batch => 100);
select pgpm.obtain('public.rp121');
insert into public.rp121 values (5000, 'frontier');
create temp table rp121_pre as select id from public.rp121 where id < 1250;   -- the source, before any copy

select child_name as pmono from pgpm.part
  where parent_table = 'public.rp121'::regclass and attached order by lo::numeric limit 1 \gset
select is(:'pmono'::text, 'rp121_p0000000000000000000_to_0000000000000001250'::text,
  'GUARD (b): the monolith is [0, 1250) as this file assumes');
select is((select pgpm._retain_boundary(c) from pgpm.config c where c.parent_table = 'public.rp121'::regclass),
  '0', 'GUARD (b): the horizon sits at 0, so [0, 250) is NOT aged when its copy starts');

select is(pgpm.regrain_step('public.rp121', :'pmono', '250'), 'prepared', '(b) tick 1 installs capture');
select is(pgpm.regrain_step('public.rp121', :'pmono', '250'), 'copied:100', '(b) tick 2 copies the first batch of [0, 250)');

-- WITNESS: the child is genuinely partial, 100 of the 249 rows its range holds in the source.
select is((select count(*)::int from public.rp121_p0000000000000000000), 100,
  'WITNESS (b): the fine child for [0, 250) holds 100 rows mid-copy');
select is((select count(*)::int from rp121_pre where id < 250), 249,
  'WITNESS (b): while its range holds 249 in the source, so the child is a strict subset');

-- The frontier advances and the range ages out from under the half-copied child.
insert into public.rp121 values (5500, 'frontier moved');
select is((select pgpm._retain_boundary(c) from pgpm.config c where c.parent_table = 'public.rp121'::regclass),
  '500', 'WITNESS (b): the horizon is now 500, so [0, 250) is entirely below it');

-- THE assertion, tick by tick: the skip does not fire on a sub-range that already has a child.
select is(pgpm.regrain_step('public.rp121', :'pmono', '250'), 'copied:100',
  '(b) tick 3 keeps copying [0, 250) (ids 101..200) instead of skipping it as aged');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rp121'::regclass), '0',
  '(b) the cursor did not jump the half-copied sub-range');
select is(pgpm.regrain_step('public.rp121', :'pmono', '250'), 'copied:49',
  '(b) tick 4 finishes it (ids 201..249)');

-- Drive the rest to the swap. [250, 500) has no child and is aged, so it is skipped and discarded, which
-- the swap's re-check accepts because the horizon is still at 500.
do $$
declare v_status text; i int := 0;
begin
  loop
    v_status := pgpm.regrain_step('public.rp121', 'rp121_p0000000000000000000_to_0000000000000001250', '250');
    i := i + 1;
    exit when v_status like 'swapped:%' or i > 50;
  end loop;
end $$;
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rp121'::regclass
     and action = 'regrain' and method = 'copy_swap_drop'),
  1, 'WITNESS (b): the swap ran');

-- LIVENESS for the negative that follows: a neighbouring childless range WAS skipped as aged under the
-- same horizon, so [0, 250) was below it too and only its existing child kept the skip from firing.
select is(
  (select array_agg(lo || '..' || hi order by lo::numeric) from pgpm.log
    where parent_table = 'public.rp121'::regclass and action = 'regrain_aged'),
  array['250..500'],
  'LIVENESS (b): exactly one regrain_aged row, for [250, 500), the childless aged range');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rp121'::regclass
     and action = 'regrain_aged' and lo = '0'),
  0, '(b) and none for [0, 250): the sub-range with a child was never skipped');

-- After the swap no attached partition holds a strict subset of its source range. By identity for the
-- half-copied one: the rows either side of the first batch's watermark (100 | 101) and both ends.
select is(
  (select array_agg(id order by id) from
     (select id from rp121_pre where id < 250 except select id from public.rp121_p0000000000000000000) x),
  null::bigint[],
  '(b) the attached [0, 250) child is missing no row of its source range (pre EXCEPT child is empty)');
select is((select array_agg(id order by id) from public.rp121_p0000000000000000000 where id in (1, 100, 101, 249)),
  array[1, 100, 101, 249]::bigint[],
  '(b) the boundary rows are all there: first, the tick-2 watermark, the first row after it, and the last');

-- The sweep: every attached fine child in [0, 1250) holds exactly what the source held for its range.
-- Paired with the set of children compared, so an empty mismatch list cannot come from comparing nothing.
select is(
  (select array_agg(p.lo || '..' || p.hi order by p.lo::numeric) from pgpm.part p
    where p.parent_table = 'public.rp121'::regclass and p.attached and p.hi::numeric <= 1250),
  array['0..250', '500..750', '750..1000', '1000..1250'],
  'WITNESS (b): four fine children are attached below 1250 ([250, 500) went with the source)');
select is(
  (select coalesce(array_agg(p.child_name::text order by p.lo::numeric), '{}') from pgpm.part p
    where p.parent_table = 'public.rp121'::regclass and p.attached and p.hi::numeric <= 1250
      and (select count(*) from public.rp121 c where c.id >= p.lo::bigint and c.id < p.hi::bigint)
          <> (select count(*) from rp121_pre s where s.id >= p.lo::bigint and s.id < p.hi::bigint)),
  '{}'::text[],
  '(b) no attached child below 1250 holds fewer rows than its source range did');

select * from finish();

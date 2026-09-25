-- pgpm.progress(): the in-flight regrain view and its ETA (issue #343, gaps 3 and 4), plus the
-- _native_frac helper it is built on.
--
-- THE GAP. Regrain progress had to be read off pgpm.log by someone who already knew what
-- regrain_prepare / regrain_copy / regrain_reconcile / regrain_attach / regrain mean, and an ETA meant
-- doing rows / batch / cadence by hand or extrapolating from cron.job_run_details. progress() reads
-- the progress pgpm already keeps: config.regrain_cursor is the native-grid lo of the sub-range being
-- copied and only ever advances, so (cursor - lo) / (hi - lo) is an exact, monotonic fraction of the
-- RANGE, and the regrain_prepare log row gives elapsed time. ETA is elapsed * (1 - pct) / pct: an
-- extrapolation from observed progress, with no per-tick instrumentation on the hot path.
--
-- THE HONESTY CONSTRAINTS, each pinned below:
--   * Range-percent is not row-percent. Rows are not uniform across a range, the cursor only moves
--     when a whole sub-range completes (so it sits still while rows pile up), and aged sub-ranges are
--     advanced over WITHOUT being copied, so the cursor legitimately outruns the rows. pct_range and
--     rows_copied are separate columns; rows_total_est is reltuples and says so in its name. There is
--     no fused "N of M rows", because that cannot be produced honestly without a full scan.
--   * ETA is null until there is progress to extrapolate from, even when rows have already moved.
create extension if not exists pgtap;
select plan(49);

-- ================================ (A) _native_frac ================================
select is(pgpm._native_frac('id', '0', '250', '50'), 0.2::numeric,
  '_native_frac: id grid, 50 of [0, 250) is 0.2');
select is(pgpm._native_frac('time', '2024-01-01 00:00+00', '2024-01-11 00:00+00', '2024-01-03 00:00+00'), 0.2::numeric,
  '_native_frac: time grid, 2 of 10 days is 0.2');
select is(pgpm._native_frac('id', '0', '250', '0'), 0::numeric, '_native_frac: x = lo is 0');
select is(pgpm._native_frac('id', '0', '250', '250'), 1::numeric, '_native_frac: x = hi is 1');
select is(pgpm._native_frac('id', '100', '100', '100'), null::numeric,
  '_native_frac: an empty range is null, never a division by zero');

-- ================================ (B) an in-flight regrain, tick by tick ================================
-- 200 rows over a step of 50: monolith [0, 250), five sub-ranges. Batch 30, so a 49- or 50-row sub-range
-- takes two copy ticks, and the cursor moves only on the second.
create table public.pr (id bigint primary key, payload text);
insert into public.pr select g, 'x' from generate_series(1, 200) g;
call pgpm.transmute('public.pr', 'id', 50, p_regrain_batch => 30);
select pgpm.obtain('public.pr');
insert into public.pr values (1000, 'frontier');   -- frontier past 250: the monolith is frozen

select child_name as mono from pgpm.part
  where parent_table = 'public.pr'::regclass and attached order by lo::numeric limit 1 \gset
select is(:'mono'::text, 'pr_p0000000000000000000_to_0000000000000000250'::text,
  'GUARD: the monolith is [0, 250), five sub-ranges of 50, as this file assumes');
select format('analyze public.%I', :'mono') \gexec

select ok(coarse_frozen = 1 and regrain_child is null and regrain_cursor is null and regrain_pct_range is null
          and regrain_rows_copied is null and regrain_started_at is null and regrain_eta is null,
  'before any tick: one frozen coarse child waits, and nothing is in flight') from pgpm.progress('public.pr');

-- tick 1: prepare (installs change capture, copies nothing)
select is(pgpm.regrain_step('public.pr', :'mono', '50'), 'prepared', 'tick 1 installs capture (prepared)');
select is(regrain_child, :'mono'::name,
  'after prepare: regrain_child is the monolith, by name') from pgpm.progress('public.pr');
select is(regrain_cursor, (select regrain_cursor from pgpm.config where parent_table = 'public.pr'::regclass),
  'regrain_cursor is config.regrain_cursor, verbatim') from pgpm.progress('public.pr');
select is(regrain_cursor, '0', 'and it sits at the coarse lo') from pgpm.progress('public.pr');
select is(regrain_pct_range, 0::numeric, 'pct_range is 0 at the start') from pgpm.progress('public.pr');
select is(regrain_rows_copied, 0::bigint, 'rows_copied is 0 at the start') from pgpm.progress('public.pr');
select is(regrain_rows_total_est, 200::bigint,
  'rows_total_est is the source''s reltuples (200, after ANALYZE)') from pgpm.progress('public.pr');
select is(regrain_started_at,
  (select max(at) from pgpm.log where parent_table = 'public.pr'::regclass and action = 'regrain_prepare'),
  'started_at is the regrain_prepare row''s timestamp') from pgpm.progress('public.pr');
select is(regrain_eta, null::interval,
  'eta is null with no progress to extrapolate from') from pgpm.progress('public.pr');

-- tick 2: the first batch of [0, 50). 49 rows there, batch 30: the sub-range is NOT complete.
select is(pgpm.regrain_step('public.pr', :'mono', '50'), 'copied:30', 'tick 2 copies one batch of [0, 50)');
select is(regrain_cursor, '0',
  'the cursor has not moved: [0, 50) is not complete (30 of 49 rows)') from pgpm.progress('public.pr');
select is(regrain_pct_range, 0::numeric, 'so pct_range is still 0') from pgpm.progress('public.pr');
select is(regrain_rows_copied, 30::bigint,
  'while rows_copied says 30 -- the two measure different things') from pgpm.progress('public.pr');
select is(regrain_eta, null::interval,
  'eta stays null at pct 0 even though rows have moved: no fabricated early estimate') from pgpm.progress('public.pr');

-- tick 3: the rest of [0, 50); the cursor advances.
select is(pgpm.regrain_step('public.pr', :'mono', '50'), 'copied:19', 'tick 3 finishes [0, 50)');
select is(regrain_cursor, '50', 'the cursor advances to the next sub-range') from pgpm.progress('public.pr');
select is(regrain_pct_range, 0.2::numeric,
  'pct_range is exactly (50 - 0) / (250 - 0) = 0.2') from pgpm.progress('public.pr');
select is(regrain_rows_copied, 49::bigint, 'rows_copied is 49 (ids 1..49)') from pgpm.progress('public.pr');
select ok(regrain_eta is not null and regrain_elapsed is not null,
  'eta appears once there is progress') from pgpm.progress('public.pr');
select is(regrain_eta, regrain_elapsed * 4,
  'eta = elapsed * (1 - 0.2) / 0.2 = 4x elapsed, exactly') from pgpm.progress('public.pr');

-- A committed DELETE in an already-copied sub-range is captured, shows as a pending change, and clears once
-- reconciled. A DELETE, not an UPDATE: the trigger records OLD and NEW for an update (a key change dirties
-- both), so one update is honestly TWO pending entries, and this assertion is about the count.
delete from public.pr where id = 10;
select is(regrain_delta_pending, 1::bigint,
  'a committed DELETE in an already-copied sub-range shows as one pending captured change') from pgpm.progress('public.pr');
select is(pgpm.regrain_step('public.pr', :'mono', '50'), 'reconciled:1', 'the next tick reconciles it');
select is(regrain_delta_pending, 0::bigint, 'and the backlog reads 0 again') from pgpm.progress('public.pr');

-- [50, 100): two more ticks; pct_range moves monotonically, and matches the cursor exactly again
select is(pgpm.regrain_step('public.pr', :'mono', '50'), 'copied:30', 'copy [50, 100), batch 1');
select is(pgpm.regrain_step('public.pr', :'mono', '50'), 'copied:20', 'copy [50, 100), batch 2 completes it');
select is(regrain_cursor, '100', 'the cursor is at 100') from pgpm.progress('public.pr');
select is(regrain_pct_range, 0.4::numeric,
  'pct_range is exactly 100 / 250 = 0.4 (monotonic: 0 -> 0.2 -> 0.4)') from pgpm.progress('public.pr');
select is(regrain_rows_copied, 99::bigint, 'rows_copied is 99') from pgpm.progress('public.pr');
select is(regrain_eta, regrain_elapsed * 1.5,
  'eta = elapsed * (1 - 0.4) / 0.4 = 1.5x elapsed') from pgpm.progress('public.pr');

-- finish it: regrain() resumes from the cursor and swaps
select is(pgpm.regrain('public.pr', :'mono', '50'), 5,
  'regrain() finishes the in-flight run from where the ticks left it (5 fine children attached)');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.pr'::regclass
     and action = 'regrain' and method = 'copy_swap_drop'),
  1, 'WITNESS: the swap actually ran (one regrain / copy_swap_drop row)');
select ok(regrain_child is null and regrain_cursor is null and regrain_pct_range is null
          and regrain_rows_copied is null and regrain_started_at is null and regrain_eta is null,
  'after the swap nothing is in flight: every in-flight column is null again') from pgpm.progress('public.pr');
select is(coarse_frozen, 0::bigint, 'and no frozen coarse child remains') from pgpm.progress('public.pr');

-- ==================== (C) the asymmetry: aged sub-ranges move the cursor, not the rows ====================
-- Same shape, with retain 900 against a frontier of 1000: the horizon is 100, so [0, 50) and [50, 100)
-- are aged. archive_fn is unset, so regrain advances over them WITHOUT copying, and the first copy tick
-- lands the cursor at 100 having moved 30 rows.
create table public.pa (id bigint primary key, payload text);
insert into public.pa select g, 'x' from generate_series(1, 200) g;
call pgpm.transmute('public.pa', 'id', 50, p_regrain_batch => 30, p_retain => 900);
select pgpm.obtain('public.pa');
insert into public.pa values (1000, 'frontier');

select child_name as amono from pgpm.part
  where parent_table = 'public.pa'::regclass and attached order by lo::numeric limit 1 \gset
select is(:'amono'::text, 'pa_p0000000000000000000_to_0000000000000000250'::text,
  'GUARD: the aged fixture''s monolith is [0, 250) as this file assumes');
select format('analyze public.%I', :'amono') \gexec

select is(pgpm.regrain_step('public.pa', :'amono', '50'), 'prepared', 'aged: tick 1 prepared');
select is(pgpm.regrain_step('public.pa', :'amono', '50'), 'copied:30',
  'aged: tick 2 advances over the aged sub-ranges and copies the first batch of [100, 150)');

-- LIVENESS: the skip this section is about actually happened, twice.
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.pa'::regclass and action = 'regrain_aged'),
  2, 'LIVENESS: two sub-ranges ([0, 50) and [50, 100)) were advanced over as aged without being copied');

select is(regrain_cursor, '100',
  'aged: the cursor jumped over both aged sub-ranges to 100') from pgpm.progress('public.pa');
select is(regrain_pct_range, 0.4::numeric,
  'aged: pct_range reads 0.4 -- 40% of the RANGE is behind the cursor') from pgpm.progress('public.pa');
select is(regrain_rows_copied, 30::bigint,
  'aged: while only 30 rows have been copied') from pgpm.progress('public.pa');
select is(regrain_rows_total_est, 200::bigint,
  'aged: against an estimated 200 in the source (every row, aged ones included)') from pgpm.progress('public.pa');
select ok(regrain_pct_range > regrain_rows_copied::numeric / regrain_rows_total_est,
  'aged: pct_range outruns the row fraction (0.4 vs 0.15), which is why the two are separate columns and never one "N of M"')
  from pgpm.progress('public.pa');

select pgpm.regrain_cancel('public.pa');
drop table if exists public.pr, public.pa cascade;

select * from finish();

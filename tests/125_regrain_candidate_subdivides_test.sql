-- Issue #515: maintain()'s auto-regrain candidate must be a child the target step actually subdivides.
--
-- The wedge. maintain() picked the oldest frozen child that was "coarse" by the GRID's definition (hi >
-- one partition_step past lo) and handed it to regrain_step, whose own precondition is different: the
-- TARGET step must subdivide the child (hi > one target step past lo), else it answers 'nosubdiv'. The
-- two predicates agree only when the target is no wider than partition_step at EVERY lo. set_regrain's
-- #341 refusal compares the two widths once, at partition_anchor, which is exact for two calendar steps
-- or two fixed ones but not across kinds: '30 days' on a '1 month' grid is narrower than the anchor's
-- 31-day January, so it is accepted, and yet a 30-day cell that starts in February is WIDER than the
-- calendar month from there (2024-02-06 + 30 days = 03-07, + 1 month = 03-06). Once the first coarse
-- child has been split into 30-day cells, that cell is coarse by the candidate's test and not
-- subdividable by regrain_step's, so every later tick reselected it, got 'nosubdiv', and never reached
-- the coarse children behind it. Silent and permanent: the exact wedge #341's refusal exists to prevent.
--
-- The fix makes the candidate query require BOTH: coarse by the grid's step AND subdividable by the
-- target, which is regrain_step's precondition verbatim, so a candidate can no longer come back
-- 'nosubdiv' whatever the target. progress().coarse_frozen mirrors the same test. The cells a target
-- cannot split are left as they are; they stay counted in status().coarse_partitions.
--
-- Fixture: a ULID (text_time) table, monthly grid in UTC anchored at 2025-01-01, history from
-- 2024-01-01 to 2025-12-31 (one row a day), the monolith frozen by one write three months ahead, then
-- split by hand into calendar years (the documented hierarchical use of regrain). Auto-regrain toward
-- '30 days' then has two frozen coarse years to work, and the FIRST of them contains the unsubdividable
-- cell [2024-02-06, 2024-03-07): the 30-day lattice from the anchor is fixed, so its position does not
-- depend on the day this runs. The second year is what the unfixed code never reaches. text_time rather
-- than uuidv7 because the frontier of both follows now() (so one future write freezes the monolith), and
-- regrain_step's resumed copy takes max() of the control column, which uuid has no aggregate for.
--
-- Every negative assertion here is paired with a LIVENESS witness that the conditions for the wedge were
-- present: the guard accepted the target, the first year really was split, and the cell that wedged the
-- unfixed code really is attached, coarse by the grid's definition, and exactly one target step wide.
set timezone = 'UTC';
create extension if not exists pgtap;
select plan(17);

create table public.rc (id text collate "C" primary key, body text);
insert into public.rc
  select pgpm._ts_to_text_time(d, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') || substr(upper(md5(d::text)), 1, 16), 'day'
    from generate_series('2024-01-01 12:00+00'::timestamptz, '2025-12-31 12:00+00'::timestamptz, interval '1 day') d;

call pgpm.transmute('public.rc', 'id', interval '1 month', p_obtain => 4,
                    p_anchor => '2025-01-01 00:00+00', p_paused => false,
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
select pgpm.obtain('public.rc');
-- a write three months ahead: the frontier leaves the monolith, which freezes
insert into public.rc values (
  pgpm._ts_to_text_time(date_trunc('month', now()) + interval '3 months 1 day', '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') || 'FFFFFFFFFFFFFFFF',
  'frontier');
create temp table rc_before as select id from public.rc;

select is(
  (select control_kind || ' ' || partition_step::interval::text || ' ' || partition_tz from pgpm.config where parent_table = 'public.rc'::regclass),
  'text_time 1 mon UTC', 'LIVENESS: a monthly text_time grid in UTC');

-- the documented hierarchical split: the monolith into calendar years on the anchor's lattice
select pgpm.regrain_history('public.rc', '1 year');

select ok(
  exists (select 1 from pgpm.part where parent_table = 'public.rc'::regclass and attached
            and lo::timestamptz = '2024-01-01 00:00+00' and hi::timestamptz = '2025-01-01 00:00+00'),
  'LIVENESS: the hierarchical split left a coarse year [2024-01-01, 2025-01-01)');
select ok(
  exists (select 1 from pgpm.part where parent_table = 'public.rc'::regclass and attached
            and lo::timestamptz = '2025-01-01 00:00+00' and hi::timestamptz = '2026-01-01 00:00+00'),
  'LIVENESS: and a second coarse year [2025-01-01, 2026-01-01) behind it');

-- The #341 guard compares widths at the anchor: 30 days is narrower than January 2025, so it accepts.
select lives_ok(
  $$ select pgpm.set_regrain('public.rc', '30 days') $$,
  'LIVENESS: set_regrain accepts ''30 days'' on the monthly grid (narrower than the anchor''s January)');

-- ...but a 30-day cell starting 2024-02-06 is wider than the calendar month from there.
select ok(
  pgpm._native_gt('text_time',
    pgpm._grid_next('text_time', '30 days', '2024-02-06 00:00:00+00', 'UTC'),
    pgpm._grid_next('text_time', '1 month', '2024-02-06 00:00:00+00', 'UTC')),
  'LIVENESS: 2024-02-06 + 30 days (03-07) is past 2024-02-06 + 1 month (03-06): the target is wider than the grid step there');

-- Tick until the first year has been swapped for its 30-day cells (bounded; the swap is ~15 ticks:
-- prepare, thirteen copies, swap). Every status is kept so the wedge's signature can be looked for.
create temp table rc_ticks (n int, status text);
do $$
declare s text; n int := 0;
begin
  while n < 40 and exists (select 1 from pgpm.part where parent_table = 'public.rc'::regclass and attached
                             and lo::timestamptz = '2024-01-01 00:00+00' and hi::timestamptz = '2025-01-01 00:00+00') loop
    n := n + 1;
    call pgpm.maintain('public.rc', s);
    insert into rc_ticks values (n, s);
  end loop;
end $$;

select ok(
  not exists (select 1 from pgpm.part where parent_table = 'public.rc'::regclass and attached
                and lo::timestamptz = '2024-01-01 00:00+00' and hi::timestamptz = '2025-01-01 00:00+00'),
  'LIVENESS: auto-regrain split [2024-01-01, 2025-01-01) into 30-day cells (the wedge''s precondition)');

-- The cell that wedged the unfixed code: attached, coarse by the grid's step, exactly one target step wide.
select ok(
  exists (select 1 from pgpm.part p where p.parent_table = 'public.rc'::regclass and p.attached
            and p.lo::timestamptz = '2024-02-06 00:00+00' and p.hi::timestamptz = '2024-03-07 00:00+00'
            and pgpm._native_gt('text_time', p.hi, pgpm._grid_next('text_time', '1 month', p.lo, 'UTC'))
            and not pgpm._native_gt('text_time', p.hi, pgpm._grid_next('text_time', '30 days', p.lo, 'UTC'))),
  'LIVENESS: [2024-02-06, 2024-03-07) is attached, wider than one partition_step, and not subdividable by 30 days');

-- progress().coarse_frozen mirrors the candidate test: of the frozen children that are coarse by the
-- grid's step, exactly one (that cell) is excluded, because the target cannot split it.
select cmp_ok(
  (select count(*) from pgpm.part p
    where p.parent_table = 'public.rc'::regclass and p.attached
      and pgpm._native_gt('text_time', p.hi, pgpm._grid_next('text_time', '1 month', p.lo, 'UTC'))
      and not pgpm._native_gt('text_time', p.hi,
            pgpm._grid_floor('text_time', '1 month', '2025-01-01 00:00:00+00', pgpm._frontier_native('public.rc'), 'UTC'))),
  '>=', 2::bigint,
  'LIVENESS: at least two frozen children are coarse by the grid''s step (the 30-day February cell and the second year)');
select is(
  (select count(*) from pgpm.part p
    where p.parent_table = 'public.rc'::regclass and p.attached
      and pgpm._native_gt('text_time', p.hi, pgpm._grid_next('text_time', '1 month', p.lo, 'UTC'))
      and not pgpm._native_gt('text_time', p.hi,
            pgpm._grid_floor('text_time', '1 month', '2025-01-01 00:00:00+00', pgpm._frontier_native('public.rc'), 'UTC')))
  - (select coarse_frozen from pgpm.progress('public.rc')),
  1::bigint,
  'progress().coarse_frozen excludes exactly the one frozen coarse child the target cannot subdivide');

-- Now the ticks the unfixed code spent reselecting that cell. The second year needs ~15; give it 40.
do $$
declare s text; n int;
begin
  select coalesce(max(rc_ticks.n), 0) into n from rc_ticks;
  for i in 1..40 loop
    n := n + 1;
    call pgpm.maintain('public.rc', s);
    insert into rc_ticks values (n, s);
  end loop;
end $$;

select is(
  (select count(*) from rc_ticks where status like '%regrain=nosubdiv%'),
  0::bigint, 'no tick answered regrain=nosubdiv: the candidate is always a child the target subdivides');

select ok(
  not exists (select 1 from pgpm.part where parent_table = 'public.rc'::regclass and attached
                and lo::timestamptz = '2025-01-01 00:00+00' and hi::timestamptz = '2026-01-01 00:00+00'),
  'the second coarse year [2025-01-01, 2026-01-01) was regrained too: auto-regrain stepped past the cell it cannot split');

select is(
  (select string_agg(lo::timestamptz::date::text, ',' order by lo::timestamptz) from pgpm.part
    where parent_table = 'public.rc'::regclass and attached
      and lo::timestamptz >= '2025-01-01 00:00+00' and hi::timestamptz <= '2026-01-01 00:00+00'),
  '2025-01-01,2025-01-31,2025-03-02,2025-04-01,2025-05-01,2025-05-31,2025-06-30,2025-07-30,2025-08-29,2025-09-28,2025-10-28,2025-11-27,2025-12-27',
  'the second year is exactly its thirteen 30-day cells on the anchor''s lattice');

-- The swaps are in the log with the years' own bounds (exact action, exact bounds: identity, not a count).
select is(
  (select string_agg(lo::timestamptz::date::text || '..' || hi::timestamptz::date::text, ' ' order by lo::timestamptz)
     from pgpm.log where parent_table = 'public.rc'::regclass and action = 'regrain' and method = 'copy_swap_drop'
      and hi::timestamptz <= '2026-01-01 00:00+00'),
  '2024-01-01..2025-01-01 2025-01-01..2026-01-01',
  'the log records one copy_swap_drop regrain for each of the two years, and none for the 30-day cells');

-- The cell the target cannot split stays exactly as it was: still attached, still coarse by the grid's
-- step, never renamed, never swapped.
select is(
  (select count(*) from pgpm.log where parent_table = 'public.rc'::regclass
     and action in ('regrain_prepare', 'regrain_rename', 'regrain')
     and lo::timestamptz = '2024-02-06 00:00+00'),
  0::bigint, 'no regrain was ever started, renamed or swapped on [2024-02-06, 2024-03-07)');

select ok(
  exists (select 1 from pgpm.part p where p.parent_table = 'public.rc'::regclass and p.attached
            and p.lo::timestamptz = '2024-02-06 00:00+00' and p.hi::timestamptz = '2024-03-07 00:00+00'),
  '[2024-02-06, 2024-03-07) is still attached after every tick (left alone, not wedged on)');

-- Row identity across both regrains: the same ids, no more, no fewer.
select is_empty(
  $$ select id from rc_before except select id from public.rc $$,
  'every fixture row (731 days and the frontier write) is still in the parent');
select is_empty(
  $$ select id from public.rc except select id from rc_before $$,
  'and nothing that was not in the fixture appeared');

select * from finish();

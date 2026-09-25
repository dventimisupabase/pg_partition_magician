-- A month step is one lattice even where midnight on the 1st falls in a DST gap (issue #505).
--
-- _grid_floor's month branch turns "00:00 on the 1st in partition_tz" into an instant. When that wall
-- time does not exist, because the zone's clocks jumped forward at midnight (America/Asuncion on
-- 2023-10-01, Asia/Amman on 2016-04-01), PostgreSQL resolves it to the instant an hour later, whose wall
-- reading is 01:00. That instant IS the first instant of the month, so the floor is right. _grid_next then
-- read the wall clock back off that instant and added a month to the reading as it stood, 01:00 on the
-- 1st, and landed an hour past the next boundary: next(floor(Oct)) was 01:00 on Nov 1 while floor(Nov)
-- was 00:00 on Nov 1. regrain_step walks sub-ranges with exactly that pair (the floor of its cursor, then
-- the next of that floor, then the floor of THAT as the following cursor), so the October child ended an
-- hour after the November child began, the swap's ATTACH failed with "would overlap", and under
-- auto-regrain that was skip_regrain on every tick, forever.
--
-- The fix snaps in _grid_next: an instant that is its month's first instant in p_tz (the wall midnight of
-- its month converts back to exactly it) steps from that wall midnight, not from its 01:00 reading. An
-- off-grid value (set_regrain compares two steps' widths from the anchor, which is not on the month
-- lattice in most zones) still steps by a plain calendar month.
--
-- The walk cannot be driven through regrain here: a calendar grid's frontier is never below now(), so a
-- monolith spanning a historical gap never freezes inside a test, and tzdata projects no future gap at
-- midnight on the 1st in any zone (checked while writing this, none in the next ten years). What IS
-- pinned is the pair regrain_step computes, at the adapter, under two session zones (a function that
-- consulted the session would disagree with itself), each with a witness that the gap really exists.
-- bench/month_step_dst_gap.sh runs this file against a mutant that adds the month to the raw wall reading
-- again (grid_next_month_unsnapped), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(18);

-- ==================== (a) the gaps really exist ====================
select isnt((('2023-10-01 00:00'::timestamp at time zone 'America/Asuncion') at time zone 'America/Asuncion'),
            '2023-10-01 00:00'::timestamp,
  'LIVENESS: 2023-10-01 00:00 does not exist on the America/Asuncion wall clock');
select is((('2023-10-01 00:00'::timestamp at time zone 'America/Asuncion') at time zone 'America/Asuncion'),
          '2023-10-01 01:00'::timestamp,
  'LIVENESS: it resolves to the instant an hour later, which reads 01:00');
select isnt((('2016-04-01 00:00'::timestamp at time zone 'Asia/Amman') at time zone 'Asia/Amman'),
            '2016-04-01 00:00'::timestamp,
  'LIVENESS: 2016-04-01 00:00 does not exist on the Asia/Amman wall clock');

-- ==================== (b) America/Asuncion, computed under an Asuncion session and a UTC session ====================
set timezone = 'America/Asuncion';
select is(current_setting('TimeZone'), 'America/Asuncion', 'LIVENESS: the session really is in Asuncion for the first pass');
create temp table g_as as
select pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion')::timestamptz as fl_oct,
       pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-11-15 12:00:00+00', 'America/Asuncion')::timestamptz as fl_nov,
       pgpm._grid_next('time', '1 month',
         pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion'),
         'America/Asuncion')::timestamptz as nx_oct,
       pgpm._grid_next('time', '1 month',
         pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-09-15 12:00:00+00', 'America/Asuncion'),
         'America/Asuncion')::timestamptz as nx_sep,
       pgpm._grid_next('time', '3 months',
         pgpm._grid_floor('time', '3 months', '2000-01-01 03:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion'),
         'America/Asuncion')::timestamptz as nx_q4,
       pgpm._part_name('ev', 'time', '1 month',
         pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion'),
         pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-11-15 12:00:00+00', 'America/Asuncion'),
         'America/Asuncion')::text as nm_oct,
       (select array_agg((b::timestamptz at time zone 'UTC') order by n)
          from (select n, (pgpm._grid_next('time', '1 month', lag_b, 'America/Asuncion')) as b
                  from (with recursive w(n, lag_b) as (
                          select 0, pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-01-15 00:00:00+00', 'America/Asuncion')
                          union all
                          select n + 1, pgpm._grid_next('time', '1 month', lag_b, 'America/Asuncion') from w where n < 11)
                        select n, lag_b from w) s) c) as chain;
set timezone = 'UTC';
select is(current_setting('TimeZone'), 'UTC', 'LIVENESS: the session really is in UTC for the second pass');
create temp table g_utc as
select pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion')::timestamptz as fl_oct,
       pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-11-15 12:00:00+00', 'America/Asuncion')::timestamptz as fl_nov,
       pgpm._grid_next('time', '1 month',
         pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion'),
         'America/Asuncion')::timestamptz as nx_oct,
       pgpm._grid_next('time', '1 month',
         pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-09-15 12:00:00+00', 'America/Asuncion'),
         'America/Asuncion')::timestamptz as nx_sep,
       pgpm._grid_next('time', '3 months',
         pgpm._grid_floor('time', '3 months', '2000-01-01 03:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion'),
         'America/Asuncion')::timestamptz as nx_q4,
       pgpm._part_name('ev', 'time', '1 month',
         pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion'),
         pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-11-15 12:00:00+00', 'America/Asuncion'),
         'America/Asuncion')::text as nm_oct,
       (select array_agg((b::timestamptz at time zone 'UTC') order by n)
          from (select n, (pgpm._grid_next('time', '1 month', lag_b, 'America/Asuncion')) as b
                  from (with recursive w(n, lag_b) as (
                          select 0, pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-01-15 00:00:00+00', 'America/Asuncion')
                          union all
                          select n + 1, pgpm._grid_next('time', '1 month', lag_b, 'America/Asuncion') from w where n < 11)
                        select n, lag_b from w) s) c) as chain;

-- the Asuncion pass, value by value (hand-derived: -04 before the jump, -03 after it)
select is((select fl_oct from g_as), '2023-10-01 04:00:00+00'::timestamptz,
  'the October floor is the first instant of October: 00:00 -04 on the 1st, which the clocks that jumped read as 01:00 -03');
select is((select fl_nov from g_as), '2023-11-01 03:00:00+00'::timestamptz,
  'the November floor is 00:00 -03 on November 1');
select is((select nx_oct from g_as), (select fl_nov from g_as),
  '_grid_next of the October floor IS the November floor (it was an hour later, 01:00 -03 on November 1)');
select is((select nx_sep from g_as), (select fl_oct from g_as),
  '_grid_next of the September floor is the October floor (stepping INTO the gap already agreed)');
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', (select nx_oct from g_as)::text, 'America/Asuncion')::timestamptz,
  (select nx_oct from g_as),
  'regrain''s next cursor floors to itself: the sub-range after [October floor, next) starts exactly where it ended, so the two cannot overlap');
select is((select nx_q4 from g_as), '2024-01-01 03:00:00+00'::timestamptz,
  'a quarter step from the October quarter floor (an anchor at Asuncion midnight puts the phase on Jan/Apr/Jul/Oct) lands on the January floor: the snap holds for any month count');
select is((select nm_oct from g_as), 'ev_p2023_10',
  'the October cell is the fine child ev_p2023_10 (hi equals next(lo) exactly, so no _to_ form)');
select is((select chain from g_as),
  (select array_agg((pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', (m + interval '14 days')::text, 'America/Asuncion')::timestamptz at time zone 'UTC') order by m)
     from generate_series('2023-02-01'::timestamptz, '2024-01-01'::timestamptz, interval '1 month') m),
  'twelve _grid_next steps from the January 2023 floor visit exactly the twelve floors of February 2023 to January 2024');

-- and the UTC pass equals the Asuncion pass, every value at once
select is(
  (select (fl_oct at time zone 'UTC') || '/' || (fl_nov at time zone 'UTC') || '/' || (nx_oct at time zone 'UTC') || '/'
       || (nx_sep at time zone 'UTC') || '/' || (nx_q4 at time zone 'UTC') || '/' || nm_oct || '/' || chain::text from g_utc),
  (select (fl_oct at time zone 'UTC') || '/' || (fl_nov at time zone 'UTC') || '/' || (nx_oct at time zone 'UTC') || '/'
       || (nx_sep at time zone 'UTC') || '/' || (nx_q4 at time zone 'UTC') || '/' || nm_oct || '/' || chain::text from g_as),
  'every value is identical under a UTC session and an Asuncion session');

-- ==================== (c) Asia/Amman 2016-04-01, and an off-grid value ====================
select is(
  pgpm._grid_next('time', '1 month',
    pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2016-04-15 12:00:00+00', 'Asia/Amman'), 'Asia/Amman')::timestamptz,
  pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2016-05-15 12:00:00+00', 'Asia/Amman')::timestamptz,
  'Asia/Amman: _grid_next of the April 2016 floor is the May floor');
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2016-04-15 12:00:00+00', 'Asia/Amman')::timestamptz,
  '2016-03-31 22:00:00+00'::timestamptz,
  'LIVENESS: the April 2016 floor is 00:00 +02 on the 1st, the instant whose wall reading became 01:00 +03');
-- the default anchor is 19:00 EST on 1999-12-31 in New York: not a month boundary there, so it steps by a
-- plain calendar month (set_regrain compares two steps'' widths from it and must keep seeing a month)
select is(pgpm._grid_next('time', '1 month', '2000-01-01 00:00:00+00', 'America/New_York')::timestamptz,
  '2000-02-01 00:00:00+00'::timestamptz,
  'an off-grid value is not snapped: the default anchor steps by one calendar month on the New York wall clock');
select is(pgpm._grid_next('time', '1 month', '2026-03-01 05:00:00+00', 'America/New_York')::timestamptz,
  '2026-04-01 04:00:00+00'::timestamptz,
  'an ordinary month boundary (no gap) steps as before: New York midnight March 1 to New York midnight April 1');

select * from finish();

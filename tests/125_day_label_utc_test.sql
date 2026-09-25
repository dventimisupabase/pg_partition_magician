-- Day and week labels are the UTC date of the cell's start, in every partition_tz (issue #503).
--
-- A day-denominated step is an absolute 86400 s lattice from the anchor instant (#455), but _part_name
-- rendered its label as the wall DATE of the cell's start in partition_tz. In a zone with daylight saving
-- that lattice drifts an hour against local midnight twice a year, so two adjacent cells could start on
-- the same wall date: with the anchor at a summer midnight, the New York cells starting 00:00 EDT and
-- 23:00 EST of the fall-back Sunday; with the default anchor, the 00:00Z cells of the fall-back Sunday
-- and of the Monday in Atlantic/Azores, whose 00:00Z reads 00:00 in summer and 23:00 the evening before
-- in winter. And set_partition_tz, documented as safe on a day step because "only the names move", moved
-- every label onto the previous cell's after a change to a zone west of the old one. obtain and extend_to
-- skip a candidate whose name already exists BEFORE their overlap check, so the second cell of any such
-- pair was never built: a permanent one-day hole that refused every write once the frontier reached it,
-- with nothing logged and a healthy status().
--
-- The fix labels every fixed-second cell (day, week, hour, minute) by the UTC reading of its start, the
-- rule hour and minute labels already followed for exactly this collision: two instants 86400 s apart
-- never share a UTC date. Calendar cells (month, year) are defined on the wall clock in partition_tz and
-- keep their wall-month label. A day grid's zone is therefore a pure setting: bounds and names are both
-- absolute, and set_partition_tz on it moves nothing.
--
-- Every "no hole" and "distinct names" below is paired with a witness that the collision was really set
-- up: the two cell starts really share a wall date in the zone, the chosen Sunday really has a fall-back,
-- the grid really crossed it. bench/day_label_utc.sh runs this file against a mutant that renders day
-- labels in partition_tz again (part_name_day_label_in_zone), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(25);

-- ==================== (a) the adapter: one label per cell, whatever the zone ====================
set timezone = 'America/New_York';
select is(current_setting('TimeZone'), 'America/New_York', 'LIVENESS: the session is in New York, so a session-zone rendering would differ from UTC');

-- the cell [2026-11-01 00:00Z, 2026-11-02 00:00Z) reads 20:00 EDT October 31 in New York and 11:00 November 1 in Sydney
select is(pgpm._part_name('ev', 'time', '1 day', '2026-11-01 00:00:00+00', '2026-11-02 00:00:00+00', 'America/New_York')::text,
  'ev_p2026_11_01', 'a day cell is labelled by the UTC date it starts on, not by the New York wall date (October 31) of that instant');
select is(pgpm._part_name('ev', 'time', '1 day', '2026-11-01 00:00:00+00', '2026-11-02 00:00:00+00', 'Australia/Sydney')::text,
  'ev_p2026_11_01', 'the same cell carries the same label under Australia/Sydney');
select is(pgpm._part_name('ev', 'time', '1 week', '2026-10-31 00:00:00+00', '2026-11-07 00:00:00+00', 'America/New_York')::text,
  'ev_p2026_10_31', 'a week cell is labelled by the UTC date it starts on');
select is(pgpm._part_name('ev', 'time', '1 day', '2026-10-25 00:00:00+00', '2026-11-02 00:00:00+00', 'Atlantic/Azores')::text,
  'ev_p2026_10_25_to_2026_11_02', 'a coarse day-step name renders both bounds as UTC dates');
-- calendar cells keep the wall-month label: 2026-03-01 00:00 AEDT is 2026-02-28 13:00Z
select is(pgpm._part_name('ev', 'time', '1 month', '2026-02-28 13:00:00+00', '2026-03-31 13:00:00+00', 'Australia/Sydney')::text,
  'ev_p2026_03', 'a month cell is still labelled by its wall month in partition_tz (a UTC rendering would say February)');

-- the New York collision: anchor at a summer midnight puts the lattice at 04:00Z, and the cells starting
-- 2026-11-01 04:00Z (00:00 EDT Sunday) and 2026-11-02 04:00Z (23:00 EST Sunday) share a wall date
select is(('2026-11-01 04:00:00+00'::timestamptz at time zone 'America/New_York')::date,
          ('2026-11-02 04:00:00+00'::timestamptz at time zone 'America/New_York')::date,
  'LIVENESS: the two New York cells straddling the 2026 fall-back start on the same wall date');
select is(pgpm._part_name('ev', 'time', '1 day', '2026-11-01 04:00:00+00', '2026-11-02 04:00:00+00', 'America/New_York')::text
          || ',' || pgpm._part_name('ev', 'time', '1 day', '2026-11-02 04:00:00+00', '2026-11-03 04:00:00+00', 'America/New_York')::text,
  'ev_p2026_11_01,ev_p2026_11_02', 'and they get two different names');
-- the Azores collision: the default 00:00Z lattice reads 00:00 in summer (+00) and 23:00 the evening before in winter (-01)
select is(('2026-10-25 00:00:00+00'::timestamptz at time zone 'Atlantic/Azores')::date,
          ('2026-10-26 00:00:00+00'::timestamptz at time zone 'Atlantic/Azores')::date,
  'LIVENESS: the Azores cells of the 2026 fall-back Sunday and the Monday start on the same wall date');
select is(pgpm._part_name('ev', 'time', '1 day', '2026-10-25 00:00:00+00', '2026-10-26 00:00:00+00', 'Atlantic/Azores')::text
          || ',' || pgpm._part_name('ev', 'time', '1 day', '2026-10-26 00:00:00+00', '2026-10-27 00:00:00+00', 'Atlantic/Azores')::text,
  'ev_p2026_10_25,ev_p2026_10_26', 'and they get two different names');

-- ==================== (b) a New York daily grid anchored at a summer midnight, across the fall-back ====================
-- The transition is the first Sunday of November, chosen relative to now() so the file keeps testing a
-- FUTURE fall-back. The anchor is local midnight a week before it (EDT), a legitimate day-grid anchor.
create temp table fb as
select d from (select make_date(y, 11, 1) + ((7 - extract(dow from make_date(y, 11, 1))::int) % 7) as d
                 from generate_series(extract(year from now())::int, extract(year from now())::int + 1) y) s
 where (d::timestamp at time zone 'America/New_York') > now() + interval '2 days'
 order by d limit 1;
select d as fbd from fb \gset
select is(((:'fbd'::date + 1)::timestamp at time zone 'America/New_York') - (:'fbd'::date::timestamp at time zone 'America/New_York'),
  interval '25 hours', 'LIVENESS: the chosen Sunday has a fall-back (it is 25 hours long)');

create table public.dl (ts timestamptz not null, id bigint not null, payload text, primary key (ts, id));
insert into public.dl values (now() - interval '3 days', 1, 'old');
select format('call pgpm.transmute(%L, %L, interval %L, p_obtain => 2, p_anchor => %L)',
              'public.dl', 'ts', '1 day', ((:'fbd'::date - 7)::timestamp at time zone 'America/New_York')) \gexec
select is((select partition_tz from pgpm.config where parent_table = 'public.dl'::regclass), 'America/New_York',
  'LIVENESS: the grid is recorded in New York');
select cmp_ok(pgpm.extend_to('public.dl', (((:'fbd'::date + 3)::timestamp + time '12:00') at time zone 'America/New_York')::text), '>', 0,
  'LIVENESS: extend_to walked the daily grid across the fall-back');
select is((select max(lo::timestamptz) from pgpm.part where parent_table = 'public.dl'::regclass and attached),
  ((:'fbd'::date + 3)::timestamp at time zone 'America/New_York') - interval '1 hour',
  'LIVENESS: the newest cell starts 23:00 EST on the Wednesday after the fall-back (the 04:00Z lattice, seen from EST)');

-- the two cells straddling the transition: 00:00 EDT Sunday and 23:00 EST Sunday
select is(
  (select string_agg(child_name || '=' || lo, ',' order by lo::timestamptz) from pgpm.part
    where parent_table = 'public.dl'::regclass and attached
      and lo::timestamptz in ((:'fbd'::date::timestamp at time zone 'America/New_York'),
                              ((:'fbd'::date + 1)::timestamp at time zone 'America/New_York') - interval '1 hour')),
  format('dl_p%s=%s,dl_p%s=%s',
         to_char(:'fbd'::date, 'YYYY_MM_DD'), (:'fbd'::date::timestamp at time zone 'America/New_York')::text,
         to_char(:'fbd'::date + 1, 'YYYY_MM_DD'), (((:'fbd'::date + 1)::timestamp at time zone 'America/New_York') - interval '1 hour')::text),
  'both cells exist, named by the UTC dates they start on (the second was skipped as a duplicate name before)');
select is(
  (select string_agg(child_name || ' ends ' || hi || ' but the next starts ' || nlo, '; ' order by lo)
     from (select child_name, lo::timestamptz as lo, hi::timestamptz as hi,
                  lead(lo::timestamptz) over (order by lo::timestamptz) as nlo
             from pgpm.part where parent_table = 'public.dl'::regclass and attached) w
    where nlo is not null and hi <> nlo),
  null::text, 'the daily grid is contiguous across the fall-back: every hi equals the next lo');
insert into public.dl values (((:'fbd'::date + 1)::timestamp + time '12:00') at time zone 'America/New_York', 2, 'monday noon');
select is(
  (select c.relname::text from public.dl e join pg_class c on c.oid = e.tableoid where e.payload = 'monday noon'),
  'dl_p' || to_char(:'fbd'::date + 1, 'YYYY_MM_DD'),
  'a write at noon on the Monday after the fall-back lands in the cell that starts 23:00 EST Sunday');

-- ==================== (c) set_partition_tz on a day grid moves nothing ====================
set timezone = 'UTC';
create table public.dz (id bigint generated by default as identity, ts timestamptz not null, payload text,
  primary key (id, ts));
insert into public.dz (ts, payload) values (now() - interval '3 days', 'old');
call pgpm.transmute('public.dz', 'ts', interval '1 day', p_obtain => 3);
select is((select partition_tz from pgpm.config where parent_table = 'public.dz'::regclass), 'UTC',
  'LIVENESS: the daily grid was built in UTC');
select max(hi::timestamptz)::text as dz_top from pgpm.part where parent_table = 'public.dz'::regclass and attached \gset
select is(
  (select string_agg(child_name, ',' order by lo::timestamptz) from pgpm.part where parent_table = 'public.dz'::regclass and attached
    and lo::timestamptz >= :'dz_top'::timestamptz - interval '3 days'),
  (select string_agg('dz_p' || to_char(d, 'YYYY_MM_DD'), ',' order by d)
     from generate_series(:'dz_top'::timestamptz - interval '3 days', :'dz_top'::timestamptz - interval '1 day', interval '1 day') d),
  'LIVENESS: the forward children are named by their UTC dates');

-- a change to a zone west of UTC: before the fix every cell''s New York label was its predecessor''s UTC label
select lives_ok($$ select pgpm.set_partition_tz('public.dz', 'America/New_York') $$,
  'set_partition_tz accepts the change on a day-denominated grid (an absolute lattice in every zone)');
select is(
  (select string_agg(method, ',') from pgpm.log where parent_table = 'public.dz'::regclass and action = 'set_partition_tz'),
  'UTC -> America/New_York', 'and logged it');
select pgpm.set_obtain('public.dz', 6);
select cmp_ok(pgpm.obtain('public.dz'), '>', 0, 'LIVENESS: obtain built new partitions under the new zone');
select is(
  (select child_name::text from pgpm.part where parent_table = 'public.dz'::regclass and attached
    and lo::timestamptz = :'dz_top'::timestamptz),
  'dz_p' || to_char(:'dz_top'::timestamptz at time zone 'UTC', 'YYYY_MM_DD'),
  'the first cell past the pre-change top exists and still carries its UTC-date name (it took the last existing child''s name before, and was skipped)');
select is(
  (select string_agg(child_name || ' ends ' || hi || ' but the next starts ' || nlo, '; ' order by lo)
     from (select child_name, lo::timestamptz as lo, hi::timestamptz as hi,
                  lead(lo::timestamptz) over (order by lo::timestamptz) as nlo
             from pgpm.part where parent_table = 'public.dz'::regclass and attached) w
    where nlo is not null and hi <> nlo),
  null::text, 'the grid is contiguous after the zone change: every hi equals the next lo');
insert into public.dz (ts, payload) values (:'dz_top'::timestamptz + interval '12 hours', 'first new cell');
select is(
  (select c.relname::text from public.dz e join pg_class c on c.oid = e.tableoid where e.payload = 'first new cell'),
  'dz_p' || to_char(:'dz_top'::timestamptz at time zone 'UTC', 'YYYY_MM_DD'),
  'a write into the first cell past the pre-change top lands in it');

select * from finish();

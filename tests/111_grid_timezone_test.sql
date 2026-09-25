-- The grid is computed in a RECORDED zone, never in the caller's session TimeZone (issue #455).
--
-- Two defects, one root cause. (1) _grid_floor/_grid_next/_part_name evaluated date_trunc, extract,
-- `+ interval` and to_char in whatever zone the calling session had, so an operator transmuting under
-- America/New_York built children on the 00:00-04/-05 lattice and pg_cron, under the server's UTC,
-- computed obtain's candidates on the 00:00+00 lattice, found every one half-overlapping an existing
-- child, skipped it, and left a permanent hole about p_obtain steps out. (2) `+ '1 day'` on a timestamptz
-- is a CALENDAR day in the session zone (23 or 25 hours across a DST transition) while _grid_floor's
-- fixed-seconds branch is an absolute 86400 s lattice, so on any DST-observing session the two disagreed
-- by an hour every autumn and the delta went uncovered.
--
-- The fix records the transmuting session's zone in pgpm.config.partition_tz and passes it into every
-- adapter call, so the same table gets the same bounds and names from any session, and makes every
-- day-denominated step an absolute number of seconds so _grid_floor and _grid_next share one lattice.
--
-- Every negative below ("no hole", "same result") is paired with a witness that the condition it denies
-- was present: that the two lattices genuinely differ, that the chosen day really has a fall-back, that
-- the second builder really ran. bench/grid_timezone.sh runs this file against a mutant that puts the
-- session-zone arithmetic back (grid_session_timezone), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(55);

-- ==================== (a) the adapter is zone-explicit ====================
-- Each pair is computed twice, under two session zones, with the SAME zone argument, and must agree.
-- The month case straddles the spring-forward (March 1 is EST, April 1 is EDT); the day, week and hour
-- cases straddle the 2026-11-01 fall-back. A function that still consulted the session would disagree
-- with itself by an hour in at least one of them.
set timezone = 'America/New_York';
select is(current_setting('TimeZone'), 'America/New_York', 'LIVENESS: the session really is in New York for the first pass');
create temp table a_ny as
select v.step,
       pgpm._grid_floor('time', v.step, '2000-01-01 00:00:00+00', v.probe, 'America/New_York')::timestamptz as fl,
       pgpm._grid_next('time', v.step, v.lo, 'America/New_York')::timestamptz as nx,
       pgpm._part_name('ev', 'time', v.step, v.lo,
                       pgpm._grid_next('time', v.step, v.lo, 'America/New_York'), 'America/New_York')::text as nm
  from (values ('1 month', '2026-03-15 12:00:00+00', '2026-03-01 05:00:00+00'),
               ('1 day',   '2026-11-01 12:00:00+00', '2026-11-01 00:00:00+00'),
               ('1 week',  '2026-11-04 12:00:00+00', '2026-10-31 00:00:00+00'),
               ('1 hour',  '2026-11-01 05:30:00+00', '2026-11-01 05:00:00+00')) v(step, probe, lo);
set timezone = 'UTC';
select is(current_setting('TimeZone'), 'UTC', 'LIVENESS: the session really is in UTC for the second pass');
create temp table a_utc as
select v.step,
       pgpm._grid_floor('time', v.step, '2000-01-01 00:00:00+00', v.probe, 'America/New_York')::timestamptz as fl,
       pgpm._grid_next('time', v.step, v.lo, 'America/New_York')::timestamptz as nx,
       pgpm._part_name('ev', 'time', v.step, v.lo,
                       pgpm._grid_next('time', v.step, v.lo, 'America/New_York'), 'America/New_York')::text as nm
  from (values ('1 month', '2026-03-15 12:00:00+00', '2026-03-01 05:00:00+00'),
               ('1 day',   '2026-11-01 12:00:00+00', '2026-11-01 00:00:00+00'),
               ('1 week',  '2026-11-04 12:00:00+00', '2026-10-31 00:00:00+00'),
               ('1 hour',  '2026-11-01 05:30:00+00', '2026-11-01 05:00:00+00')) v(step, probe, lo);

-- the New York pass, value by value (hand-derived, not read back from the code under test)
select is((select fl from a_ny where step = '1 month'), '2026-03-01 05:00:00+00'::timestamptz,
  'month floor is New York midnight March 1 (EST), computed under a New York session');
select is((select nx from a_ny where step = '1 month'), '2026-04-01 04:00:00+00'::timestamptz,
  'month next is New York midnight April 1 (EDT): a calendar month in the pinned zone, across spring-forward');
select is((select nm from a_ny where step = '1 month'), 'ev_p2026_03',
  'month name renders in the pinned zone (March, not February as a UTC rendering of 05:00Z would give)');
select is((select fl from a_ny where step = '1 day'), '2026-11-01 00:00:00+00'::timestamptz,
  'day floor sits on the absolute 86400 s lattice from the anchor');
select is((select nx from a_ny where step = '1 day'), '2026-11-02 00:00:00+00'::timestamptz,
  'day next is exactly 86400 s later across the fall-back, not the 25 h calendar day New York would add');
select is((select nm from a_ny where step = '1 day'), 'ev_p2026_11_01',
  'day name is the UTC date of the cell start (00:00Z is 20:00 EDT on October 31, but a fixed-step cell is labelled in UTC like the hourly ones below, so adjacent cells never share a name; #503)');
select is((select fl from a_ny where step = '1 week'), '2026-10-31 00:00:00+00'::timestamptz,
  'week floor: 2026-10-31 is a whole number of weeks after the Saturday anchor');
select is((select nx from a_ny where step = '1 week'), '2026-11-07 00:00:00+00'::timestamptz,
  'week next is exactly 604800 s later across the fall-back');
select is((select nx from a_ny where step = '1 hour'), '2026-11-01 06:00:00+00'::timestamptz,
  'hour next is 3600 s later');
select is((select nm from a_ny where step = '1 hour'), 'ev_p2026_11_01_05',
  'sub-day names render in UTC: 05:00Z and 06:00Z are both 01:00 on a New York wall clock that autumn night');
select is(pgpm._part_name('ev', 'time', '1 hour', '2026-11-01 06:00:00+00', '2026-11-01 07:00:00+00', 'America/New_York')::text,
  'ev_p2026_11_01_06',
  'the very next hourly cell gets a DIFFERENT name (a wall-clock rendering would collide and obtain would skip it)');
select is(pgpm._grid_floor('time', '1 day', '2000-01-01 00:00:00+00', '2026-11-02 00:30:00+00', 'America/New_York')::timestamptz,
  (select nx from a_ny where step = '1 day'),
  'the two lattices agree: flooring a value just past day-next lands exactly on day-next');

-- and the UTC pass equals the New York pass, all eight values at once
select is(
  (select string_agg(step || '=' || fl || '/' || nx || '/' || nm, '; ' order by step) from a_utc),
  (select string_agg(step || '=' || fl || '/' || nx || '/' || nm, '; ' order by step) from a_ny),
  'floor, next and name for month, day, week and hour are identical under a UTC session and a New York session');

-- ==================== (b) transmute under New York, maintain under UTC ====================
set timezone = 'America/New_York';
create table public.gt_ev (id bigint generated by default as identity, ts timestamptz not null, payload text,
  primary key (id, ts));
insert into public.gt_ev (ts, payload) values (now() - interval '200 days', 'old'), (now() - interval '20 days', 'recent');
-- p_obtain => 0 so transmute builds NO forward grid: every forward child below is minted by the UTC session
call pgpm.transmute('public.gt_ev', 'ts', interval '1 month', p_obtain => 0);

select is((select partition_tz from pgpm.config where parent_table = 'public.gt_ev'::regclass), 'America/New_York',
  'transmute recorded the transmuting session''s zone in config.partition_tz');
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.gt_ev'::regclass order by lo::timestamptz limit 1),
  (date_trunc('month', now() at time zone 'America/New_York') + interval '1 month') at time zone 'America/New_York',
  'LIVENESS: the monolith''s upper bound is the New York month boundary');
select isnt(
  (date_trunc('month', now() at time zone 'America/New_York') + interval '1 month') at time zone 'America/New_York',
  (date_trunc('month', now() at time zone 'UTC') + interval '1 month') at time zone 'UTC',
  'LIVENESS: the New York and UTC month boundaries are different instants, so the two lattices genuinely differ');

set timezone = 'UTC';
select pgpm.set_obtain('public.gt_ev', 4);
select is(pgpm.obtain('public.gt_ev'), 4, 'obtain under a UTC session built the four forward partitions past the monolith');
select cmp_ok(pgpm.extend_to('public.gt_ev', (now() + interval '400 days')::text), '>', 0,
  'extend_to under a UTC session built more');

select is(
  (select string_agg(child_name || ' ends ' || hi || ' but the next starts ' || nlo, '; ' order by lo)
     from (select child_name, lo::timestamptz as lo, hi::timestamptz as hi,
                  lead(lo::timestamptz) over (order by lo::timestamptz) as nlo
             from pgpm.part where parent_table = 'public.gt_ev'::regclass and attached) w
    where nlo is not null and hi <> nlo),
  null::text,
  'the grid built under UTC continues the New York lattice: every hi equals the next lo');
select is(
  (select string_agg(child_name, ',' order by lo::timestamptz) from pgpm.part
    where parent_table = 'public.gt_ev'::regclass and attached
      and lo::timestamptz >= (date_trunc('month', now() at time zone 'America/New_York') + interval '1 month') at time zone 'America/New_York'),
  (select string_agg('gt_ev_p' || to_char(m, 'YYYY_MM'), ',' order by m)
     from generate_series(date_trunc('month', now() at time zone 'America/New_York') + interval '1 month',
                          date_trunc('month', (now() + interval '400 days') at time zone 'America/New_York'),
                          interval '1 month') m),
  'the forward children are named exactly as New York would name them, month by month');
select is(
  (select count(*)::int from pgpm.part
    where parent_table = 'public.gt_ev'::regclass and attached
      and (lo::timestamptz at time zone 'America/New_York') <> date_trunc('month', lo::timestamptz at time zone 'America/New_York')),
  0, 'every lower bound is a New York month start (none is on the UTC lattice the maintaining session would have used)');
insert into public.gt_ev (ts, payload) values (now() + interval '100 days', 'future');
select is(
  (select c.relname::text from public.gt_ev e join pg_class c on c.oid = e.tableoid where e.payload = 'future'),
  'gt_ev_p' || to_char((now() + interval '100 days') at time zone 'America/New_York', 'YYYY_MM'),
  'a write 100 days out lands in the New York-named child for its month');

-- ==================== (c) a daily uuidv7 grid across the fall-back ====================
-- The frontier of a uuidv7 grid is data-driven, so inserted rows advance the clock. The transition is the
-- first Sunday of November, chosen relative to now() so the file keeps testing a FUTURE fall-back.
set timezone = 'America/New_York';
create temp table fb as
select d from (select make_date(y, 11, 1) + ((7 - extract(dow from make_date(y, 11, 1))::int) % 7) as d
                 from generate_series(extract(year from now())::int, extract(year from now())::int + 1) y) s
 where d > (now() at time zone 'America/New_York')::date + 3
 order by d limit 1;
select is(
  (((select d from fb)::timestamp + time '03:30') at time zone 'America/New_York')
    - (((select d from fb)::timestamp + time '00:30') at time zone 'America/New_York'),
  interval '4 hours',
  'LIVENESS: the chosen day has a fall-back (three wall-clock hours span four real hours)');

create table public.gt_u (id uuid primary key, payload text);
insert into public.gt_u values (pgpm._ts_to_uuid(now()), 'seed');
call pgpm.transmute('public.gt_u', 'id', interval '1 day', p_obtain => 2);
select is((select partition_tz from pgpm.config where parent_table = 'public.gt_u'::regclass), 'America/New_York',
  'the uuidv7 table recorded New York too');

-- one builder walks the chain across the transition...
select cmp_ok(
  pgpm.extend_to('public.gt_u',
    pgpm._ts_to_uuid(((select d from fb)::timestamp + interval '4 days 12 hours') at time zone 'America/New_York')::text),
  '>', 0, 'extend_to walked the daily grid across the fall-back');
-- ...then the frontier moves to the chain's tail and a SECOND builder floors it afresh. This is the meeting
-- point where a chain shifted by an hour used to half-overlap every candidate and leave a 23 h hole.
insert into public.gt_u values
  (pgpm._ts_to_uuid(((select d from fb)::timestamp + interval '4 days 12 hours') at time zone 'America/New_York'), 'tail');
select pgpm.obtain('public.gt_u');
select is((select max(hi::timestamptz) from pgpm.part where parent_table = 'public.gt_u'::regclass and attached),
  ((select d from fb) + 7)::timestamp at time zone 'UTC',
  'LIVENESS: obtain extended the grid two cells past the chain, so the two builders met');
select is(
  (select string_agg(child_name || ' ends ' || hi || ' but the next starts ' || nlo, '; ' order by lo)
     from (select child_name, lo::timestamptz as lo, hi::timestamptz as hi,
                  lead(lo::timestamptz) over (order by lo::timestamptz) as nlo
             from pgpm.part where parent_table = 'public.gt_u'::regclass and attached) w
    where nlo is not null and hi <> nlo),
  null::text,
  'the daily grid is contiguous across the fall-back: every hi equals the next lo');

-- the ambiguous hour: 01:30 EDT and 01:30 EST are different instants with the same wall reading
insert into public.gt_u values
  (pgpm._ts_to_uuid((((select d from fb)::timestamp + time '01:30') at time zone 'America/New_York') - interval '1 hour'), 'edt'),
  (pgpm._ts_to_uuid((((select d from fb)::timestamp + time '01:30') at time zone 'America/New_York')), 'est');
select is(
  to_char(((((select d from fb)::timestamp + time '01:30') at time zone 'America/New_York') - interval '1 hour') at time zone 'America/New_York', 'HH24:MI')
    || '/' || to_char((((select d from fb)::timestamp + time '01:30') at time zone 'America/New_York') at time zone 'America/New_York', 'HH24:MI'),
  '01:30/01:30',
  'LIVENESS: the two rows really share a wall-clock reading an hour apart');
select is(
  (select string_agg(e.payload || '=' || c.relname, ',' order by e.payload)
     from public.gt_u e join pg_class c on c.oid = e.tableoid where e.payload in ('edt', 'est')),
  'edt=gt_u_p' || to_char((select d from fb), 'YYYY_MM_DD') || ',est=gt_u_p' || to_char((select d from fb), 'YYYY_MM_DD'),
  'both land in the one cell that covers them (the cell starting 00:00Z on the Sunday, labelled by that UTC date although it starts 20:00 EDT the evening before)');
select is(
  (select c.relname::text from public.gt_u e join pg_class c on c.oid = e.tableoid where e.payload = 'tail'),
  'gt_u_p' || to_char((select d from fb) + 4, 'YYYY_MM_DD'),
  'the row four days past the transition (the hunt''s failing insert) landed in its cell');

-- ==================== (d) timestamp and date control columns ====================
-- A naive value has no zone of its own. It is read as WALL TIME IN partition_tz, so the same table gets
-- the same bounds whichever session builds them: the monolith (built under New York) and the forward
-- children (built under UTC) must meet on the same wall-clock literal.
set timezone = 'America/New_York';
create table public.gt_n (id bigint generated by default as identity, ts timestamp not null, payload text,
  primary key (id, ts));
create table public.gt_d (id bigint generated by default as identity, d date not null, payload text,
  primary key (id, d));
insert into public.gt_n (ts, payload) values ((now() at time zone 'America/New_York') - interval '100 days', 'old');
insert into public.gt_d (d, payload) values (((now() at time zone 'America/New_York') - interval '100 days')::date, 'old');
-- p_obtain => 0 again: the monolith is New York's work, every forward child is UTC's
call pgpm.transmute('public.gt_n', 'ts', interval '1 month', p_obtain => 0);
call pgpm.transmute('public.gt_d', 'd', interval '1 month', p_obtain => 0);
set timezone = 'UTC';
select pgpm.extend_to('public.gt_n', ((now() at time zone 'America/New_York') + interval '300 days')::text);
select pgpm.extend_to('public.gt_d', (((now() at time zone 'America/New_York') + interval '300 days')::date)::text);

create temp view bounds as
  select p.parent_table, p.child_name, p.lo::timestamptz as lo, p.hi::timestamptz as hi,
         pg_get_expr(c.relpartbound, c.oid) as bound
    from pgpm.part p join pg_class c on c.oid = p.child_oid
   where p.attached;

-- timestamp without time zone
select is(
  (select string_agg(child_name || ' ends ' || hi || ' but the next starts ' || nlo, '; ' order by lo)
     from (select child_name, lo, hi, lead(lo) over (order by lo) as nlo from bounds
            where parent_table = 'public.gt_n'::regclass) w
    where nlo is not null and hi <> nlo),
  null::text, 'timestamp column: the grid is contiguous as instants');
select is(
  (select bound from bounds where parent_table = 'public.gt_n'::regclass order by lo limit 1),
  format('FOR VALUES FROM (%L) TO (%L)',
         to_char(date_trunc('month', (now() at time zone 'America/New_York') - interval '100 days'), 'YYYY-MM-DD HH24:MI:SS'),
         to_char(date_trunc('month', now() at time zone 'America/New_York') + interval '1 month', 'YYYY-MM-DD HH24:MI:SS')),
  'timestamp column: the monolith (built under New York) is bounded by New York wall-clock month starts');
select is(
  (select string_agg(bound, '; ' order by lo) from bounds
    where parent_table = 'public.gt_n'::regclass
      and lo >= (date_trunc('month', now() at time zone 'America/New_York') + interval '1 month') at time zone 'America/New_York'),
  (select string_agg(format('FOR VALUES FROM (%L) TO (%L)', to_char(m, 'YYYY-MM-DD HH24:MI:SS'),
                            to_char(m + interval '1 month', 'YYYY-MM-DD HH24:MI:SS')), '; ' order by m)
     from generate_series(date_trunc('month', now() at time zone 'America/New_York') + interval '1 month',
                          date_trunc('month', (now() at time zone 'America/New_York') + interval '300 days'),
                          interval '1 month') m),
  'timestamp column: the forward children (built under UTC) carry the same wall-clock literals New York would, meeting the monolith exactly');
insert into public.gt_n (ts, payload) values ((now() at time zone 'America/New_York') + interval '45 days', 'future');
select is(
  (select c.relname::text from public.gt_n e join pg_class c on c.oid = e.tableoid where e.payload = 'future'),
  'gt_n_p' || to_char((now() at time zone 'America/New_York') + interval '45 days', 'YYYY_MM'),
  'timestamp column: a write 45 days out lands in the child for its wall-clock month');

-- date
select is(
  (select string_agg(child_name || ' ends ' || hi || ' but the next starts ' || nlo, '; ' order by lo)
     from (select child_name, lo, hi, lead(lo) over (order by lo) as nlo from bounds
            where parent_table = 'public.gt_d'::regclass) w
    where nlo is not null and hi <> nlo),
  null::text, 'date column: the grid is contiguous as instants');
select is(
  (select bound from bounds where parent_table = 'public.gt_d'::regclass order by lo limit 1),
  format('FOR VALUES FROM (%L) TO (%L)',
         to_char(date_trunc('month', (now() at time zone 'America/New_York') - interval '100 days'), 'YYYY-MM-DD'),
         to_char(date_trunc('month', now() at time zone 'America/New_York') + interval '1 month', 'YYYY-MM-DD')),
  'date column: the monolith is bounded by the first of the month, as New York counts months');
select is(
  (select string_agg(bound, '; ' order by lo) from bounds
    where parent_table = 'public.gt_d'::regclass
      and lo >= (date_trunc('month', now() at time zone 'America/New_York') + interval '1 month') at time zone 'America/New_York'),
  (select string_agg(format('FOR VALUES FROM (%L) TO (%L)', to_char(m, 'YYYY-MM-DD'),
                            to_char(m + interval '1 month', 'YYYY-MM-DD')), '; ' order by m)
     from generate_series(date_trunc('month', now() at time zone 'America/New_York') + interval '1 month',
                          date_trunc('month', (now() at time zone 'America/New_York') + interval '300 days'),
                          interval '1 month') m),
  'date column: the forward children carry first-of-month literals and meet the monolith exactly');
insert into public.gt_d (d, payload) values (((now() at time zone 'America/New_York') + interval '45 days')::date, 'future');
select is(
  (select c.relname::text from public.gt_d e join pg_class c on c.oid = e.tableoid where e.payload = 'future'),
  'gt_d_p' || to_char((now() at time zone 'America/New_York') + interval '45 days', 'YYYY_MM'),
  'date column: a write 45 days out lands in the child for its month');

-- ==================== (e) set_partition_tz ====================
select throws_like(
  $$ select pgpm.set_partition_tz('public.gt_ev', 'Mars/Olympus_Mons') $$,
  '%pg_timezone_names%', 'set_partition_tz refuses a name that is not in pg_timezone_names');
create table public.gt_unmanaged (id int);
select throws_like(
  $$ select pgpm.set_partition_tz('public.gt_unmanaged', 'UTC') $$,
  '%is not managed%', 'set_partition_tz refuses an unmanaged table');

set timezone = 'America/New_York';
create table public.gt_id (id bigint primary key, payload text);
insert into public.gt_id select g, 'x' from generate_series(1, 100) g;
call pgpm.transmute('public.gt_id', 'id', 1000);
set timezone = 'UTC';
select is((select partition_tz from pgpm.config where parent_table = 'public.gt_id'::regclass), 'UTC',
  'an id grid records UTC even when transmuted under New York: it has no calendar');
select throws_like(
  $$ select pgpm.set_partition_tz('public.gt_id', 'America/New_York') $$,
  '%id grid%', 'set_partition_tz refuses an id grid, whose zone is never consulted');

-- gt_ev sits on the New York month lattice; UTC month starts are not on it, so this would open a hole
select throws_like(
  $$ select pgpm.set_partition_tz('public.gt_ev', 'UTC') $$,
  '%refused%', 'set_partition_tz refuses a zone whose lattice the grid built so far is not on');
select is((select partition_tz from pgpm.config where parent_table = 'public.gt_ev'::regclass), 'America/New_York',
  'the refused calls left partition_tz untouched');
select lives_ok(
  $$ select pgpm.set_partition_tz('public.gt_ev', 'america/new_york') $$,
  'set_partition_tz accepts the zone the grid is on, spelled in any case');
select is((select partition_tz from pgpm.config where parent_table = 'public.gt_ev'::regclass), 'America/New_York',
  'the stored name is the canonical spelling from pg_timezone_names');
select is(
  (select string_agg(method, ',') from pgpm.log where parent_table = 'public.gt_ev'::regclass and action = 'set_partition_tz'),
  'America/New_York -> America/New_York',
  'exactly the accepted call was logged as set_partition_tz, old -> new; the refused ones logged nothing');
-- a daily grid is on the absolute lattice in every zone and its names are UTC dates (#503), so a zone
-- change moves nothing about it
select lives_ok(
  $$ select pgpm.set_partition_tz('public.gt_u', 'Europe/London') $$,
  'set_partition_tz accepts a zone change on a day-denominated grid (same lattice everywhere)');
select is((select partition_tz from pgpm.config where parent_table = 'public.gt_u'::regclass), 'Europe/London',
  'the daily grid records London; its bounds and names are absolute, so nothing else about it changes');

-- ==================== (f) transmute refuses a session zone it could not record ====================
set timezone = 'XYZ5';
select ok(current_setting('TimeZone') = 'XYZ5' and not exists (select 1 from pg_timezone_names where name = 'XYZ5'),
  'LIVENESS: the session accepted a POSIX-style zone that pg_timezone_names does not list');
create table public.gt_posix (id bigint generated by default as identity, ts timestamptz not null, primary key (id, ts));
select throws_like(
  $$ call pgpm.transmute('public.gt_posix', 'ts', interval '1 month') $$,
  '%pg_timezone_names%', 'transmute refuses to record a zone that is not a pg_timezone_names name');
select ok(not exists (select 1 from pgpm.config where parent_table = 'public.gt_posix'::regclass),
  'the refused transmute registered nothing');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.gt_posix'::regclass and conname = 'pgpm_monolith_bound'),
  'the refused transmute left no bound behind: it refused before its first commit');
set timezone = 'UTC';

select * from finish();

-- A timestamp or date control column has no zone: its grid is its own wall clock (issue #504).
--
-- pgpm read a naive (timestamp without time zone, date) value as wall time in partition_tz, the
-- transmuting session's zone, computed the grid on the resulting instants, and rendered every bound back
-- as wall time in that zone with its offset, which the naive column then discarded. For a calendar step
-- that round-trips (midnight on the 1st in the zone is midnight on the 1st on the column), but the fixed
-- steps are an absolute lattice of seconds, and in a zone with an offset that lattice does not sit on the
-- column's own clock: under America/New_York the 00:00Z day boundary rendered as 20:00 the previous day,
-- a date column read it as the previous DATE, the monolith's CHECK excluded every row dated today, and
-- phase 2's VALIDATE failed with a raw 23514 after phase 1 had committed, leaving a NOT VALID CHECK that
-- rejected every insert dated today. With an hourly step the two cells either side of the autumn
-- fall-back rendered to the same naive wall time (05:00Z and 06:00Z are both 01:00 in New York), so
-- CREATE TABLE refused the second as an empty range and the grid could never extend past that hour. And
-- set_partition_tz accepted a zone change for such a column, after which every new bound literal was
-- rendered in a different zone from the existing ones: pgpm.part and pg_class disagreed and a wall-clock
-- hole opened.
--
-- The fix is the invariant: a naive column's values are wall readings, and the grid is computed on that
-- wall clock directly, so a day is [D 00:00, D+1 00:00) in the column's own values, an hour [H:00,
-- H+1:00), a month [1st 00:00, next 1st 00:00), and every bound literal is that reading with no offset.
-- That is the UTC lattice, so transmute records partition_tz = 'UTC' for a naive column (as for an id
-- grid) whatever the session's zone, and set_partition_tz refuses to change it.
--
-- Every negative below is paired with a witness that the condition was present: the session really is
-- in New York, today's 00:00Z boundary really reads as yesterday there, the two hourly cells really share
-- a New York wall time. bench/naive_column_utc_grid.sh runs this file against a mutant that records the
-- session's zone for a naive column again (naive_column_grid_in_session_zone), so it is also required to
-- FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(24);

-- ==================== (a) a date column, a day step, a New York session ====================
set timezone = 'America/New_York';
select is(current_setting('TimeZone'), 'America/New_York', 'LIVENESS: this session is in New York');
select is(((current_date::timestamp at time zone 'UTC') at time zone 'America/New_York')::date, current_date - 1,
  'LIVENESS: today''s 00:00Z day boundary reads as yesterday in New York, so a literal rendered there loses a day on a date column');

create table public.nd (id bigint, d date not null, primary key (id, d));
insert into public.nd select i, current_date - i from generate_series(0, 20) i;
select ok(exists (select 1 from public.nd where d = current_date), 'LIVENESS: the table holds a row dated today');

-- The conversion runs in a second session pinned to New York (as the operator's would be), so that the
-- pre-fix failure inside phase 2 reports as a failed assertion rather than ending this file.
select dblink_connect('nd', 'dbname=' || current_database());
select dblink_exec('nd', $$set timezone = 'America/New_York'$$);
select is((select tz from dblink('nd', 'show timezone') as t(tz text)), 'America/New_York',
  'LIVENESS: the converting session is in New York too');
select lives_ok(
  $$ select dblink_exec('nd', $c$ call pgpm.transmute('public.nd', 'd', interval '1 day', p_obtain => 2) $c$) $$,
  'transmute converts the date column (it failed phase 2''s VALIDATE with a raw 23514 before)');
select dblink_disconnect('nd');

select is((select partition_tz from pgpm.config where parent_table = 'public.nd'::regclass), 'UTC',
  'a date column records partition_tz = UTC: it carries no zone, and its grid is its own wall clock');
select is((select relkind::text from pg_class where oid = 'public.nd'::regclass), 'p', 'the table is partitioned');
select ok(not exists (select 1 from pg_constraint where conname = 'pgpm_monolith_bound'),
  'no pgpm_monolith_bound CHECK is left behind anywhere');
select is(
  (select string_agg(p.child_name || ':' || pg_get_expr(c.relpartbound, c.oid), '; ' order by p.lo::timestamptz)
     from pgpm.part p join pg_class c on c.oid = p.child_oid
    where p.parent_table = 'public.nd'::regclass and p.attached),
  format('nd_p%s_to_%s:FOR VALUES FROM (%L) TO (%L); nd_p%s:FOR VALUES FROM (%L) TO (%L); nd_p%s:FOR VALUES FROM (%L) TO (%L)',
         to_char(current_date - 20, 'YYYY_MM_DD'), to_char((now() at time zone 'UTC')::date + 1, 'YYYY_MM_DD'),
         (current_date - 20)::text, ((now() at time zone 'UTC')::date + 1)::text,
         to_char((now() at time zone 'UTC')::date + 1, 'YYYY_MM_DD'), ((now() at time zone 'UTC')::date + 1)::text, ((now() at time zone 'UTC')::date + 2)::text,
         to_char((now() at time zone 'UTC')::date + 2, 'YYYY_MM_DD'), ((now() at time zone 'UTC')::date + 2)::text, ((now() at time zone 'UTC')::date + 3)::text),
  'the monolith is bounded by whole dates (the oldest row''s date to the day after today) and the two forward cells are the next two dates');
select lives_ok($$ insert into public.nd values (99, current_date) $$, 'a row dated today is accepted');
select is(
  (select c.relname::text from public.nd e join pg_class c on c.oid = e.tableoid where e.id = 99),
  format('nd_p%s_to_%s', to_char(current_date - 20, 'YYYY_MM_DD'), to_char((now() at time zone 'UTC')::date + 1, 'YYYY_MM_DD')),
  'and it landed in the monolith, whose range still covers today');

-- ==================== (b) a timestamp column, an hourly step, across the autumn fall-back ====================
create table public.nh (id bigint, t timestamp not null, primary key (id, t));
insert into public.nh select i, localtimestamp - (i || ' hours')::interval from generate_series(0, 5) i;
call pgpm.transmute('public.nh', 't', interval '1 hour', p_obtain => 2);
select is((select partition_tz from pgpm.config where parent_table = 'public.nh'::regclass), 'UTC',
  'a timestamp column records partition_tz = UTC as well');

-- the next New York fall-back, chosen relative to now() so the file keeps testing a FUTURE one
create temp table fb as
select d from (select make_date(y, 11, 1) + ((7 - extract(dow from make_date(y, 11, 1))::int) % 7) as d
                 from generate_series(extract(year from now())::int, extract(year from now())::int + 1) y) s
 where (d::timestamp at time zone 'America/New_York') > now() + interval '2 days'
 order by d limit 1;
select d as fbd from fb \gset
select is(((:'fbd'::date + interval '5 hours') at time zone 'UTC') at time zone 'America/New_York',
          ((:'fbd'::date + interval '6 hours') at time zone 'UTC') at time zone 'America/New_York',
  'LIVENESS: the 05:00Z and 06:00Z cells of the fall-back night read the same New York wall time (01:00)');
-- the two cells, through the real creation path (extend_to would walk every hour between now and then)
select lives_ok(
  format($$ select pgpm._create_partition(c, 'public', 'nh', null,
                     pgpm._part_name('nh', c.control_kind, c.partition_step, v.lo, v.hi, c.partition_tz), v.lo, v.hi)
              from pgpm.config c,
                   (values (%L, %L), (%L, %L)) v(lo, hi)
             where c.parent_table = 'public.nh'::regclass $$,
         ((:'fbd'::date + interval '5 hours') at time zone 'UTC')::text, ((:'fbd'::date + interval '6 hours') at time zone 'UTC')::text,
         ((:'fbd'::date + interval '6 hours') at time zone 'UTC')::text, ((:'fbd'::date + interval '7 hours') at time zone 'UTC')::text),
  'the two hourly cells either side of the fall-back are both created (the second was an empty range bound before)');
select is(
  (select string_agg(p.child_name || ':' || pg_get_expr(c.relpartbound, c.oid), '; ' order by p.lo::timestamptz)
     from pgpm.part p join pg_class c on c.oid = p.child_oid
    where p.parent_table = 'public.nh'::regclass and p.attached
      and p.lo::timestamptz >= (:'fbd'::date + interval '5 hours') at time zone 'UTC'),
  format('nh_p%s_05:FOR VALUES FROM (%L) TO (%L); nh_p%s_06:FOR VALUES FROM (%L) TO (%L)',
         to_char(:'fbd'::date, 'YYYY_MM_DD'), (:'fbd'::date + interval '5 hours')::text, (:'fbd'::date + interval '6 hours')::text,
         to_char(:'fbd'::date, 'YYYY_MM_DD'), (:'fbd'::date + interval '6 hours')::text, (:'fbd'::date + interval '7 hours')::text),
  'their catalog bounds are consecutive wall hours on the column''s own clock, 05:00 to 06:00 to 07:00');
insert into public.nh values (7, :'fbd'::date + interval '6 hours 30 minutes');
select is(
  (select c.relname::text from public.nh e join pg_class c on c.oid = e.tableoid where e.id = 7),
  'nh_p' || to_char(:'fbd'::date, 'YYYY_MM_DD') || '_06',
  'a row at 06:30 on the column''s clock lands in the 06:00 cell');

-- ==================== (c) set_partition_tz is refused for a naive column ====================
set timezone = 'UTC';
create table public.nz (id bigint generated by default as identity, ts timestamp not null, primary key (ts, id));
insert into public.nz (ts) select now()::timestamp - (g || ' hours')::interval from generate_series(1, 50) g;
call pgpm.transmute('public.nz', 'ts', interval '1 day', p_obtain => 3);
select is((select partition_tz from pgpm.config where parent_table = 'public.nz'::regclass), 'UTC',
  'LIVENESS: the daily grid on the timestamp column is recorded as UTC');
select throws_like(
  $$ select pgpm.set_partition_tz('public.nz', 'America/New_York') $$,
  '%carries no zone%',
  'set_partition_tz refuses a zone for a timestamp column: it has none, and rendering new bounds in one would shift them against the existing partitions');
select is((select partition_tz from pgpm.config where parent_table = 'public.nz'::regclass), 'UTC',
  'the refusal left partition_tz untouched');
select is((select count(*)::int from pgpm.log where parent_table = 'public.nz'::regclass and action = 'set_partition_tz'), 0,
  'and logged nothing');

-- the grid keeps extending on the one wall clock: what pgpm.part renders for each cell IS its catalog bound
select pgpm.set_obtain('public.nz', 6);
select cmp_ok(pgpm.obtain('public.nz'), '>', 0, 'LIVENESS: obtain extended the grid after the refused call');
create temp table nz_bounds as
select p.child_name, p.lo,
       pgpm._encode(c.control_kind, p.lo, null, null, null, null, null, 0, '1970-01-01', c.partition_tz)::timestamp as pgpm_lo_wall,
       substring(pg_get_expr(k.relpartbound, k.oid) from $$FROM \('([^']+)'\)$$)::timestamp as catalog_lo_wall,
       substring(pg_get_expr(k.relpartbound, k.oid) from $$TO \('([^']+)'\)$$)::timestamp as catalog_hi_wall
  from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table join pg_class k on k.oid = p.child_oid
 where p.parent_table = 'public.nz'::regclass and p.attached;
select is((select string_agg(format('%s: pgpm says lo=%s, catalog says %s', child_name, pgpm_lo_wall, catalog_lo_wall), '; ' order by lo::timestamptz)
             from nz_bounds where pgpm_lo_wall <> catalog_lo_wall),
  null, 'every attached partition''s catalog lower bound is the literal pgpm.part renders for it');
select is((select string_agg(format('gap after %s: [%s, %s)', a.child_name, a.catalog_hi_wall, b.catalog_lo_wall), '; ')
             from nz_bounds a join nz_bounds b
               on b.catalog_lo_wall = (select min(catalog_lo_wall) from nz_bounds where catalog_lo_wall > a.catalog_lo_wall)
            where a.catalog_hi_wall <> b.catalog_lo_wall),
  null, 'the partitions are contiguous on the column''s wall clock');
insert into public.nz (ts) select max(catalog_lo_wall) + interval '1 hour' from nz_bounds;
select is(
  (select string_agg(c.relname::text, ',') from public.nz e join pg_class c on c.oid = e.tableoid
    where e.ts = (select max(catalog_lo_wall) + interval '1 hour' from nz_bounds)),
  (select child_name::text from nz_bounds order by catalog_lo_wall desc limit 1),
  'a write into the newest cell lands in it');

select * from finish();

-- Native bounds are rendered the same way in every session, whatever its DateStyle (issue #500).
--
-- Every native time value pgpm stores -- pgpm.part.lo/hi, pgpm.log.lo/hi, config.partition_anchor,
-- transmute_inflight.lo/hi, the archive ledger's bounds -- is text, written by one session and read back
-- with ::timestamptz by another: the operator's transmute writes, pg_cron's maintain reads. A bare
-- timestamptz::text renders in the WRITING session's DateStyle. Under 'SQL, DMY' 1 October 2026 is
-- '01/10/2026 00:00:00 UTC', which a session on the default 'ISO, MDY' reads back as 10 January, so every
-- bound means a different instant to maintenance than it meant to the operator: a monolith whose real hi
-- is next month reads as ending last January, sits below the retention horizon, and retain() drops it
-- with every row in it, today's included.
--
-- The fix routes every render through pgpm._ts_text, which pins DateStyle to ISO for the duration of the
-- call: '2026-10-01 00:00:00+00' is the one form the parser reads identically under every style. Parses
-- are untouched and still honour the caller's session, so session-rendered text (now()::text, a control
-- value read in the caller's session) can still be passed INTO the adapter.
--
-- Every negative below ("nothing dropped", "every row survives") is paired with a witness that the
-- disagreement was really set up: the writing session really was on SQL, DMY and a bare render under it
-- really is day-first, the reading session really is on the default, and the retain step really ran. The
-- load-bearing assertions are positive identities: the stored text, and the instant an MDY session reads
-- it back as. bench/datestyle_bounds.sh runs this file against a mutant that drops the DateStyle pin from
-- _ts_text (datestyle_session_render), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(40);

set timezone = 'UTC';
select is(current_setting('TimeZone'), 'UTC', 'LIVENESS: the session is in UTC, so every expected offset below is +00');

-- ==================== (a) the render helper is DateStyle-explicit ====================
-- One instant, rendered bare and through _ts_text under six DateStyles, and each canonical text read back
-- under the style that produced it. set_config(..., true) is transaction-local, and a DO block is one
-- transaction, so each iteration really runs under its own style and the session's setting is untouched
-- once the block ends.
create temp table styles (style text primary key, plain text, canon text, canon_back timestamptz);
do $$
declare s text;
begin
  foreach s in array array['ISO, MDY', 'ISO, DMY', 'SQL, DMY', 'SQL, MDY', 'Postgres, DMY', 'German, DMY'] loop
    perform set_config('DateStyle', s, true);
    insert into styles (style, plain, canon, canon_back)
    values (s, timestamptz '2026-10-01 00:00:00+00'::text,
            pgpm._ts_text(timestamptz '2026-10-01 00:00:00+00'),
            pgpm._ts_text(timestamptz '2026-10-01 00:00:00+00')::timestamptz);
  end loop;
end $$;

select is((select plain from styles where style = 'SQL, DMY'), '01/10/2026 00:00:00 UTC',
  'LIVENESS: a bare ::text under SQL, DMY renders 1 October day-first');
select is((select plain from styles where style = 'SQL, MDY'), '10/01/2026 00:00:00 UTC',
  'LIVENESS: the same instant under SQL, MDY renders month-first: the two sessions'' texts swap day and month');
select is((select plain from styles where style = 'SQL, DMY')::timestamptz, timestamptz '2026-01-10 00:00:00+00',
  'LIVENESS: read back under the default ISO, MDY, the DMY text is 10 January: the mechanism of the defect');
select is((select array_agg(style order by style) from styles where canon = '2026-10-01 00:00:00+00'),
  array['German, DMY', 'ISO, DMY', 'ISO, MDY', 'Postgres, DMY', 'SQL, DMY', 'SQL, MDY'],
  '_ts_text renders the one ISO 8601 text under all six DateStyles');
select is((select array_agg(style order by style) from styles where canon_back = timestamptz '2026-10-01 00:00:00+00'),
  array['German, DMY', 'ISO, DMY', 'ISO, MDY', 'Postgres, DMY', 'SQL, DMY', 'SQL, MDY'],
  'and that text reads back as 1 October under all six');

set datestyle = 'SQL, DMY';
select is(pgpm._ts_text(timestamptz '2026-10-01 12:34:56.5-04'), '2026-10-01 16:34:56.5+00',
  'fractional seconds and a non-UTC input offset survive the render, under SQL, DMY');
select is(current_setting('DateStyle'), 'SQL, DMY',
  'the pin is scoped to the call: the session''s own DateStyle is untouched afterwards');

-- ==================== (b) every adapter output is canonical; inputs still read in the session style ====================
select is(current_setting('DateStyle'), 'SQL, DMY', 'LIVENESS: the adapter is exercised under SQL, DMY');
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '15/10/2026 12:00:00 UTC', 'UTC'), '2026-10-01 00:00:00+00',
  '_grid_floor (month step) reads a DMY-rendered native in the session style and returns ISO 8601');
select is(pgpm._grid_floor('time', '1 day', '2000-01-01 00:00:00+00', '2026-10-01 12:00:00+00', 'UTC'), '2026-10-01 00:00:00+00',
  '_grid_floor (fixed step) returns ISO 8601');
select is(pgpm._grid_next('time', '1 month', '2026-10-01 00:00:00+00', 'UTC'), '2026-11-01 00:00:00+00',
  '_grid_next (month step) returns ISO 8601');
select is(pgpm._grid_next('time', '1 day', '2026-10-01 00:00:00+00', 'UTC'), '2026-10-02 00:00:00+00',
  '_grid_next (fixed step) returns ISO 8601');
select is(pgpm._decode('uuidv7', pgpm._ts_to_uuid(timestamptz '2026-10-01 00:00:00+00')::text), '2026-10-01 00:00:00+00',
  '_decode of a uuidv7 value returns ISO 8601');
select is(pgpm._decode('text_time', pgpm._ts_to_text_time(timestamptz '2026-10-01 00:00:00+00', 'c', 8, 36, 'ms'), 'c', 8, 36, 'ms'),
  '2026-10-01 00:00:00+00', '_decode of a text_time value returns ISO 8601');

-- ==================== (c) the issue's reproduction: a DMY transmute, an MDY maintain, a `time` table ====================
create table public.ev (id bigint generated always as identity, at timestamptz not null, payload text, primary key (id, at));
insert into public.ev (at, payload) values (now() - interval '100 days', 'old'), (now() - interval '1 day', 'yesterday');
select is(current_setting('DateStyle'), 'SQL, DMY', 'LIVENESS: the transmuting session is on SQL, DMY');
call pgpm.transmute('public.ev', 'at', interval '1 month', p_retain => interval '1 month', p_paused => false);
insert into public.ev (at, payload) values (now(), 'today');

-- The expected bounds, derived without the code under test: the monolith is [floor(min), next(floor(now))),
-- and to_char does not consult DateStyle. Its child is the one with the lowest lo.
select to_char(date_trunc('month', now() - interval '100 days'), 'YYYY-MM-DD HH24:MI:SS') || '+00' as mono_lo,
       to_char(date_trunc('month', now()) + interval '1 month', 'YYYY-MM-DD HH24:MI:SS') || '+00' as mono_hi \gset
select child_name as mono from pgpm.part where parent_table = 'public.ev'::regclass order by lo::timestamptz limit 1 \gset

select is((select lo from pgpm.part where parent_table = 'public.ev'::regclass and child_name = :'mono'), :'mono_lo',
  'the monolith''s lo, as the DMY session stored it, is ISO 8601');
select is((select hi from pgpm.part where parent_table = 'public.ev'::regclass and child_name = :'mono'), :'mono_hi',
  'the monolith''s hi, as the DMY session stored it, is ISO 8601');
select is((select partition_anchor from pgpm.config where parent_table = 'public.ev'::regclass), '2000-01-01 00:00:00+00',
  'config.partition_anchor, rendered from the timestamptz parameter, is ISO 8601');
select is((select lo from pgpm.log where parent_table = 'public.ev'::regclass and action = 'obtain' order by id limit 1), :'mono_hi',
  'the first obtain row''s lo (the bound above the monolith), as the DMY session logged it, is ISO 8601');
select matches(pgpm._frontier_native('public.ev'), '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?\+00$',
  '_frontier_native of a time table returns ISO 8601 from the DMY session');
select is(pgpm._col_to_native((select c from pgpm.config c where parent_table = 'public.ev'::regclass), '15/10/2026 12:00:00 UTC'),
  '2026-10-15 12:00:00+00', '_col_to_native reads a timestamptz column value in the session style and returns ISO 8601');
select is((select newest_bound from pgpm.status() where parent = 'public.ev'::regclass),
  (select to_char(max(hi::timestamptz), 'YYYY-MM-DD HH24:MI:SS') || '+00' from pgpm.part where parent_table = 'public.ev'::regclass),
  'status().newest_bound, a dynamic max(hi) read, renders ISO 8601 from the DMY session');

reset datestyle;
select is(current_setting('DateStyle'), 'ISO, MDY', 'LIVENESS: maintenance runs under the default DateStyle, as pg_cron does');
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.ev'::regclass and child_name = :'mono'),
  date_trunc('month', now()) + interval '1 month',
  'read from the MDY session, the monolith''s hi is the boundary above the clock that the DMY session meant');
select is(pgpm._retain_boundary((select c from pgpm.config c where parent_table = 'public.ev'::regclass))::timestamptz,
  date_trunc('month', now() - interval '1 month'),
  'LIVENESS: the retention horizon is the first of last month, inside the monolith: retain has a live partition to judge');

create table public.st (s text);
do $$ declare v text; begin call pgpm.maintain('public.ev', v); insert into public.st values (v); end $$;
select matches((select s from public.st), '^archived=\d+ dropped=\d+ ', 'LIVENESS: the maintain tick completed');
select unalike((select s from public.st), '%retain_deferred%', 'LIVENESS: its retain step ran rather than being deferred');
select is((select array_agg(payload order by at) from public.ev), array['old', 'yesterday', 'today'],
  'no row of the live table is dropped: old, yesterday and today all survive the MDY tick');
select has_table('public', :'mono', 'the monolith is still attached');
select is((select count(*)::int from pgpm.log where parent_table = 'public.ev'::regclass and action = 'retain_drop'), 0,
  'nothing was retired from public.ev');

-- ==================== (d) the uuidv7 kind ====================
-- The issue's Part A, with its expectation corrected. Since #325 the uuidv7 frontier is
-- greatest(max(control), now()), so the monolith of a table whose data ends in 2020 still runs to the
-- boundary above the clock and IS the live write partition; a correct tick keeps every row, those below
-- the horizon included, because they sit inside it. What discriminates here is the stored text and the
-- instant an MDY session reads it back as.
create table public.u (id uuid primary key, v int);
insert into public.u values (pgpm._ts_to_uuid('2020-01-10 00:00:00+00'), 1), (pgpm._ts_to_uuid('2020-02-10 00:00:00+00'), 2);
select (now() - timestamptz '2020-03-15 00:00:00+00') as ret \gset
set datestyle = 'SQL, DMY';
select is(current_setting('DateStyle'), 'SQL, DMY', 'LIVENESS: the uuidv7 table is transmuted from a SQL, DMY session');
call pgpm.transmute('public.u', 'id', interval '1 month', p_retain => :'ret'::interval, p_paused => false);
insert into public.u values (pgpm._ts_to_uuid('2020-06-10 00:00:00+00'), 6), (pgpm._ts_to_uuid('2021-06-10 00:00:00+00'), 7);
select child_name as umono from pgpm.part where parent_table = 'public.u'::regclass order by lo::timestamptz limit 1 \gset
select is((select lo || ' .. ' || hi from pgpm.part where parent_table = 'public.u'::regclass and child_name = :'umono'),
  '2020-01-01 00:00:00+00 .. ' || :'mono_hi',
  'the uuidv7 monolith''s bounds, as the DMY session stored them, are ISO 8601: the data''s first month up to the boundary above the clock');

reset datestyle;
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.u'::regclass and child_name = :'umono'),
  date_trunc('month', now()) + interval '1 month',
  'read from the MDY session, its hi is the instant the DMY session meant (a bare render would read as 10 January)');
select is(pgpm._retain_boundary((select c from pgpm.config c where parent_table = 'public.u'::regclass))::timestamptz,
  timestamptz '2020-03-01 00:00:00+00',
  'LIVENESS: the retention horizon is 1 March 2020: above rows 1 and 2, below the monolith''s hi');
create table public.stu (s text);
do $$ declare v text; begin call pgpm.maintain('public.u', v); insert into public.stu values (v); end $$;
select unalike((select s from public.stu), '%retain_deferred%', 'LIVENESS: the retain step ran for public.u');
select is((select array_agg(v order by v) from public.u), array[1, 2, 6, 7],
  'every row survives: the monolith is the live write partition, and the rows below the horizon are inside it');
select is((select count(*)::int from pgpm.log where parent_table = 'public.u'::regclass and action = 'retain_drop'), 0,
  'nothing was retired from public.u');

-- ==================== (e) a naive control column: the wall-time rule still renders ISO 8601 ====================
create table public.evn (id bigint generated always as identity, at timestamp not null, primary key (id, at));
insert into public.evn (at) values (now()::timestamp - interval '100 days');
set datestyle = 'SQL, DMY';
call pgpm.transmute('public.evn', 'at', interval '1 month');
select is((select lo from pgpm.part where parent_table = 'public.evn'::regclass order by lo::timestamptz limit 1), :'mono_lo',
  'a naive column''s monolith lo (min read as wall time in partition_tz) is stored as ISO 8601 by the DMY session');
select is(pgpm._col_to_native((select c from pgpm.config c where parent_table = 'public.evn'::regclass), '15/10/2026 12:00:00'),
  '2026-10-15 12:00:00+00', '_col_to_native reads a naive value in the session style, as wall time in partition_tz, and returns ISO 8601');
reset datestyle;

select * from finish();

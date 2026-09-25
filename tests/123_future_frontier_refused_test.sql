-- Issue #457: for uuidv7 and text_time the frontier is greatest(max(control), now()), and until this fix
-- it had no upper sanity bound. One row minted by a client with a wrong clock set the frontier, and so
-- the monolith's PERMANENT upper bound hi, years into the future: every row written today landed in the
-- monolith, status() showed nothing abnormal, and the monolith could not be regrained nor anything behind
-- it dropped until the clock really got there. The sampling gate cannot see it (one bad row in 402 is
-- fraction 0.9975), so transmute now compares the DATA maximum against now() and refuses when it decodes
-- to more than one partition step plus one hour ahead, naming the offending value and its decoded
-- timestamp. p_force_frontier => true accepts the consequence, the same way p_bound_headroom lets an
-- operator ask for a far hi on purpose.
--
-- Every refusal below is paired with a witness that the condition it denies was really present: the
-- sampling gate passes the skewed table (so the refusal is not the sampling gate in disguise), the forced
-- conversion shows the 2031 bound the refusal protects against, and the same table minus the skewed row
-- converts with hi at the first boundary above now().
create extension if not exists pgtap;

select plan(24);

-- ============================================== (A) uuidv7: one 2031 row among 402
create table public.ev_skew (id uuid primary key, body text);
insert into public.ev_skew (id, body)
select pgpm._ts_to_uuid(now() - (g || ' days')::interval), 'valid ' || g from generate_series(1, 401) g;
insert into public.ev_skew (id, body) values (pgpm._ts_to_uuid('2031-06-01 00:00:00+00'), 'skewed client');

-- WITNESS: the issue's premise. The sampling gate that exists for random (v4) columns passes this table,
-- so whatever refuses it below is not that gate.
select cmp_ok(
  (select fraction from pgpm.check_uuidv7('public.ev_skew', 'id', 1000)),
  '>=', 0.95::numeric,
  'uuidv7 WITNESS: one skewed row in 402 sails through the plausibility sampling');

-- check_uuidv7 reports the actual (not sampled) maximum, decoded, and flags it
select is(
  (select newest_decoded from pgpm.check_uuidv7('public.ev_skew', 'id')),
  timestamptz '2031-06-01 00:00:00+00',
  'check_uuidv7.newest_decoded is the decoded actual maximum of the column');
select is(
  (select newest_in_future from pgpm.check_uuidv7('public.ev_skew', 'id')),
  true,
  'check_uuidv7.newest_in_future flags a maximum years ahead of the clock');

-- refused, and the message names the skewed maximum itself and its decoded timestamp
select throws_like(
  $$ call pgpm.transmute('public.ev_skew', 'id', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician:%' || pgpm._ts_to_uuid('2031-06-01 00:00:00+00')::text || '%2031-06-01 00:00:00+00%p_force_frontier%',
  'uuidv7: transmute refuses, naming the offending maximum value, its decoded 2031 timestamp and the override');

select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'ev_skew'),
  'r', 'uuidv7: the refusal is up front, ev_skew is left a plain table');
select ok(
  not exists (select 1 from pgpm.config where parent_table = 'public.ev_skew'::regclass),
  'uuidv7: nothing was registered');

-- LIVENESS for the refusal: forced through, the consequence is exactly the one the refusal describes.
-- The monolith's hi lands at the grid boundary above 2031-06-01, not above now().
call pgpm.transmute('public.ev_skew', 'id', interval '1 month', p_obtain => 2, p_force_frontier => true);
select is(
  (select hi::timestamptz from pgpm.part where parent_table = 'public.ev_skew'::regclass
    order by lo::timestamptz limit 1),
  timestamptz '2031-07-01 00:00:00+00',
  'uuidv7 LIVENESS: with p_force_frontier the monolith hi really is pinned at the 2031-07 boundary');

-- ============================================== (B) uuidv7: the same table without the skewed row
create table public.ev_clean (id uuid primary key, body text);
insert into public.ev_clean (id, body)
select pgpm._ts_to_uuid(now() - (g || ' days')::interval), 'valid ' || g from generate_series(1, 401) g;

select is(
  (select newest_in_future from pgpm.check_uuidv7('public.ev_clean', 'id')),
  false,
  'check_uuidv7.newest_in_future is false when the newest row is in the past');

call pgpm.transmute('public.ev_clean', 'id', interval '1 month', p_obtain => 2);
select is(
  (select hi::timestamptz from pgpm.part where parent_table = 'public.ev_clean'::regclass
    order by lo::timestamptz limit 1),
  pgpm._grid_next('uuidv7', '1 month',
    pgpm._grid_floor('uuidv7', '1 month', '2000-01-01 00:00:00+00', now()::text, 'UTC'), 'UTC')::timestamptz,
  'uuidv7: without the skewed row the same table converts, hi = first grid boundary above now()');

-- ============================================== (C) ordinary clock skew is accepted
create table public.ev_minutes (id uuid primary key, body text);
insert into public.ev_minutes (id, body)
select pgpm._ts_to_uuid(now() - (g || ' days')::interval), 'valid ' || g from generate_series(1, 401) g;
insert into public.ev_minutes (id, body) values (pgpm._ts_to_uuid(now() + interval '5 minutes'), 'a client a few minutes fast');

select is(
  (select newest_in_future from pgpm.check_uuidv7('public.ev_minutes', 'id')),
  false,
  'check_uuidv7.newest_in_future does not flag a few minutes of ordinary skew');

call pgpm.transmute('public.ev_minutes', 'id', interval '1 month', p_obtain => 2);
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'ev_minutes'),
  'p', 'uuidv7: a row a few minutes ahead of the clock (ordinary skew) is accepted without an override');
select is(
  (select hi::timestamptz from pgpm.part where parent_table = 'public.ev_minutes'::regclass
    order by lo::timestamptz limit 1),
  pgpm._grid_next('uuidv7', '1 month',
    pgpm._grid_floor('uuidv7', '1 month', '2000-01-01 00:00:00+00',
      greatest(pgpm._uuid_to_ts((select id from public.ev_minutes order by id desc limit 1)), now())::text, 'UTC'), 'UTC')::timestamptz,
  'uuidv7: and its hi is the boundary above the frontier, greatest(max, now())');

-- ============================================== (C2) the allowance is one step plus one hour, pinned
-- from both sides on a daily grid: 1 day + 30 min is inside it, 1 day + 90 min is outside it.
create table public.ev_inside (id uuid primary key, body text);
insert into public.ev_inside (id, body)
select pgpm._ts_to_uuid(now() - (g || ' days')::interval), 'valid ' || g from generate_series(1, 40) g;
insert into public.ev_inside (id, body) values
  (pgpm._ts_to_uuid(now() + interval '1 day' + interval '30 minutes'), 'just inside the allowance');
call pgpm.transmute('public.ev_inside', 'id', interval '1 day', p_obtain => 2);
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'ev_inside'),
  'p', 'allowance: a maximum one step + 30 min ahead is inside one step + one hour and converts');

create table public.ev_outside (id uuid primary key, body text);
insert into public.ev_outside (id, body)
select pgpm._ts_to_uuid(now() - (g || ' days')::interval), 'valid ' || g from generate_series(1, 40) g;
insert into public.ev_outside (id, body) values
  (pgpm._ts_to_uuid(now() + interval '1 day' + interval '90 minutes'), 'just outside the allowance');
select is(
  (select newest_in_future from pgpm.check_uuidv7('public.ev_outside', 'id')),
  true,
  'check_uuidv7.newest_in_future flags a maximum more than an hour ahead');
select throws_like(
  $$ call pgpm.transmute('public.ev_outside', 'id', interval '1 day', p_obtain => 2) $$,
  'pg_partition_magician:%' || (select id::text from public.ev_outside order by id desc limit 1) || '%p_force_frontier%',
  'allowance: a maximum one step + 90 min ahead is outside one step + one hour and is refused, by name');

-- ============================================== (D) text_time (cuid-shaped): the same two cases
create table public.tt_skew (id text primary key, body text);
insert into public.tt_skew (id, body)
select pgpm._ts_to_text_time(now() - (g || ' days')::interval, 'c', 8, 36, 'ms'), 'valid ' || g
from generate_series(1, 401) g;
insert into public.tt_skew (id, body)
values (pgpm._ts_to_text_time('2031-06-01 00:00:00+00', 'c', 8, 36, 'ms'), 'skewed client');

select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tt_skew', 'id', 'c', 8, 36, 'ms', 1000)),
  '>=', 0.95::numeric,
  'text_time WITNESS: one skewed row in 402 sails through the plausibility sampling');
select is(
  (select newest_decoded from pgpm.check_text_time('public.tt_skew', 'id', 'c', 8, 36, 'ms')),
  timestamptz '2031-06-01 00:00:00+00',
  'check_text_time.newest_decoded is the decoded actual maximum of the column');
select is(
  (select newest_in_future from pgpm.check_text_time('public.tt_skew', 'id', 'c', 8, 36, 'ms')),
  true,
  'check_text_time.newest_in_future flags a maximum years ahead of the clock');

select throws_like(
  $$ call pgpm.transmute('public.tt_skew', 'id', interval '1 month', p_obtain => 2,
       p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms') $$,
  'pg_partition_magician:%' || pgpm._ts_to_text_time('2031-06-01 00:00:00+00', 'c', 8, 36, 'ms') || '%2031-06-01 00:00:00+00%p_force_frontier%',
  'text_time: transmute refuses, naming the offending maximum value, its decoded 2031 timestamp and the override');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'tt_skew'),
  'r', 'text_time: the refusal is up front, tt_skew is left a plain table');

create table public.tt_clean (id text primary key, body text);
insert into public.tt_clean (id, body)
select pgpm._ts_to_text_time(now() - (g || ' days')::interval, 'c', 8, 36, 'ms'), 'valid ' || g
from generate_series(1, 401) g;
insert into public.tt_clean (id, body)
values (pgpm._ts_to_text_time(now() + interval '5 minutes', 'c', 8, 36, 'ms'), 'a client a few minutes fast');

select is(
  (select newest_in_future from pgpm.check_text_time('public.tt_clean', 'id', 'c', 8, 36, 'ms')),
  false,
  'check_text_time.newest_in_future does not flag a few minutes of ordinary skew');

call pgpm.transmute('public.tt_clean', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'tt_clean'),
  'p', 'text_time: without the skewed row (and with a few minutes of skew) the same table converts');
select is(
  (select hi::timestamptz from pgpm.part where parent_table = 'public.tt_clean'::regclass
    order by lo::timestamptz limit 1),
  pgpm._grid_next('text_time', '1 month',
    pgpm._grid_floor('text_time', '1 month', '2000-01-01 00:00:00+00',
      greatest(pgpm._text_time_to_ts((select id from public.tt_clean order by id desc limit 1), 'c', 8, 36, 'ms'), now())::text, 'UTC'), 'UTC')::timestamptz,
  'text_time: its hi is the boundary above the frontier, greatest(max, now())');

-- check_text_time must not raise when the column's maximum does not even match the declared shape
-- (one malformed row must not abort the check): newest_decoded is null for it instead.
create table public.tt_junk_max (id text primary key, body text);
insert into public.tt_junk_max (id, body) values
  (pgpm._ts_to_text_time(now() - interval '1 day', 'c', 8, 36, 'ms'), 'shaped'),
  ('zzzz-not-a-cuid', 'sorts above every cuid');
select is(
  (select newest_decoded from pgpm.check_text_time('public.tt_junk_max', 'id', 'c', 8, 36, 'ms')),
  null::timestamptz,
  'check_text_time.newest_decoded is null, not an error, when the maximum does not match the shape');

select * from finish();

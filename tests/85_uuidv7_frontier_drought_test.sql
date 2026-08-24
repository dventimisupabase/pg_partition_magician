-- Issue #325: uuidv7 grids the forward frontier against DATA (max(control)) while every other kind
-- grids it against something that cannot fall behind now() -- `time` IS the clock, and `id` has no
-- clock to fall behind. A uuidv7 table whose data goes quiet (a restored dump, a stale clone, a table
-- that just stops getting writes) has a frontier stuck wherever the data ended while now() keeps
-- moving. Once the gap exceeds `obtain x step`, no partition covers now() and every write is refused,
-- permanently and silently -- obtain has nothing to do by its own (data-only) measure.
--
-- The fixture mirrors the issue's own reproduction: two rows backfilled 13 and 11 months stale, a
-- monthly step, and p_obtain => 2 (2 months of lookahead -- nowhere near enough to reach "now" from an
-- 11-month-old frontier, so this cannot pass by accident of a generous default).
create extension if not exists pgtap;

select plan(4);

create table public.fd_uuid (id uuid primary key, body text);
insert into public.fd_uuid (id, body) values
  (pgpm._ts_to_uuid(now() - interval '13 months'), 'oldest'),
  (pgpm._ts_to_uuid(now() - interval '11 months'), 'newest');

-- LIVENESS WITNESS: the drought this guard exists to catch is really present. Every assertion below is
-- of the form "obtain still reaches now()", which would also pass vacuously against a fixture that
-- was never actually stale.
select cmp_ok(
  (select now() - pgpm._uuid_to_ts(id) from public.fd_uuid order by id desc limit 1),
  '>', interval '2 months',
  'the newest backfilled row is well outside the 2-month (p_obtain x step) lookahead about to be configured'
);

call pgpm.transmute('public.fd_uuid', 'id', interval '1 month', p_obtain => 2);
select pgpm.resume('public.fd_uuid');
call pgpm.maintain('public.fd_uuid');

select ok(
  exists (
    select 1 from pgpm.part
     where parent_table = 'public.fd_uuid'::regclass and attached
       and lo::timestamptz <= now() and hi::timestamptz > now()
  ),
  'a partition covers now() after one maintenance tick, despite an 11-month-stale data frontier'
);

select lives_ok(
  $$ insert into public.fd_uuid (id, body) values (pgpm._ts_to_uuid(now()), 'live') $$,
  'a uuidv7 row timestamped at now() is accepted, not refused with "no partition ... found for row"'
);

-- 'id' has no clock, so its frontier must stay EXACTLY max(control) -- this fix must not blend now()
-- into a kind that has nothing to do with time.
create table public.fd_id (id bigint primary key, body text);
insert into public.fd_id (id, body) values (100, 'only');
call pgpm.transmute('public.fd_id', 'id', 10::bigint, p_obtain => 2);

select is(
  pgpm._frontier_native('public.fd_id'::regclass),
  '100', 'id kind frontier is exactly max(control), never blended with now()'
);

select * from finish();

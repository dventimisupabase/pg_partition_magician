-- Regression test for issue #96. A uuid control column is treated as uuidv7 on assumption. transmute
-- samples it and now REFUSES when it looks overwhelmingly random (UUIDv4) -- mirroring the float-key
-- and PK refusals -- rather than only warning, since range-partitioning a non-time-ordered key
-- scatters rows across meaningless partitions on a garbage frontier. An operator certain the column
-- is time-ordered can override with p_force_uuidv7 => true.
create extension if not exists pgtap;

select plan(11);

-- (A) a random UUIDv4 column samples near zero and is refused
create table public.v4_t (id uuid primary key, body text);
insert into public.v4_t (id, body) select gen_random_uuid(), 'x' from generate_series(1, 500) g;

select cmp_ok(
  (select fraction from pgpm.check_uuidv7('public.v4_t', 'id', 500)),
  '<', 0.5::numeric, 'setup: the column samples as random UUIDv4 (fraction < 0.5)');

select throws_like(
  $$ call pgpm.transmute('public.v4_t', 'id', interval '1 month') $$,
  'pg_partition_magician:%UUIDv4%',
  'transmute refuses a uuid control column that samples as random');

select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'v4_t'),
  'r', 'the refusal is up front: v4_t is left a plain table, untouched');

-- (B) p_force_uuidv7 overrides the SAMPLING heuristic, but not arithmetic (issue #299).
--
-- This used to assert that forcing converted `v4_t` outright. It cannot, and the attempt was a
-- probabilistic CI flake: a column of random uuids has its maximum near the top of the 128-bit space, so
-- its frontier decodes to within a whisker of the 48-bit UUIDv7 ceiling (10889-08-02 05:31:50.65504+00),
-- and the next grid boundary is unrepresentable. `_ts_to_uuid` used to TRUNCATE that overflow instead of
-- refusing -- `lpad(..., 12, '0')` shortens a 13-digit hex string -- so a later timestamp encoded as a
-- SMALLER uuid and the bound came out with lo > hi. Whether it blew up depended on how close to the
-- ceiling that particular run's random maximum landed, which is why it failed on some runs and not
-- others.
--
-- The override's remit is now exact: it lets an operator vouch for a column the sampling MISJUDGED. It
-- does not, and cannot, conjure a bound no uuid can express.
-- Note this fixture is CRAFTED, not random. Asserting the ceiling refusal against `v4_t` would reproduce
-- the very flakiness being fixed: whether B overflows depends on where that run's random maximum landed
-- (a max decoding to 10889-07 leaves the next boundary representable, and transmute proceeds).
create table public.v4_top (id uuid primary key, body text);
insert into public.v4_top (id, body) values
  ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'at the very top of the space'),
  ('fffffffe-0000-0000-0000-000000000000', 'just below it');

select throws_like(
  $$ call pgpm.transmute('public.v4_top', 'id', interval '1 month', p_force_uuidv7 => true, p_obtain => 2) $$,
  '%newest instant a UUIDv7 timestamp can express%',
  'p_force_uuidv7 does NOT override the 48-bit ceiling: the refusal names the arithmetic, not the heuristic');

select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'v4_top'),
  'r', 'and that refusal is up front too: the table is left a plain table');

-- (B2) the override DOES work on a column the sampling misjudges but whose grid is representable.
-- These uuids encode 1990, so they decode outside check_uuidv7's plausible window [2015-01-01, now()]
-- and sample at 0.0 -- yet their frontier is nowhere near the ceiling, so the grid is ordinary. That is
-- exactly the case p_force_uuidv7 exists for, and it is deterministic.
create table public.v7_old (id uuid primary key, body text);
insert into public.v7_old (id, body)
select pgpm._ts_to_uuid(timestamptz '1990-01-01' + (g || ' hours')::interval), 'x'
from generate_series(1, 200) g;

select cmp_ok(
  (select fraction from pgpm.check_uuidv7('public.v7_old', 'id', 200)),
  '<', 0.5::numeric, 'setup: a time-ordered but OLD uuid column still samples as implausible');

call pgpm.transmute('public.v7_old', 'id', interval '1 month', p_force_uuidv7 => true);
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'v7_old'),
  'p', 'p_force_uuidv7 => true overrides the sampling refusal and converts it');

-- (C) a genuine UUIDv7/ULID-shaped column (48-bit ms prefix) is accepted with no override
create table public.v7_t (id uuid primary key, body text);
insert into public.v7_t (id, body)
select (substr(h,1,8) || '-' || substr(h,9,4) || '-' || substr(h,13,4) || '-'
        || substr(h,17,4) || '-' || substr(h,21,12))::uuid, 'x'
from (
  select g, lpad(to_hex((extract(epoch from now()) * 1000)::bigint), 12, '0')
            || substr(replace(gen_random_uuid()::text, '-', ''), 13) as h
  from generate_series(1, 200) g
) s;

call pgpm.transmute('public.v7_t', 'id', interval '1 month');
select pass('a genuine time-ordered uuid column is accepted without an override');

-- (D) the ceiling itself: _ts_to_uuid must refuse rather than truncate (issue #299).
-- Monotonicity is the property every bound-computing caller assumes, so this is the root fix; the
-- refusals above are consequences of it.
select is(pgpm._ts_to_uuid(timestamptz '10889-08-02 05:31:50.65504+00')::text,
  'ffffffff-ffff-0000-0000-000000000000',
  'the last representable instant encodes to the maximum 48-bit prefix');

select throws_ok(
  $$ select pgpm._ts_to_uuid(timestamptz '10889-08-02 05:31:50.65504+00' + interval '1 millisecond') $$,
  '22008', NULL,
  'one millisecond past it is REFUSED, not silently truncated into a smaller uuid');

-- The liveness witness for that negative: the decode direction genuinely cannot overflow, so the ceiling
-- is only ever reachable by stepping forward. If this failed, the assertion above would be guarding a
-- case that could never arise.
select ok(pgpm._uuid_to_ts('ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
          <= timestamptz '10889-08-02 05:31:50.65504+00',
  'LIVENESS: no uuid decodes past the ceiling, so only forward steps can overflow it');

select * from finish();

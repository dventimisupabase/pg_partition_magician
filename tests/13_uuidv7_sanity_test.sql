-- Verifies the uuidv7 sanity heuristic: genuine time-ordered uuids pass, random
-- (v4) columns are flagged, and transmute REFUSES a column that samples as random (issue #96).
create extension if not exists pgtap;

begin;
select plan(3);

-- the seeded events_uuid column is genuinely time-ordered -> ~all plausible
select cmp_ok(
  (select fraction from pgpm.check_uuidv7('public.events_uuid', 'id', 1000)),
  '>=', 0.95::numeric,
  'genuine uuidv7 column passes the sanity check'
);

-- a column of random v4 uuids decodes to implausible timestamps
create table public.rnd_uuid (id uuid primary key default gen_random_uuid(), payload text);
insert into public.rnd_uuid (payload) select 'x' from generate_series(1, 500);
select cmp_ok(
  (select fraction from pgpm.check_uuidv7('public.rnd_uuid', 'id', 500)),
  '<', 0.5::numeric,
  'random (v4) column is flagged by the sanity check'
);

-- refuse-by-default: range-partitioning a non-time-ordered key is meaningless, so transmute refuses
-- a column that samples as random (the operator can override with p_force_uuidv7; see tests/39)
select throws_like(
  $$ select pgpm.transmute('public.rnd_uuid', 'id', interval '1 month') $$,
  'pg_partition_magician:%UUIDv4%',
  'transmute (uuid column treated as uuidv7) refuses a random-uuid column'
);

select * from finish();
rollback;

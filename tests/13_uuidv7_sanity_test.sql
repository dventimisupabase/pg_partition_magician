-- Verifies the uuidv7 sanity heuristic: genuine time-ordered uuids pass, random
-- (v4) columns are flagged, and adopt warns-but-proceeds on a suspect column.
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

-- warn-by-default: adopt still proceeds on the suspect column (operator's call)
select lives_ok(
  $$ select pgpm.adopt('public.rnd_uuid', 'id', interval '1 month') $$,
  'adopt (uuidv7 inferred from the uuid column) warns but proceeds on a random-uuid column'
);

select * from finish();
rollback;

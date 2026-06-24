-- Regression test for issue #96. A uuid control column is treated as uuidv7 on assumption. transmute
-- samples it and now REFUSES when it looks overwhelmingly random (UUIDv4) -- mirroring the float-key
-- and PK refusals -- rather than only warning, since range-partitioning a non-time-ordered key
-- scatters rows across meaningless partitions on a garbage frontier. An operator certain the column
-- is time-ordered can override with p_force_uuidv7 => true.
create extension if not exists pgtap;

begin;
select plan(5);

-- (A) a random UUIDv4 column samples near zero and is refused
create table public.v4_t (id uuid primary key, body text);
insert into public.v4_t (id, body) select gen_random_uuid(), 'x' from generate_series(1, 500) g;

select cmp_ok(
  (select fraction from pgpm.check_uuidv7('public.v4_t', 'id', 500)),
  '<', 0.5::numeric, 'setup: the column samples as random UUIDv4 (fraction < 0.5)');

select throws_like(
  $$ select pgpm.transmute('public.v4_t', 'id', interval '1 month') $$,
  'pg_partition_magician:%UUIDv4%',
  'transmute refuses a uuid control column that samples as random');

select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'v4_t'),
  'r', 'the refusal is up front: v4_t is left a plain table, untouched');

-- (B) the operator can override when certain the column is time-ordered
select lives_ok(
  $$ select pgpm.transmute('public.v4_t', 'id', interval '1 month', p_force_uuidv7 => true) $$,
  'p_force_uuidv7 => true overrides the refusal');

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

select lives_ok(
  $$ select pgpm.transmute('public.v7_t', 'id', interval '1 month') $$,
  'a genuine time-ordered uuid column is accepted without an override');

select * from finish();
rollback;

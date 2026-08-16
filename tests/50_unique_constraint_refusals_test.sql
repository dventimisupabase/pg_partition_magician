-- Refusals for the relaxed key contract. The reused key must be a CONSTRAINT (PK or UNIQUE) whose key
-- includes the control column, and the control column must be NOT NULL. transmute refuses up front,
-- leaving the table intact, when: the control column is nullable (we never fall into an O(rows)
-- SET NOT NULL scan), or the only unique key on the control column is a BARE unique index rather than a
-- constraint (ADD UNIQUE would REBUILD it; the operator first promotes it with
-- ALTER TABLE ... ADD CONSTRAINT ... UNIQUE USING INDEX, consistent with pgpm's other operator-prep refusals).
create extension if not exists pgtap;

select plan(4);

-- (A) UNIQUE constraint includes control, but the control column is NULLABLE -> refuse
create table public.uq_nullable (
  ts   timestamptz,          -- nullable control column
  id   bigint not null,
  constraint uq_nullable_key unique (ts, id)
);
insert into public.uq_nullable (ts, id)
  select now() - (g || ' days')::interval, g from generate_series(1, 10) g;

select throws_like(
  $$ select pgpm.transmute('public.uq_nullable', 'ts', interval '1 month') $$,
  'pg_partition_magician:%NOT NULL%',
  'refuses when the control column is nullable, naming the NOT NULL requirement');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'uq_nullable'),
  'r', 'the nullable-control table is left intact (refused before the cutover)');

-- (B) a BARE unique index includes control, but there is no PK and no unique CONSTRAINT -> refuse
create table public.uq_bare (
  ts   timestamptz not null,
  id   bigint not null,
  body text
);
create unique index uq_bare_idx on public.uq_bare (ts, id);   -- a bare index, not a constraint
insert into public.uq_bare (ts, id)
  select now() - (g || ' days')::interval, g from generate_series(1, 10) g;

select throws_like(
  $$ select pgpm.transmute('public.uq_bare', 'ts', interval '1 month') $$,
  'pg_partition_magician:%USING INDEX%',
  'refuses a bare unique index, guiding the operator to promote it to a constraint');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'uq_bare'),
  'r', 'the bare-unique-index table is left intact');

select * from finish();

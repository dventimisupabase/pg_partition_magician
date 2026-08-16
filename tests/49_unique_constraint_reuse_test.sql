-- Feature test for the relaxed key contract. transmute no longer requires a PRIMARY KEY: it reuses any
-- PRIMARY KEY *or* UNIQUE CONSTRAINT whose key includes the control column (with control NOT NULL),
-- adopting the monolith's existing constraint index with no rebuild. (Postgres adopts a child's PK index
-- under ADD PRIMARY KEY and a child's UNIQUE-constraint index under ADD UNIQUE, both metadata-only; it
-- would REBUILD a bare unique index, which is why a bare index is refused -- see test 50.) Faithful: no
-- primary key is synthesized when the source had only a unique constraint.
create extension if not exists pgtap;

select plan(10);

-- (A) NO primary key, a UNIQUE CONSTRAINT whose key LEADS with the control column
create table public.uq_lead (
  ts   timestamptz not null,
  id   bigint      not null,
  body text,
  constraint uq_lead_key unique (ts, id)
);
insert into public.uq_lead (ts, id, body)
  select date_trunc('month', now()) - interval '3 months' + (g || ' days')::interval, g, 'x'
  from generate_series(1, 40) g;

select lives_ok(
  $$ select pgpm.transmute('public.uq_lead', 'ts', interval '1 month', p_paused => false) $$,
  'transmute reuses a UNIQUE constraint that includes the control column (no PK required)');

select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'uq_lead'),
  'p', 'the table is now partitioned');

-- the parent carries a UNIQUE constraint (not a PK) on the reused key
select is(
  (select count(*)::int from pg_constraint where conrelid = 'public.uq_lead'::regclass and contype = 'u'),
  1, 'the reused UNIQUE constraint is present on the parent');
select is(
  (select count(*)::int from pg_constraint where conrelid = 'public.uq_lead'::regclass and contype = 'p'),
  0, 'no primary key was synthesized (faithful to the source)');

-- the control column is NOT NULL on the parent (required up front, never an O(rows) scan)
select is(
  (select attnotnull from pg_attribute where attrelid = 'public.uq_lead'::regclass and attname = 'ts'),
  true, 'the control column is NOT NULL');

-- row conservation: the monolith holds every row, visible through the parent
select is((select count(*)::int from public.uq_lead), 40, 'all rows conserved through the parent');

-- uniqueness is enforced across partitions once they are materialized
select pgpm.drain_all('public.uq_lead', p_include_open => true);
select throws_ok(
  $$ insert into public.uq_lead (ts, id, body)
       values (date_trunc('month', now()) - interval '3 months' + interval '1 day', 1, 'dup') $$,
  '23505', NULL,
  'the reused UNIQUE constraint enforces global uniqueness on a materialized partition');

-- (B) NO primary key, composite UNIQUE constraint where the control column is NOT the leading column
create table public.uq_mid (
  device_id bigint      not null,
  ts        timestamptz not null,
  body      text,
  constraint uq_mid_key unique (device_id, ts)
);
insert into public.uq_mid (device_id, ts, body)
  select g, date_trunc('month', now()) - interval '2 months' + (g || ' days')::interval, 'x'
  from generate_series(1, 30) g;

select lives_ok(
  $$ select pgpm.transmute('public.uq_mid', 'ts', interval '1 month', p_paused => false) $$,
  'transmute reuses a composite UNIQUE constraint even when control is not the leading column');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'uq_mid'),
  'p', 'the non-leading-control table is partitioned too');
select is((select count(*)::int from public.uq_mid), 30, 'rows conserved (non-leading control)');

select * from finish();

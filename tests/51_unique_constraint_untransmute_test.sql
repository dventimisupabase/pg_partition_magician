-- untransmute round-trips a table whose reused key is a UNIQUE constraint (no PK), exactly as it does
-- for a PK table: while the monolith still holds every row (before obtain/drain), untransmute restores
-- the plain table with its UNIQUE constraint intact and every row conserved. (Detaching the monolith
-- leaves its adopted unique constraint standing on the now-standalone table, so the reverse is clean.)
create extension if not exists pgtap;

select plan(5);

create table public.uq_rt (
  ts   timestamptz not null,
  id   bigint not null,
  body text,
  constraint uq_rt_key unique (ts, id)
);
insert into public.uq_rt (ts, id, body)
  select now() - (g || ' days')::interval, g, 'x' from generate_series(1, 25) g;

call pgpm.transmute('public.uq_rt', 'ts', interval '1 month');
select pass('transmute a no-PK unique-constraint table (paused, monolith holds all)');
select lives_ok(
  $$ select pgpm.untransmute('public.uq_rt') $$,
  'untransmute reverses it while the monolith still holds every row');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'uq_rt'),
  'r', 'the table is a plain table again');
select is(
  (select count(*)::int from pg_constraint where conrelid = 'public.uq_rt'::regclass and contype = 'u'),
  1, 'the UNIQUE constraint survived the round trip');
select is((select count(*)::int from public.uq_rt), 25, 'all rows conserved through the round trip');

select * from finish();

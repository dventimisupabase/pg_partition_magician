-- CHECK constraints reach the partitioned parent. transmute builds the parent with LIKE INCLUDING
-- CONSTRAINTS so the user's CHECK constraints land on the parent and every partition enforces them --
-- not just the monolith. The transient pgpm_monolith_bound CHECK (copied by LIKE) is dropped from the
-- parent so it never constrains forward partitions.
create extension if not exists pgtap;

begin;
select plan(3);

create table public.ck (
  id     bigint  not null,
  amount numeric not null,
  primary key (id),
  constraint ck_amount check (amount >= 0)
);
insert into public.ck select g, g from generate_series(1, 100) g;
select pgpm.transmute('public.ck', 'id', 1000::bigint, p_paused => false);

select is(
  (select count(*)::int from pg_constraint
    where conrelid = 'public.ck'::regclass and contype = 'c' and conname = 'ck_amount'),
  1, 'the user CHECK constraint is carried onto the partitioned parent');
select is(
  (select count(*)::int from pg_constraint
    where conrelid = 'public.ck'::regclass and conname = 'pgpm_monolith_bound'),
  0, 'the transient monolith bound CHECK is not left on the parent');

-- a forward partition (ahead of the frontier) inherits the parent CHECK and enforces it
select pgpm.obtain('public.ck');
select throws_ok(
  $$ insert into public.ck (id, amount) values (1500, -1) $$,
  '23514', NULL,
  'a new forward partition enforces the inherited CHECK constraint');

select * from finish();
rollback;

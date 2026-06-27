-- Generated columns. The data-movement paths (drain and refine) build the column list they INSERT
-- through; it must OMIT generated columns (they recompute on insert and cannot be written to), else the
-- move fails with "cannot insert a non-DEFAULT value into a generated column". This exercises both refine
-- (copying the monolith) and drain (moving a stray) on a table with a STORED generated column, and checks
-- the generated value is recomputed correctly on the destination.
create extension if not exists pgtap;

begin;
select plan(5);

create table public.gc (
  id     bigint  not null,
  amount numeric not null,
  cents  bigint  generated always as (amount * 100) stored,
  primary key (id)
);
insert into public.gc (id, amount) select g, g from generate_series(1, 5000) g;   -- [0,6000) at step 1000
select pgpm.transmute('public.gc', 'id', 1000::bigint, p_paused => true);
insert into public.gc (id, amount) values (100000, 100000);   -- past B: lands in the DEFAULT, freezes the monolith

-- refine copies the coarse monolith into fine children -- the copy must omit the generated column
select lives_ok(
  $$ select pgpm.refine_history('public.gc', '1000') $$,
  'refine copies a table with a generated column without an insert-into-generated error');
select is((select count(*)::int from public.gc), 5001, 'rows conserved through refine');
select is(
  (select count(*)::int from public.gc where cents = amount * 100),
  5001, 'the generated column is correct on every row after refine');

-- drain moves the open stray out of the DEFAULT -- the move must omit the generated column too
select lives_ok(
  $$ select pgpm.drain_all('public.gc', p_include_open => true) $$,
  'drain moves a row of a generated-column table without an insert-into-generated error');
select is(
  (select cents from public.gc where id = 100000),
  10000000::bigint, 'the generated column is recomputed correctly on the drained row');

select * from finish();
rollback;

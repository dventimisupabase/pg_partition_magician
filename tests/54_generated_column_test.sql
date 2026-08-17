-- Generated columns. The data-movement paths (drain and regrain) build the column list they INSERT
-- through; it must OMIT generated columns (they recompute on insert and cannot be written to), else the
-- move fails with "cannot insert a non-DEFAULT value into a generated column". This exercises both regrain
-- (copying the monolith) and drain (moving a stray) on a table with a STORED generated column, and checks
-- the generated value is recomputed correctly on the destination.
create extension if not exists pgtap;

select plan(3);

create table public.gc (
  id     bigint  not null,
  amount numeric not null,
  cents  bigint  generated always as (amount * 100) stored,
  primary key (id)
);
insert into public.gc (id, amount) select g, g from generate_series(1, 5000) g;   -- [0,6000) at step 1000
call pgpm.transmute('public.gc', 'id', 1000::bigint, p_paused => true);
insert into public.gc (id, amount) values (20000, 100000);   -- past B: lands in the DEFAULT, freezes the monolith

-- regrain copies the coarse monolith into fine children -- the copy must omit the generated column
select lives_ok(
  $$ select pgpm.regrain_history('public.gc', '1000') $$,
  'regrain copies a table with a generated column without an insert-into-generated error');
select is((select count(*)::int from public.gc), 5001, 'rows conserved through regrain');
select is(
  (select count(*)::int from public.gc where cents = amount * 100),
  5001, 'the generated column is correct on every row after regrain');

-- The drain half is gone with the drain (#288): it asserted that moving a stray OUT of the DEFAULT also
-- omitted the generated column. There is no DEFAULT and no move. regrain's copy above is the surviving
-- path that must omit it, and it is asserted there.

select * from finish();

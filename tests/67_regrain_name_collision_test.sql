-- regrain must never name a fine sub-range the same as the source child it is splitting (issue #266).
-- pgpm._part_name renders the id kind as lpad(lo, 19, '0') with NO step in the name, and appends
-- _to_<hi> only for a COARSE child (one wider than a single step at its own step). So a source child
-- exactly one config step wide and its own FIRST fine sub-range render the same relation name. Left
-- unguarded, regrain_step's "does the destination exist yet?" check finds the SOURCE, treats it as the
-- already-created destination, copies nothing, advances the cursor as though the sub-range were done, and
-- the swap's DROP TABLE then destroys that sub-range's rows -- silently, with a return value one lower
-- than the number of sub-ranges. These tests pin the refusal and the conservation it protects.
create extension if not exists pgtap;
begin;
select plan(9);

-- ============================ the colliding case ============================
-- 400 ids over a step of 1000: the monolith is [0, 1000), exactly ONE grid step wide, so its name
-- carries no _to_<hi> suffix. Its first fine sub-range at a target step of 100 is [0, 100), which
-- renders identically.
create table public.rnc (id bigint primary key, payload text);
insert into public.rnc select g, 'x' from generate_series(1, 400) g;
select pgpm.transmute('public.rnc', 'id', 1000);
insert into public.rnc values (900000, 'frontier');   -- advance the frontier so the monolith freezes

select is(
  pgpm._part_name('rnc', 'id', '1000', '0', '1000'),
  pgpm._part_name('rnc', 'id', '100', '0', '100'),
  'the source child and its own first fine sub-range render the same relation name');

select is((select count(*)::int from public.rnc), 401,
  'baseline: 401 rows before any regrain');

select throws_ok(
  $$ select pgpm.regrain('public.rnc', 'rnc_p0000000000000000000', '100') $$,
  'P0001', NULL,
  'regrain refuses when the first fine sub-range would be named as the source child');

-- the refusal must be total: pgpm.regrain loops regrain_step in one transaction, so a raise rolls the
-- whole attempt back. Assert the state is untouched rather than trusting that.
select is((select count(*)::int from public.rnc), 401,
  'the refusal mutated nothing: all 401 rows still present');

select is(
  (select count(*)::int from generate_series(1, 99) g
    where not exists (select 1 from public.rnc where id = g)),
  0, 'the first sub-range''s rows (ids 1..99) are intact -- this is what the bug destroyed');

select ok(
  to_regclass('public.rnc_p0000000000000000000') is not null,
  'the source child still exists (the swap never ran)');

select is(
  (select attached from pgpm.part
    where parent_table = 'public.rnc'::regclass and child_name = 'rnc_p0000000000000000000'),
  true, 'the source child is still attached and still registered');

-- ============================ the coarse case still works ============================
-- 2500 ids over a step of 1000: the monolith is [0, 3000), three steps wide, so it IS coarse and its
-- name carries _to_<hi>. Its first fine sub-range is named differently, so nothing collides and the
-- guard must not fire.
create table public.rcc (id bigint primary key, payload text);
insert into public.rcc select g, 'x' from generate_series(1, 2500) g;
select pgpm.transmute('public.rcc', 'id', 1000);
insert into public.rcc values (900000, 'frontier');

select is(
  (select pgpm.regrain('public.rcc', 'rcc_p0000000000000000000_to_0000000000000003000', '100'))::int,
  30, 'a coarse source child still regrains into all 30 fine children');

select is((select count(*)::int from public.rcc), 2501,
  'the coarse regrain is lossless: every row survives the swap');

select * from finish();
rollback;

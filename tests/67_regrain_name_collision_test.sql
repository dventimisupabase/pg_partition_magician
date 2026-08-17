-- regrain must never name a fine sub-range the same as the source child it is splitting (issue #266).
--
-- pgpm._part_name gives a one-step range the historical name _p<lo> and a WIDER range the explicit
-- _p<lo>_to_<hi>, and the comment above it states the reason: the wide form exists "so it can never
-- collide with the fine child at its low edge". The flaw is that "wider" was judged at the child's OWN
-- step. A child exactly one step wide is not wide on its own grid, so it kept the bare _p<lo>; regrain
-- then reinterprets it on a FINER grid, where its own first sub-range also renders _p<lo>.
--
-- Unguarded that was silent data loss: regrain_step's "does the destination exist yet?" check found the
-- SOURCE, treated it as an already-created destination, the anti-join copy moved nothing, the cursor
-- advanced as though the sub-range were done, and the swap's DROP TABLE took those rows with it.
--
-- The cure is to finish the stated design: before splitting, rename the source to its own name as
-- rendered on the TARGET grid, where it IS wider than one step and therefore always takes the explicit
-- _to_ form. The fine sub-range names are then free, and the collision is structurally impossible.
create extension if not exists pgtap;
select plan(14);

-- ======================= the case that used to destroy rows =======================
-- 400 ids over a step of 1000: the monolith is [0, 1000), exactly ONE grid step wide, so its name
-- carries no _to_<hi>. Its own first sub-range at a target step of 100 is [0, 100), which renders
-- identically on the source grid.
create table public.rnc (id bigint primary key, payload text);
insert into public.rnc select g, 'x' from generate_series(1, 400) g;
call pgpm.transmute('public.rnc', 'id', 1000);
insert into public.rnc values (900000, 'frontier');   -- advance the frontier so the monolith freezes

select is(
  pgpm._part_name('rnc', 'id', '1000', '0', '1000'),
  pgpm._part_name('rnc', 'id', '100', '0', '100'),
  'the collision is real: source and its own first sub-range render the same name on the source grid');

select is((select count(*)::int from public.rnc), 401,
  'baseline: 401 rows before the regrain');

select is(
  (select pgpm.regrain('public.rnc', 'rnc_p0000000000000000000', '100'))::int,
  10, 'a one-step-wide child now regrains into ALL 10 sub-ranges (the bug returned 9)');

select is((select count(*)::int from public.rnc), 401,
  'the regrain is lossless: all 401 rows survive');

select is(
  (select count(*)::int from generate_series(1, 99) g
    where not exists (select 1 from public.rnc where id = g)),
  0, 'the first sub-range''s rows (ids 1..99) survive -- this is exactly what the bug destroyed');

select ok(
  to_regclass('public.rnc_p0000000000000000000') is not null,
  'the first fine child took the natural _p<lo> name, freed by renaming the source');

select is(
  (select attached from pgpm.part
    where parent_table = 'public.rnc'::regclass and child_name = 'rnc_p0000000000000000000'),
  true, 'that fine child is attached and registered');

select is(
  (select count(*)::int from pgpm.part p
    where p.parent_table = 'public.rnc'::regclass and p.attached
      and p.lo::numeric >= 0 and p.hi::numeric <= 1000),
  10, 'ten fine children now cover the old one-step child''s range');

select ok(
  to_regclass('public.rnc_p0000000000000000000_to_0000000000000001000') is null,
  'the transitional coarse-form source name is gone (the swap dropped it)');

select cmp_ok(
  (select count(*) from pgpm.log
    where parent_table = 'public.rnc'::regclass and action = 'regrain_rename'),
  '>', 0::bigint, 'the rename is recorded in pgpm.log');

-- ======================= the already-coarse case is untouched =======================
-- 2500 ids over a step of 1000: the monolith is [0, 3000), three steps wide, so it already carries
-- _to_<hi> and nothing needs renaming. This is the path regrain_history and auto-regrain always take.
create table public.rcc (id bigint primary key, payload text);
insert into public.rcc select g, 'x' from generate_series(1, 2500) g;
call pgpm.transmute('public.rcc', 'id', 1000);
insert into public.rcc values (900000, 'frontier');

select is(
  (select pgpm.regrain('public.rcc', 'rcc_p0000000000000000000_to_0000000000000003000', '100'))::int,
  30, 'a coarse source child still regrains into all 30 fine children, losslessly');

-- ======================= the rename survives across ticks =======================
-- regrain() loops inside one transaction, but a feathered regrain is one regrain_step per tick, so the
-- rename has to be visible to the NEXT call. Drive it a step at a time and pin the hand-off.
create table public.rnd (id bigint primary key, payload text);
insert into public.rnd select g, 'x' from generate_series(1, 400) g;
call pgpm.transmute('public.rnd', 'id', 1000);
insert into public.rnd values (900000, 'frontier');

select pgpm.regrain_step('public.rnd', 'rnd_p0000000000000000000', '100', 50);   -- first tick: renames

select is(
  (select child_name from pgpm.part
    where parent_table = 'public.rnd'::regclass and attached and lo::numeric = 0),
  'rnd_p0000000000000000000_to_0000000000000001000'::name,
  'after the first tick pgpm.part tracks the source under its new coarse-form name');

select ok(
  to_regclass('public.rnd_p0000000000000000000_to_0000000000000001000') is not null,
  'the source table itself was renamed, not copied');

select is((select count(*)::int from public.rnd), 401,
  'the rename tick moved no rows and lost none');

select * from finish();

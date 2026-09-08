-- regrain's fine children carry their own already-validated copy of the parent's outgoing FK
-- (issue #348). A fresh child is created via `like ... including constraints`, which never
-- copies a FOREIGN KEY (no LIKE option does), so before this fix every fine child reached the
-- swap's ATTACH with no matching constraint and forced PostgreSQL to validate it from scratch --
-- an O(rows) scan of the child, under whatever lock ATTACH already holds, with no timeout of its
-- own. In production this reached the session's statement_timeout outright.
--
-- The fix mirrors the bound CHECK immediately above it in regrain_step: add each of the parent's
-- validated outgoing FKs to the fine child, NOT VALID, then VALIDATE it right there -- while the
-- child is still EMPTY (this runs before the first row is copied in), so the scan costs nothing,
-- the same way an empty CHECK validates for free. Every row copied in afterward is checked at
-- INSERT time by the ordinary FK machinery regardless, so this one-time, zero-row VALIDATE is the
-- only one this constraint will ever need, and by the swap's ATTACH, PostgreSQL adopts it instead
-- of re-scanning -- the same adoption transmute already relies on for the monolith
-- (install.sql:2841-2851).
--
-- This file pins the CORRECTNESS consequence (every partition ends up with one validated,
-- adopted FK, and it keeps enforcing before and after). It cannot pin the LOCK-DURATION
-- consequence -- pgTAP wraps every file in one transaction, and the defect this fixes is a
-- difference in how long a lock is held, not a difference in final state (an unfixed ATTACH
-- reaches the same validated end state, just after an O(rows) scan under lock instead of an
-- instant one). Measured independently instead: pre-validating and then attaching a 90,000-row
-- partition took 0.69ms; the identical attach without pre-validating took 16.9ms for the same row
-- count -- the gap that scales with row count and is exactly what turned into the production
-- statement-timeout. A bench/-style lock-duration guard (mirroring bench/restore_fk_lock.sh) is
-- the natural follow-up to make that gap a standing, mutation-tested check.
create extension if not exists pgtap;
select plan(6);

create table public.ofk92_ref (id int primary key);
insert into public.ofk92_ref select generate_series(1, 100);

create table public.ofk92 (id bigint primary key, ref_id int not null references public.ofk92_ref(id), payload text);

-- liveness witness: the plain, unconverted table genuinely enforces the FK, so "it still
-- enforces after regrain" below cannot be satisfied by a fixture that never enforced anything.
select throws_ok(
  $$ insert into public.ofk92 values (1, 999, 'orphan') $$,
  '23503', null, 'setup: the plain table rejects a ref_id that does not exist in ofk92_ref');

insert into public.ofk92 select g*10, ((g*10) % 100) + 1, 'x' from generate_series(1, 250) g;

-- a PROCEDURE, not a function: it calls transmute, which COMMITs (#275)
create or replace procedure pg_temp.mk92() language plpgsql as $$
begin
  call pgpm.transmute('public.ofk92'::regclass, 'id', 1000);
  insert into public.ofk92 values (20000, 1, 'frontier');   -- freeze the monolith
end $$;
call pg_temp.mk92();

-- drive regrain_step tick by tick to the swap, same harness shape as tests/68 (avoids
-- pgpm.regrain(), which loops in one transaction and would hide any mid-flight state)
create or replace function pg_temp.finish_regrain92(p_batch int) returns text language plpgsql as $$
declare s text; n int := 0;
begin
  loop
    s := pgpm.regrain_step('public.ofk92'::regclass,
                           'ofk92_p0000000000000000000_to_0000000000000003000'::name, '100', p_batch);
    exit when s like 'swapped:%';
    n := n + 1;
    if n > 500 then raise exception 'regrain did not converge'; end if;
  end loop;
  return s;
end $$;

select pgpm.regrain_step('public.ofk92'::regclass, 'ofk92_p0000000000000000000_to_0000000000000003000'::name, '100', 50);
select pg_temp.finish_regrain92(50);

-- every partition's own copy of the FK ended up validated -- not just the parent
select is(
  (select count(*)::int from pg_constraint
    where contype = 'f' and confrelid = 'public.ofk92_ref'::regclass and not convalidated),
  0, 'every partition''s outgoing FK (parent and every child) is validated, none left NOT VALID');

-- and genuinely ADOPTED by the parent, not a second, disconnected constraint sitting beside it
select is(
  (select count(*)::int from pg_constraint
    where contype = 'f' and confrelid = 'public.ofk92_ref'::regclass and conparentid = 0),
  1, 'exactly one top-level outgoing FK constraint -- every partition''s copy merged into it, none orphaned');

-- the liveness witness's mirror, post-regrain: a fine (post-swap) partition still enforces the FK
-- for a new write, proving the constraint that survived is a real, enforcing one
select throws_ok(
  $$ insert into public.ofk92 values (15, 999, 'orphan-after-regrain') $$,
  '23503', null, 'a fine partition (post-swap) still rejects a ref_id that does not exist');

-- and the data the regrain actually moved is intact (identity, not just cardinality)
select is((select count(*)::int from public.ofk92 where id between 1 and 2500), 250,
  'every row the regrain copied survived the swap');

select is(
  (select count(*)::int from pgpm.part p
    where p.parent_table = 'public.ofk92'::regclass and p.attached
      and p.lo::numeric >= 0 and p.hi::numeric <= 3000),
  30, 'the coarse monolith split into all 30 fine children');

select * from finish();

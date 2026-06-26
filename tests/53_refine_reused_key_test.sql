-- refine identifies rows for its resumable copy by the REUSED key, which after the relaxed key contract
-- may be a UNIQUE constraint rather than a primary key (regression: the resume anti-join used to be built
-- from the primary key only, so it produced malformed SQL on a no-PK monolith). A truly keyless monolith
-- has no key to dedup a resumed batch, so refine refuses it cleanly (the coarse monolith stays a valid,
-- queryable permanent state).
create extension if not exists pgtap;

begin;
select plan(5);

-- (A) refine a UNIQUE-constraint (no primary key) coarse monolith
create table public.ruq (id bigint not null, batch bigint not null, body text,
                         constraint ruq_uq unique (id, batch));
insert into public.ruq select g, 1, 'x' from generate_series(1, 5000) g;   -- spans [0,6000) at step 1000
select pgpm.transmute('public.ruq', 'id', 1000::bigint, p_paused => true);
insert into public.ruq (id, batch, body) values (100000, 1, 'frontier');   -- push the frontier past the monolith

select lives_ok(
  $$ select pgpm.refine_history('public.ruq', '1000') $$,
  'refine works on a unique-constraint (no primary key) coarse monolith');
select is((select count(*)::int from public.ruq), 5001, 'rows conserved through refine');
select is(
  (select count(*)::int from pgpm.part
    where parent_table = 'public.ruq'::regclass and attached
      and (hi::numeric - lo::numeric) <= 1000),
  6, 'the monolith was split into 6 fine (one-step) children');

-- (B) a truly keyless coarse monolith: refine refuses cleanly (no key to dedup a resumed copy)
create table public.rkl (id bigint not null, body text);
insert into public.rkl select g, 'x' from generate_series(1, 5000) g;
select pgpm.transmute('public.rkl', 'id', 1000::bigint, p_paused => true);
insert into public.rkl (id, body) values (100000, 'frontier');

select throws_like(
  $$ select pgpm.refine_history('public.rkl', '1000') $$,
  'pg_partition_magician:%',
  'refine refuses a keyless monolith with a clear error');
select is(
  (select count(*)::int from pgpm.part
    where parent_table = 'public.rkl'::regclass and attached
      and (hi::numeric - lo::numeric) > 1000),
  1, 'the keyless monolith is left intact (still one coarse child)');

select * from finish();
rollback;

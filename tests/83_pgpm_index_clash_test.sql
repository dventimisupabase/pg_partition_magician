-- Colliding <index>_pgpm names are refused up front (#311).
--
-- transmute recreates each carried secondary index as a PARTITIONED index on the new parent, named
-- <original>_pgpm, then attaches the monolith's original under it. Nothing checked that name was free, so
-- a pre-existing relation by it made the CREATE INDEX fail with a raw 42P07 from inside the cutover:
-- no pgpm prefix, no guidance, and no hint that the remedy is `drop index ..._pgpm`.
--
-- The cutover is one transaction, so no data was lost, but the operator was NOT left where they started.
-- Measured against pre-fix code with a bare CALL: phases 1 and 2 had already committed, leaving a
-- pgpm.transmute_inflight row AND a live pgpm_monolith_bound CHECK on the table -- which goes on refusing
-- every write outside [lo, hi) until someone runs transmute_abort. Every sibling shape (a key excluding
-- the control column, a bare unique index, an un-carryable UNIQUE secondary, a transition-table trigger,
-- an orphaned child table) refuses UP FRONT instead. This was the one hole in that contract.
--
-- WHICH ASSERTION BELOW ACTUALLY DISCRIMINATES: only the first. throws_ok is a FUNCTION, and a committing
-- procedure cannot commit inside one, so against pre-fix code the CALL dies at phase 1's COMMIT with
-- 2D000 and never reaches the phase-3 collision at all. Assertions 2-5 therefore pass pre-fix too, for
-- the wrong reason -- they characterise the post-fix contract (the refusal happens before any COMMIT, so
-- those values are meaningful) rather than proving the defect is gone. Do not read them as the proof.
create extension if not exists pgtap;

select plan(7);

create table public.ic (id bigint, created_at timestamptz not null default now(), payload text,
                        primary key (created_at, id));
insert into public.ic (id, created_at, payload)
  select g, now() - (g || ' minutes')::interval, 'x' from generate_series(1, 100) g;
create index ic_payload_idx on public.ic (payload);

-- The squatter: exactly the name step 9b will want.
create table public.ic_payload_idx_pgpm (whatever int);

select throws_ok(
  $$ call pgpm.transmute('public.ic', 'created_at', interval '1 day') $$,
  'P0001', null,
  'a colliding _pgpm name is refused with a pgpm error, not a raw 42P07');

-- Up front means BEFORE anything is committed: not a rolled-back cutover, which would still have left
-- the phase-1 bound CHECK and an inflight row behind for the operator to clean up by hand.
select is((select relkind::text from pg_class where oid = 'public.ic'::regclass), 'r',
  'the table is untouched');
select is((select count(*) from pgpm.transmute_inflight), 0::bigint,
  'no in-flight record was recorded');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.ic'::regclass and conname = 'pgpm_monolith_bound'),
  'no bound CHECK was left behind');
select is((select count(*) from pgpm.config where parent_table = 'public.ic'::regclass), 0::bigint,
  'the table was not registered');

-- LIVENESS WITNESS: drop the squatter and the identical call must succeed. Without it this file would
-- pass against a build where transmute is broken for some entirely unrelated reason -- the refusal would
-- look like the guard working when it was really the conversion failing.
drop table public.ic_payload_idx_pgpm;

call pgpm.transmute('public.ic', 'created_at', interval '1 day');

select is((select relkind::text from pg_class where oid = 'public.ic'::regclass), 'p',
  'the same call succeeds once the name is free');
select ok(exists (select 1 from pg_class where relname = 'ic_payload_idx_pgpm'
                   and relkind = 'I'),
  'and the partitioned index took the name it needed');

select * from finish();

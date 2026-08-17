-- obtain's three-phase partition build and what an interrupted one leaves behind (issue #280).
--
-- To create a partition beside a NON-EMPTY default, someone must prove the default holds no row in the
-- new range. obtain does that with ADD CONSTRAINT ... NOT VALID then VALIDATE, so the CREATE can skip
-- its own scan, and commits between the three so the O(rows) scan runs under SHARE UPDATE EXCLUSIVE
-- instead of under the ADD's ACCESS EXCLUSIVE. The lock behaviour itself needs a second session
-- watching a first, so it lives in bench/obtain_lock.sh (./test.sh perf); this file pins the states
-- those commits make reachable.
--
-- The price of committing is a window where the constraint is on the table and the partition is not,
-- so the DEFAULT rejects writes in a range nothing else is catching yet. That is a real new failure
-- mode and it is asserted here rather than glossed: tests 5-7 prove the bad state is exactly as bad as
-- claimed, and 8-10 prove the next tick clears it.
--
-- The interruption is forced with an event trigger that rejects CREATE TABLE, which fails phase 3
-- while leaving phases 1 and 2 committed. That is deterministic, unlike killing a session mid-run.
create extension if not exists pgtap;
select plan(12);

create table public.ob71 (id bigint primary key, v text);
insert into public.ob71 select g, 'x' from generate_series(1, 2500) g;
call pgpm.transmute('public.ob71', 'id', 1000, p_paused => false);
-- Rows past the monolith keep the DEFAULT non-empty, which is what puts obtain on the constraint path
-- at all: against an empty default it uses a single plain CREATE and none of this applies.
insert into public.ob71 select g, 'x' from generate_series(3001, 3500) g;
update pgpm.config set partition_step = '1000', obtain = 1
  where parent_table = 'public.ob71'::regclass;

-- ============================ a successful build leaves nothing behind ============================
call pgpm.obtain('public.ob71');

select is((select count(*)::int from pg_constraint
            where conrelid = 'public.ob71_default'::regclass and conname = 'pgpm_obtain_excl'),
  0, 'a completed build drops its exclusion constraint');

select cmp_ok((select count(*) from pgpm.log
                where parent_table = 'public.ob71'::regclass
                  and action = 'obtain' and method = 'check_skip'),
  '>', 0::bigint, 'and it took the constraint path, not a full scan by the CREATE');

select is((select count(*)::int from pg_locks
            where locktype = 'advisory' and pid = pg_backend_pid()),
  0, 'and it released its advisory lock rather than holding it for the session');

-- ============================ an interrupted build: phase 3 fails ============================
-- Advance the frontier into the cell just built, so the NEXT candidate ([5000,6000)) is one obtain
-- still has to create. Without this the call above has already built everything in range and the
-- blocked CREATE below is never reached, so the deferral assertions pass against a call that did
-- nothing at all.
insert into public.ob71 values (4600, 'advances the frontier');

-- Rejecting CREATE TABLE leaves phases 1 and 2 committed and phase 3 not, which is exactly the state a
-- session dying mid-build produces, without the nondeterminism of actually killing one.
create function public.ob71_block() returns event_trigger language plpgsql as $$
begin raise exception 'ob71: CREATE TABLE blocked for the test'; end $$;
create event trigger ob71_block_et on ddl_command_start
  when tag in ('CREATE TABLE') execute function public.ob71_block();

call pgpm.obtain('public.ob71') \gset

select ok(:'p_deferred'::boolean, 'a build that fails mid-way reports a deferral rather than raising');

select is((select count(*)::int from pg_constraint
            where conrelid = 'public.ob71_default'::regclass and conname = 'pgpm_obtain_excl'),
  1, 'and the committed phases leave the exclusion constraint in place');

select cmp_ok((select count(*) from pgpm.log
                where parent_table = 'public.ob71'::regclass and action = 'skip_obtain'),
  '>', 0::bigint, 'and says so in pgpm.log rather than failing silently');

-- The honest statement of the cost of committing between phases. While the constraint is stranded the
-- DEFAULT refuses the very range it is the only thing catching, because the partition that would take
-- those rows was never created.
select throws_ok($$ insert into public.ob71 values (5500, 'into the stranded range') $$, '23514', NULL,
  'while stranded, the DEFAULT REJECTS writes in that range: the new failure mode, stated plainly');

-- ============================ the next call clears it ============================
drop event trigger ob71_block_et;
drop function public.ob71_block();

call pgpm.obtain('public.ob71');

select is((select count(*)::int from pg_constraint
            where conrelid = 'public.ob71_default'::regclass and conname = 'pgpm_obtain_excl'),
  0, 'the next obtain clears the stranded constraint');

select ok(
  exists(select 1 from pgpm.part where parent_table = 'public.ob71'::regclass and lo = '5000'),
  'and builds the partition it was trying to build');

select lives_ok($$ insert into public.ob71 values (5500, 'into the stranded range') $$,
  'so the range accepts writes again');

-- ============================ a stale constraint for an UNRELATED range ============================
-- obtain RESTARTS rather than resumes: it never tries to match a leftover constraint back to a
-- candidate. It cannot safely, since the name is fixed and the range it covers may be one the current
-- config no longer produces. So any leftover is dropped outright, whatever range it names.
alter table public.ob71_default
  add constraint pgpm_obtain_excl check (id < 900000 or id >= 901000) not valid;

call pgpm.obtain('public.ob71');

select is((select count(*)::int from pg_constraint
            where conrelid = 'public.ob71_default'::regclass and conname = 'pgpm_obtain_excl'),
  0, 'a leftover naming a range the current config never produces is dropped, not resumed');

-- ============================ the empty-DEFAULT fast path is untouched ============================
create table public.ob71e (id bigint primary key, v text);
insert into public.ob71e select g, 'x' from generate_series(1, 2500) g;
call pgpm.transmute('public.ob71e', 'id', 1000, p_paused => false);
call pgpm.obtain('public.ob71e');

select is((select count(*)::int from pgpm.log
            where parent_table = 'public.ob71e'::regclass
              and action = 'obtain' and method = 'check_skip'),
  0, 'an empty DEFAULT still takes the single-statement plain path, with no constraint dance');

select * from finish();

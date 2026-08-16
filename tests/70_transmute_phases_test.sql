-- transmute's three-phase conversion and the machinery that makes it recoverable (issue #275).
--
-- transmute commits between adding the monolith bound, validating it, and cutting over, so the O(rows)
-- validation scan is not held under the ACCESS EXCLUSIVE lock the ADD takes. The price is that the bound
-- sits on the live table for the whole conversion, and a NOT VALID check still REJECTS new out-of-range
-- rows -- so a conversion that dies between phases leaves the table refusing writes it used to accept.
--
-- These pin the recovery paths. The lock behaviour itself cannot be asserted here: it needs a second
-- session observing a first one mid-scan, so it lives in bench/transmute_lock.sh (./test.sh perf).
--
-- An interrupted conversion is CONSTRUCTED rather than produced by killing a session mid-run, which no
-- test can do deterministically. The recorded bound is deliberately WIDER than a fresh computation would
-- produce, so "resumed" and "started over" give different answers and the assertion can tell them apart.
create extension if not exists pgtap;
select plan(15);

-- ============================ a successful conversion leaves nothing behind ============================
create table public.ph0 (id bigint primary key, v text);
insert into public.ph0 select g, 'x' from generate_series(1, 2500) g;
call pgpm.transmute('public.ph0', 'id', 1000);

select is((select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.ph0'::regclass),
  0, 'a completed conversion clears its in-flight record');

select is((select count(*)::int from pg_constraint
            where conname = 'pgpm_monolith_bound'
              and conrelid in (select oid from pg_class where relname like 'ph0%')),
  0, 'and leaves no monolith bound behind');

-- ============================ resume: interrupted after phase 1 ============================
-- Fresh computation for this table would give [0, 3000). The recorded bound says [0, 5000). If transmute
-- resumes it honours 5000; if it starts over it produces 3000.
create table public.ph1 (id bigint primary key, v text);
insert into public.ph1 select g, 'x' from generate_series(1, 2500) g;
alter table public.ph1 add constraint pgpm_monolith_bound check (id >= 0 and id < 5000) not valid;
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi)
  values ('public.ph1'::regclass, 'public', 'ph1', 'id', '0', '5000');

call pgpm.transmute('public.ph1', 'id', 1000);

select ok(
  exists(select 1 from pgpm.part where parent_table = 'public.ph1'::regclass and hi = '5000'),
  'a conversion interrupted after phase 1 RESUMES on the recorded bound, it does not recompute one');

select is((select relkind::text from pg_class where oid = 'public.ph1'::regclass), 'p',
  'and it completes: the table is partitioned');

select is((select count(*)::int from public.ph1), 2500, 'with every row intact');

select cmp_ok((select count(*) from pgpm.log
                where parent_table = 'public.ph1'::regclass and action = 'transmute_resume'),
  '>', 0::bigint, 'and the resume is recorded in pgpm.log');

-- ============================ resume: interrupted after phase 2 ============================
-- Same, but the bound is already VALIDATED, so the resume must skip the scan and go straight to cutover.
create table public.ph2 (id bigint primary key, v text);
insert into public.ph2 select g, 'x' from generate_series(1, 2500) g;
alter table public.ph2 add constraint pgpm_monolith_bound check (id >= 0 and id < 5000) not valid;
alter table public.ph2 validate constraint pgpm_monolith_bound;
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi)
  values ('public.ph2'::regclass, 'public', 'ph2', 'id', '0', '5000');

call pgpm.transmute('public.ph2', 'id', 1000);

select is((select relkind::text from pg_class where oid = 'public.ph2'::regclass), 'p',
  'a conversion interrupted after phase 2 also resumes and completes');

-- ============================ the reaper undoes an abandoned conversion ============================
-- No session holds the advisory lock for this constructed record, which is exactly the state a died-mid-run
-- conversion leaves, so the reaper must claim and undo it.
create table public.ph3 (id bigint primary key, v text);
insert into public.ph3 select g, 'x' from generate_series(1, 100) g;
alter table public.ph3 add constraint pgpm_monolith_bound check (id >= 0 and id < 1000) not valid;
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi)
  values ('public.ph3'::regclass, 'public', 'ph3', 'id', '0', '1000');

select throws_ok($$ insert into public.ph3 values (5000, 'past the bound') $$, '23514', NULL,
  'while the abandoned bound is in place the table rejects out-of-range writes');

select cmp_ok(pgpm._transmute_reap(), '>=', 1, 'the reaper claims the abandoned conversion');

select is((select count(*)::int from pg_constraint
            where conrelid = 'public.ph3'::regclass and conname = 'pgpm_monolith_bound'),
  0, 'and drops the bound');

select lives_ok($$ insert into public.ph3 values (5000, 'past the bound') $$,
  'so the table accepts those writes again');

select cmp_ok((select count(*) from pgpm.log
                where parent_table = 'public.ph3'::regclass and action = 'transmute_reap'),
  '>', 0::bigint, 'and says so in pgpm.log rather than doing it silently');

-- ============================ transmute_abort, for an operator who will not wait ============================
create table public.ph4 (id bigint primary key, v text);
insert into public.ph4 select g, 'x' from generate_series(1, 100) g;
alter table public.ph4 add constraint pgpm_monolith_bound check (id >= 0 and id < 1000) not valid;
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi)
  values ('public.ph4'::regclass, 'public', 'ph4', 'id', '0', '1000');

select ok(pgpm.transmute_abort('public.ph4'), 'transmute_abort reports that it undid a conversion');

select is(
  (select count(*)::int from pg_constraint
    where conrelid = 'public.ph4'::regclass and conname = 'pgpm_monolith_bound')
  + (select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.ph4'::regclass),
  0, 'leaving neither the bound nor the in-flight record');

-- ============================ headroom widens the bound ============================
-- Without headroom this table's monolith would end at 3000. Two extra grid steps push it to 5000, so a
-- writer running ahead of the frontier during the scan has room before the bound starts rejecting it.
create table public.ph5 (id bigint primary key, v text);
insert into public.ph5 select g, 'x' from generate_series(1, 2500) g;
call pgpm.transmute('public.ph5', 'id', 1000, p_bound_headroom => 2);

select ok(
  exists(select 1 from pgpm.part where parent_table = 'public.ph5'::regclass and hi = '5000'),
  'p_bound_headroom pushes the monolith bound further out (3000 -> 5000 at two steps)');

select * from finish();

-- regrain's change capture is anchored by IDENTITY, re-minted per regrain, and writable by the parent's
-- writers (issue #496).
--
-- Three defects, one root cause: the capture apparatus (the per-parent delta table and the trigger
-- function the source child's trigger drives) was found by NAME, derived from the parent's CURRENT
-- relname, and kept across regrains once minted. (1) A rename of the parent mid-regrain left the trigger
-- writing the delta it was given while reconcile, the swap gate and the swap all derived a new name, found
-- nothing, counted 0 pending and swapped: every change committed since the copy went with the source. (2)
-- The delta kept the key columns of the FIRST regrain while the trigger function was regenerated from the
-- CURRENT key, so a key column renamed between two regrains made every write into the source raise for the
-- life of the next one. (3) The delta was created by whoever ran regrain_step, with no grants, and the
-- trigger runs as the writer (pgpm has no SECURITY DEFINER anywhere), so every non-owner role with DML on
-- the parent got 42501 on every write into the regraining child.
--
-- The fix records the delta's and the function's oids in pgpm.config at prepare and resolves them from
-- there (falling back to the derived name only when nothing is recorded); drops and re-mints the delta on
-- every prepare, from the key as it is now; and gives the delta the parent's owner plus INSERT for every
-- role holding INSERT, UPDATE or DELETE on the parent, re-synced on every tick.
--
-- Every negative below ("the change is honoured", "the write does not raise") is paired with a witness
-- that the condition it denies was present: the derived name really changed, the delta really was minted
-- with the old key, the role really had no privilege on a delta nobody had granted.
-- bench/regrain_capture_identity.sh runs this file against mutants that put each defect back
-- (regrain_capture_by_name, regrain_delta_reused, regrain_delta_ungranted), so it is also required to
-- FAIL there.
create extension if not exists pgtap;
select plan(49);

-- drive a regrain to its swap. regrain_step commits nothing itself, so a loop in one function is fine for
-- the identity assertions below; nothing here reads the counters this repo warns about.
create function pg_temp.to_swap(p_parent regclass, p_child name, p_step text) returns text language plpgsql as $f$
declare s text; n int := 0;
begin
  loop
    s := pgpm.regrain_step(p_parent, p_child, p_step, 5000);
    exit when s like 'swapped:%';
    n := n + 1; if n > 60 then raise exception 'no swap (last %)', s; end if;
  end loop;
  return s;
end $f$;

-- ==================== (A) a parent renamed mid-regrain loses nothing ====================
create table public.ev (id bigint primary key, payload text);
insert into public.ev select g, 'orig' from generate_series(1, 1000) g;
insert into public.ev values (199999, 'widen');
call pgpm.transmute('public.ev', 'id', 100000);
select pgpm.obtain('public.ev');
insert into public.ev values (350000, 'frontier');   -- the frontier leaves the monolith: it is frozen

select is(pgpm.regrain_step('public.ev', 'ev_p0000000000000000000_to_0000000000000200000', '20000', 5000),
  'prepared', 'tick 1 prepares: capture is installed on the monolith');
select is((select regrain_delta_oid from pgpm.config where parent_table = 'public.ev'::regclass),
  'public.ev_pgpm_regrain_delta'::regclass::oid, 'prepare records the delta it minted, by oid');
select is((select regrain_capture_fn_oid from pgpm.config where parent_table = 'public.ev'::regclass),
  'public.ev_pgpm_regrain_capture()'::regprocedure::oid, 'and the trigger function it minted, by oid');

-- copy everything up to the swap's doorstep: the cursor at hi, the next tick the swap
do $$ declare s text; n int := 0; v_cur text; begin
  loop
    select regrain_cursor into v_cur from pgpm.config where parent_table = 'public.ev'::regclass;
    exit when v_cur is not null and v_cur::numeric >= 200000;
    s := pgpm.regrain_step('public.ev', 'ev_p0000000000000000000_to_0000000000000200000', '20000', 5000);
    n := n + 1; if n > 100 then raise exception 'no convergence (last %)', s; end if;
  end loop;
end $$;
select is((select payload from public.ev_p0000000000000000000 where id = 7), 'orig',
  'WITNESS: row 7 is already copied into its fine child, so the copy itself will never see what follows');

-- the operator renames the managed table: an ordinary ALTER TABLE, which pgpm.config follows by oid
alter table public.ev rename to events;
select is((select delta from pgpm._regrain_capture_derive('public.events')), 'events_pgpm_regrain_delta',
  'WITNESS: the name derived from the parent now differs from the delta the trigger was given');
select is((select delta from pgpm._regrain_capture_names('public.events')), 'ev_pgpm_regrain_delta',
  'the readers resolve the delta by its recorded oid, not by the parent''s current name');
select is((select fn from pgpm._regrain_capture_names('public.events')), 'ev_pgpm_regrain_capture',
  'and the trigger function likewise');

-- committed DML against already-copied rows while the regrain is in flight
update public.events set payload = 'updated' where id = 7;
delete from public.events where id = 8;
insert into public.events values (9500, 'inserted');
select is((select string_agg(id::text, ',' order by id) from public.ev_pgpm_regrain_delta), '7,7,8,9500',
  'WITNESS: the trigger captured all three (the update as old + new) into the delta it was given');
select is(pgpm._regrain_delta_count('public.events'), 4::bigint,
  'and the swap gate counts those 4 as pending, not 0');

select matches(pg_temp.to_swap('public.events', 'ev_p0000000000000000000_to_0000000000000200000', '20000'),
  '^swapped:', 'the regrain swaps under the new name');
select is((select payload from public.events where id = 7), 'updated', 'the committed UPDATE of id 7 is honoured');
select ok(not exists (select 1 from public.events where id = 8), 'the committed DELETE of id 8 is honoured');
select is((select payload from public.events where id = 9500), 'inserted', 'the committed INSERT of id 9500 is present');
select is((select count(*)::int from public.ev_pgpm_regrain_delta), 0,
  'the delta the trigger wrote is the one the swap cleared: no phantom backlog under the old name');
select ok(to_regclass('public.ev_p0000000000000000000_to_0000000000000200000') is null,
  'GUARD: the source is gone, so nothing above passed because the swap never happened');

-- ==================== (B) a key column renamed between two regrains ====================
create table public.b (id bigint not null, k2 int not null, payload text, primary key (id, k2));
insert into public.b select g*10, 1, 'x' from generate_series(1, 299) g;
call pgpm.transmute('public.b', 'id', 1000, p_obtain => 3);
select pgpm.obtain('public.b');
insert into public.b values (5000, 1, 'frontier');   -- the monolith [0, 3000) is frozen

select is(pgpm.regrain('public.b', 'b_p0000000000000000000_to_0000000000000003000', '1000'), 3,
  'first regrain: the monolith becomes three 1000-wide children');
select is((select array_agg(attname::text order by attnum) from pg_attribute
            where attrelid = 'public.b_pgpm_regrain_delta'::regclass and attnum > 0 and not attisdropped),
  array['id', 'k2', 'pgpm_seq'], 'WITNESS: the first regrain minted the delta with the key (id, k2)');
select regrain_delta_oid as b_delta1 from pgpm.config where parent_table = 'public.b'::regclass \gset

alter table public.b rename column k2 to k3;   -- propagates to every partition

select is(pgpm.regrain_step('public.b', 'b_p0000000000000000000', '100', 50), 'prepared',
  'second regrain: the prepare tick succeeds after the key rename');
select is((select array_agg(attname::text order by attnum) from pg_attribute
            where attrelid = 'public.b_pgpm_regrain_delta'::regclass and attnum > 0 and not attisdropped),
  array['id', 'k3', 'pgpm_seq'], 'the delta is re-minted from the key as it is NOW: (id, k3)');
select isnt((select regrain_delta_oid from pgpm.config where parent_table = 'public.b'::regclass), :'b_delta1'::oid,
  'as a new relation, recorded: the first regrain''s delta was not reused');
select is((select regrain_delta_oid from pgpm.config where parent_table = 'public.b'::regclass),
  'public.b_pgpm_regrain_delta'::regclass::oid, 'and the record points at the relation that now carries the name');

-- the #266 rename gives the source its coarse-form name on the target grid; follow it by lo
select child_name as bsrc from pgpm.part where parent_table = 'public.b'::regclass and lo = '0' and attached \gset
select ok(pgpm._regrain_capture_active('public.b', :'bsrc'), 'LIVENESS: capture is installed on the source');
select lives_ok($$ insert into public.b values (55, 1, 'backdated') $$,
  'a backdated INSERT into the source does not raise: the trigger inserts (id, k3) into a delta that has k3');
select is((select string_agg(id::text || '/' || k3::text, ',') from public.b_pgpm_regrain_delta), '55/1',
  'and it was captured, key and all');
select lives_ok($$ update public.b set payload = 'touched' where id = 60 and k3 = 1 $$, 'an UPDATE of a historical row does not raise either');
select lives_ok($$ delete from public.b where id = 70 and k3 = 1 $$, 'nor a DELETE');
do $$ declare s text; n int := 0; v_src name; begin
  select child_name into v_src from pgpm.part where parent_table = 'public.b'::regclass and lo = '0' and attached;
  loop
    s := pgpm.regrain_step('public.b', v_src, '100', 50);
    exit when s like 'swapped:%';
    n := n + 1; if n > 200 then raise exception 'no convergence (last %)', s; end if;
  end loop;
end $$;
select is((select string_agg(id::text || ':' || payload, ',' order by id) from public.b where id in (55, 60, 70)),
  '55:backdated,60:touched', 'after the swap: the backdated row is there, the update took, the deleted row stays gone');

-- ==================== (C) the parent's writers can write the delta ====================
-- Roles are cluster-wide; created if absent and dropped at the end, so a re-run and the other files are clean.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't124_owner')  then create role t124_owner;  end if;
  if not exists (select 1 from pg_roles where rolname = 't124_writer') then create role t124_writer; end if;
  if not exists (select 1 from pg_roles where rolname = 't124_late')   then create role t124_late;   end if;
end $$;
create table public.pv (id bigint primary key, payload text);
alter table public.pv owner to t124_owner;
grant select, insert, update, delete on public.pv to t124_writer;
insert into public.pv select g, 'x' from generate_series(1, 1000) g;
insert into public.pv values (199999, 'widen');
call pgpm.transmute('public.pv', 'id', 100000);
select pgpm.obtain('public.pv');
insert into public.pv values (350000, 'frontier');

set role t124_writer;
select lives_ok($$ update public.pv set payload = 'before' where id = 5 $$,
  'LIVENESS: the writer role can update a historical row before the regrain (its grants live on the parent)');
reset role;

select is(pgpm.regrain_step('public.pv', 'pv_p0000000000000000000_to_0000000000000200000', '20000', 5000),
  'prepared', 'the regrain is in flight (capture installed by the superuser running the tick)');
select is((select pg_get_userbyid(relowner) from pg_class where oid = 'public.pv_pgpm_regrain_delta'::regclass),
  't124_owner', 'the delta is owned like the parent, not by the role that ran the tick');
select ok(has_table_privilege('t124_writer', 'public.pv_pgpm_regrain_delta', 'INSERT'),
  'the writer role holds INSERT on the delta, mirroring its DML on the parent');
select ok(not has_table_privilege('t124_late', 'public.pv_pgpm_regrain_delta', 'INSERT'),
  'WITNESS: a role with no grant on the parent gets none on the delta');

set role t124_writer;
select lives_ok($$ update public.pv set payload = 'during' where id = 6 $$,
  'the writer role can update a historical row while the regrain is in flight');
select lives_ok($$ delete from public.pv where id = 7 $$, 'and delete one');
select lives_ok($$ insert into public.pv values (9600, 'app-inserted') $$, 'and insert a backdated one');
reset role;
set role t124_owner;
select lives_ok($$ update public.pv set payload = 'owner-during' where id = 9 $$,
  'the parent''s owner, who holds no explicit grant, can write too');
reset role;

-- a role granted DML on the parent AFTER the prepare tick: the next tick re-syncs the delta's grants
grant select, insert, update, delete on public.pv to t124_late;   -- SELECT too: an UPDATE ... WHERE reads
set role t124_late;
select throws_ok($$ update public.pv set payload = 'too-early' where id = 10 $$, '42501', null,
  'WITNESS: until a tick runs, a grant made after prepare has not reached the delta');
reset role;
select matches(pgpm.regrain_step('public.pv', 'pv_p0000000000000000000_to_0000000000000200000', '20000', 5000),
  '^copied:', 'the next tick copies');
select ok(has_table_privilege('t124_late', 'public.pv_pgpm_regrain_delta', 'INSERT'),
  'and re-syncs the grants: the late role now holds INSERT on the delta');
set role t124_late;
select lives_ok($$ update public.pv set payload = 'late-during' where id = 10 $$,
  'so the late role can write while the regrain is in flight');
reset role;

select matches(pg_temp.to_swap('public.pv', 'pv_p0000000000000000000_to_0000000000000200000', '20000'),
  '^swapped:', 'the regrain swaps');
select is((select string_agg(id || ':' || payload, ',' order by id) from public.pv where id in (5, 6, 7, 9, 10, 9600)),
  '5:before,6:during,9:owner-during,10:late-during,9600:app-inserted',
  'every write by every role is honoured after the swap, and the deleted row stays deleted');

reassign owned by t124_owner to current_user;
drop owned by t124_owner, t124_writer, t124_late;
drop role t124_owner, t124_writer, t124_late;

-- ==================== (D) nothing recorded resolves by the derived name, as before ====================
-- install.sql backfills the record for an install upgraded with a regrain in flight; should a record be
-- missing anyway, the readers fall back to the parent-derived name, where a pre-fix trigger writes, rather
-- than to nothing.
create table public.lg (id bigint primary key, payload text);
insert into public.lg select g, 'x' from generate_series(1, 100) g;
call pgpm.transmute('public.lg', 'id', 1000);
insert into public.lg values (5000, 'frontier');
select is(pgpm.regrain_step('public.lg', 'lg_p0000000000000000000', '100', 50), 'prepared', 'a regrain is in flight');
update pgpm.config set regrain_delta_oid = null, regrain_capture_fn_oid = null where parent_table = 'public.lg'::regclass;
delete from public.lg where id = 3;
select is((select delta from pgpm._regrain_capture_names('public.lg')), 'lg_pgpm_regrain_delta',
  'with nothing recorded, the resolver falls back to the derived name');
select is(pgpm._regrain_delta_count('public.lg'), 1::bigint, 'and the readers still see the captured change');
select pgpm.regrain_cancel('public.lg');

-- ==================== (E) a foreign relation on the derived name is refused, not adopted ====================
-- Before, prepare took whatever sat under the derived name for its delta and TRUNCATED it. Now a relation
-- there that is not the one this parent recorded is a refusal, naming it.
create table public.sq (id bigint primary key, payload text);
insert into public.sq select g, 'x' from generate_series(1, 100) g;
call pgpm.transmute('public.sq', 'id', 1000);
insert into public.sq values (5000, 'frontier');
create table public.sq_pgpm_regrain_delta (note text);
insert into public.sq_pgpm_regrain_delta values ('not yours');
select throws_like($$ select pgpm.regrain_step('public.sq', 'sq_p0000000000000000000', '100', 50) $$,
  'pg_partition_magician: cannot regrain % -- change capture would mint its delta table as public.sq_pgpm_regrain_delta, and that name is held by relation %',
  'the prepare tick refuses when another relation holds the name it would mint under');
select is((select note from public.sq_pgpm_regrain_delta), 'not yours', 'and it did not touch that relation');
select ok(not pgpm._regrain_capture_active('public.sq', 'sq_p0000000000000000000'), 'nor install capture');
drop table public.sq_pgpm_regrain_delta;
select is(pgpm.regrain_step('public.sq', 'sq_p0000000000000000000', '100', 50), 'prepared',
  'with the name free, the same tick prepares');

select * from finish();

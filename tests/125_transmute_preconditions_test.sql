-- transmute's preconditions on the TABLE and on the NAMES it will need, and the claim's view of its own
-- session (issue #509). Three defects, one shape: a condition the cutover was always going to trip on
-- was checked nowhere before it, so phases 1 and 2 committed a validated, write-rejecting
-- pgpm_monolith_bound CHECK plus a transmute_inflight claim, and the failure surfaced as a raw error from
-- inside the cutover, on a table the docs promised would be "untouched" by an up-front refusal.
--
--   A. transmute never asked whether p_parent was an unconverted plain table. Re-run on an already
--      converted table (the documented remedy after ANY failure, and what a client that lost its
--      connection after the cutover committed will do), phase 1 added the bound to the live PARTITIONED
--      parent, where it propagates to every partition including the forward ones taking writes; phase 2
--      validated it; the cutover then failed on the monolith's name, and the bound stayed, rejecting
--      every write past the original monolith's hi, i.e. every current write.
--   B. The orphan guard matched standalone TABLES named <rel>_p<digits>(_<digits>)* only. The monolith's
--      own coarse name <rel>_p<lo>_to_<hi> matched neither regex, so a relation holding it surfaced as a
--      42P07 from the cutover's RENAME with the bound and the claim left behind. A sequence, view or
--      index holding a CHILD name was skipped by the guard's relkind filter and then by obtain itself
--      (`continue when to_regclass(...) is not null`), so that conversion COMPLETED with no forward
--      partition and nothing logged: the first write past hi failed with `no partition of relation ...
--      found for row`, and every later tick skipped the name again.
--   C. The claim's take-over predicate was `not _session_alive(owner)`, and the owner of a claim left by a
--      cutover failure is the still-connected operator's own session, which reads as alive. So the
--      documented remedies, "re-run transmute, it resumes" and transmute_abort, were BOTH refused with
--      "already in progress in another session" to the very session that owned it, and the bound stayed
--      until that session disconnected, which no document said.
--
-- INSTRUMENT. The failing conversions run through dblink, for two reasons that both matter here. A
-- committing procedure inside throws_ok dies at its first COMMIT with 2D000 (tests/83's header), and
-- pg_prove runs this file under ON_ERROR_STOP, so a failing top-level CALL would end it. More to the
-- point, a mutant that fails LATE, in the cutover, must be allowed to really commit phases 1 and 2, so
-- that the damage each refusal exists to prevent (the bound on the live parent, the claim, the
-- 42P07) is observable and the state assertions below discriminate, instead of being satisfied by the
-- wrapper's own rollback. Part C keeps ONE dblink connection ('op') open across the failure, the retry
-- and the abort: that connection is one backend, so "the same session" is literal, and the second
-- connection ('holder') supplies the cutover failure deterministically (an open transaction holding
-- ACCESS SHARE on the referencing table, which the preserve-FK drop's ACCESS EXCLUSIVE waits behind
-- until p_lock_timeout), the shape tests/112 B already uses, with no poll and no race.
--
-- WITNESSES. Every refusal is paired with proof the condition it denies was present (the table really is
-- converted, the name really is the one the conversion needs, the claim's owner really reads as alive
-- and really is the op backend), and with a liveness witness that the same call succeeds once the
-- condition is removed, so a transmute that refused everything could not pass this file. Part C also
-- pins that the fix is scoped to the owner: a DIFFERENT live session is still refused both ways.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(49);

-- ====================================== A. an already converted table ======================================
create table public.dt (id bigint primary key, v int);
insert into public.dt select i, i from generate_series(1, 2500) i;
call pgpm.transmute('public.dt', 'id', 1000, p_obtain => 1);

select is((select relkind::text from pg_class where oid = 'public.dt'::regclass), 'p',
  'A WITNESS: dt is converted (a partitioned parent)');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.dt'::regclass
                    and child_name = 'dt_p0000000000000003000'),
  'A WITNESS: the forward partition [3000, 4000) exists');
-- A write past the monolith lands in the forward partition. Removed again so max(id) stays inside the
-- monolith: the re-run then recomputes the SAME bound and collides with the real monolith's name, which
-- is the path that leaves the bound on the live parent (with a higher frontier it instead succeeds and
-- nests the whole table under a second parent; either is the defect, this one is the one that hurts).
insert into public.dt values (3500, 1);
select is((select tableoid::regclass::text from public.dt where id = 3500), 'dt_p0000000000000003000',
  'A WITNESS: a write past the monolith lands in the forward partition before the re-run');
delete from public.dt where id = 3500;

select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.dt', 'id', 1000, p_obtain => 1) $c$) $$,
  'pg_partition_magician: dt is already converted and managed by pgpm%',
  'A: a re-run against the converted table is refused by pgpm, up front, naming the reason');

-- The damage the refusal prevents: no bound anywhere in the dt family (the parent, or any partition it
-- would have propagated to), one config row, no claim, and a write past the monolith still lands.
select is((select count(*)::int from pg_constraint
            where conname = 'pgpm_monolith_bound'
              and conrelid in (select 'public.dt'::regclass::oid
                               union all select inhrelid from pg_inherits where inhparent = 'public.dt'::regclass)),
  0, 'A: no pgpm_monolith_bound CHECK on the live parent or any of its partitions');
select is((select count(*)::int from pgpm.config where parent_table = 'public.dt'::regclass), 1,
  'A: still exactly one pgpm.config row for dt');
select ok(not exists (select 1 from pgpm.transmute_inflight where rel = 'dt'),
  'A: no transmute_inflight claim was left for dt');
insert into public.dt values (3501, 1);
select is((select tableoid::regclass::text from public.dt where id = 3501), 'dt_p0000000000000003000',
  'A: a write past the monolith still lands in the forward partition after the refused re-run');

-- A2. The monolith partition itself: relkind 'r', not in pgpm.config, but ATTACHED. A relkind-only check
-- passes it; the cutover would fail on "is already a partition" after committing the bound.
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.dt_p0000000000000000000_to_0000000000000003000', 'id', 1000, p_obtain => 1) $c$) $$,
  'pg_partition_magician: dt_p0000000000000000000_to_0000000000000003000 is already a partition of dt%',
  'A2: the monolith partition (a plain-relkind table that is attached) is refused too, naming its parent');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.dt_p0000000000000000000_to_0000000000000003000'::regclass
                         and conname = 'pgpm_monolith_bound'),
  'A2: no pgpm_monolith_bound CHECK on the monolith');
select ok(not exists (select 1 from pgpm.transmute_inflight where rel like 'dt_p%'),
  'A2: no claim was left for it');

-- A4. The other manifestation: the frontier PAST the monolith. The re-run then computes a monolith name
-- that is free ([0, 4000)), so the name check before phase 1 cannot catch it, and on the unfixed code the
-- re-run SUCCEEDED: it renamed the live parent, attached it as a sub-partitioned monolith under a second
-- parent, and left two pgpm.config rows. Only the shape check refuses this one.
create table public.dn (id bigint primary key, v int);
insert into public.dn select i, i from generate_series(1, 2500) i;
call pgpm.transmute('public.dn', 'id', 1000, p_obtain => 1);
insert into public.dn values (3500, 1);
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.dn', 'id', 1000, p_obtain => 1) $c$) $$,
  'pg_partition_magician: dn is already converted and managed by pgpm%',
  'A4: with the frontier past the monolith the re-run is refused just the same');
select is((select count(*)::int from pgpm.config c join pg_class r on r.oid = c.parent_table
            where r.relname like 'dn%'),
  1, 'A4: one pgpm.config row for the dn family, not a second one for a nested parent');
select is((select inhparent::regclass::text from pg_inherits
            where inhrelid = 'public.dn_p0000000000000000000_to_0000000000000003000'::regclass),
  'dn', 'A4: the monolith is still a direct partition of dn, not of a parent nested under a new dn');

-- A3. An inheritance PARENT: relkind 'r', unattached, but PostgreSQL refuses to attach an inheritance
-- parent as a partition, which the cutover would have discovered after phases 1 and 2.
create table public.inh_parent (id bigint primary key, v int);
create table public.inh_child () inherits (public.inh_parent);
insert into public.inh_parent select i, i from generate_series(1, 100) i;
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.inh_parent', 'id', 1000, p_obtain => 1) $c$) $$,
  'pg_partition_magician: inh_parent has inheritance children%',
  'A3: an inheritance parent is refused up front');
select is((select count(*)::int from pg_constraint
            where conrelid = 'public.inh_parent'::regclass and conname = 'pgpm_monolith_bound')
        + (select count(*)::int from pgpm.transmute_inflight where rel = 'inh_parent'),
  0, 'A3: leaving neither a bound nor a claim');

-- ====================================== B. the names the cutover will need ======================================
-- B1. The monolith's own coarse name. id grid, step 1000, anchor 0: min 1 floors to 0, max 2500 floors
-- to 2000, hi 3000, so the name is deterministic (no clock involved).
create table public.ev (id bigint primary key, payload text);
insert into public.ev select i, 'x' from generate_series(1, 2500) i;
select is(pgpm._part_name('ev', 'id', '1000', '0', '3000', 'UTC')::text,
  'ev_p0000000000000000000_to_0000000000000003000',
  'B WITNESS: the monolith name this conversion will need');
-- a standalone table already answers to it (an operator leftover; a partition of nothing)
create table public.ev_p0000000000000000000_to_0000000000000003000 (id bigint);

select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.ev', 'id', 1000, p_obtain => 1) $c$) $$,
  'pg_partition_magician: public.ev_p0000000000000000000_to_0000000000000003000 already exists, and transmute needs that name for the monolith%',
  'B: the collision is refused by pgpm up front, naming the relation, not as a raw error from inside the cutover');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.ev'::regclass and conname = 'pgpm_monolith_bound'),
  'B: no pgpm_monolith_bound CHECK left on ev');
select ok(not exists (select 1 from pgpm.transmute_inflight where rel = 'ev'),
  'B: no transmute_inflight claim left for ev');
select is((select relkind::text from pg_class where oid = 'public.ev'::regclass), 'r',
  'B: ev is still a plain table');

-- LIVENESS for the refusal: with the squatter gone the SAME call converts ev, and the monolith takes
-- exactly the name the refusal was protecting.
drop table public.ev_p0000000000000000000_to_0000000000000003000;
call pgpm.transmute('public.ev', 'id', 1000, p_obtain => 1);
select is((select child_name::text from pgpm.part where parent_table = 'public.ev'::regclass
            and child_name = 'ev_p0000000000000000000_to_0000000000000003000'),
  'ev_p0000000000000000000_to_0000000000000003000',
  'B LIVENESS: without the squatter the same call converts ev, and the monolith takes exactly that name');

-- B2. A NON-TABLE relation holding a child's name: here the first forward partition's, [3000, 4000). The
-- orphan guard's relkind filter skipped it, and so did obtain in the cutover (it skips any candidate
-- whose name is taken, by design, because that is how it recognises a partition it already made), so the
-- unfixed conversion COMPLETED with no forward partition. The discriminator is therefore not an error
-- message but the table itself: after a refusal it is still a plain table; after the silent version it
-- is a partitioned parent whose first write past hi fails with "no partition of relation found for row".
create table public.ev2 (id bigint primary key, payload text);
insert into public.ev2 select i, 'x' from generate_series(1, 2500) i;
create sequence public.ev2_p0000000000000003000;

select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.ev2', 'id', 1000, p_obtain => 1) $c$) $$,
  'pg_partition_magician: public.ev2_p0000000000000003000 already exists as a sequence matching this parent''s partition naming%',
  'B2: a sequence holding a child name is refused up front, naming it and its kind');
select is((select relkind::text from pg_class where oid = 'public.ev2'::regclass), 'r',
  'B2: ev2 is still a plain table (the unfixed code converted it with no forward partition at all)');
select is((select count(*)::int from pg_constraint
            where conrelid = 'public.ev2'::regclass and conname = 'pgpm_monolith_bound')
        + (select count(*)::int from pgpm.transmute_inflight where rel = 'ev2'),
  0, 'B2: leaving neither a bound nor a claim on ev2');
drop sequence public.ev2_p0000000000000003000;
call pgpm.transmute('public.ev2', 'id', 1000, p_obtain => 1);
select is((select child_name::text from pgpm.part where parent_table = 'public.ev2'::regclass
            and child_name = 'ev2_p0000000000000003000'),
  'ev2_p0000000000000003000',
  'B2 LIVENESS: without the sequence the same call converts ev2 and creates that very partition');

-- ====================================== C. the claim and its own session ======================================
-- One backend for the operator across the failure, the retry and the abort.
select dblink_connect('op', 'dbname=' || current_database());
-- A session-level ceiling on the op connection, as tests/112 B gives its conversion: the phases override
-- it with p_lock_timeout, so it changes nothing here; it exists so a regression that moved a lock wait
-- outside the phases fails this file loudly instead of hanging it on the holder.
select dblink_exec('op', $$ set lock_timeout = '5s' $$);
create temp table op_id as select * from dblink('op', 'select pg_backend_pid()') as t(pid int);

-- C1. The failure: the referencing table is held under ACCESS SHARE by an open transaction, so the
-- cutover's preserve-FK drop waits for ACCESS EXCLUSIVE and gives up at p_lock_timeout.
create table public.rt (id bigint primary key, payload text);
insert into public.rt select i, 'x' from generate_series(1, 2500) i;
create table public.rt_child (id bigint primary key, rt_id bigint references public.rt (id));
insert into public.rt_child values (1, 1), (2, 2);

select dblink_connect('holder', 'dbname=' || current_database());
select dblink_exec('holder', 'begin');
select * from dblink('holder', 'select count(*) from public.rt_child') as t(c bigint);
select is((select count(*)::int from pg_locks
            where relation = 'public.rt_child'::regclass and mode = 'AccessShareLock' and granted
              and pid <> pg_backend_pid()),
  1, 'C WITNESS: the holder holds ACCESS SHARE on the referencing table');

select throws_ok(
  $$ select dblink_exec('op', $c$ call pgpm.transmute('public.rt', 'id', 1000, p_obtain => 1,
                                   p_incoming_fks => 'preserve', p_lock_timeout => '300ms') $c$) $$,
  '55P03', 'canceling statement due to lock timeout',
  'C: the cutover gives up on the referencing table''s lock');

-- The recorded, resumable state, and WHOSE it is: this is the condition the defect trips on.
select ok((select convalidated from pg_constraint
            where conrelid = 'public.rt'::regclass and conname = 'pgpm_monolith_bound'),
  'C WITNESS: phases 1 and 2 committed (the validated bound is on rt): the failure was in the cutover');
select is((select owner_pid from pgpm.transmute_inflight where rel = 'rt'), (select pid from op_id),
  'C WITNESS: the claim is owned by the op backend');
select ok((select pgpm._session_alive(owner_pid, owner_backend_start) from pgpm.transmute_inflight where rel = 'rt'),
  'C WITNESS: and that owner reads as alive, because it is');

-- Scope: a DIFFERENT live session (this one) is still refused. The fix must not have made the claim free
-- for all; the owner alone may resume.
select throws_ok(
  $$ call pgpm.transmute('public.rt', 'id', 1000, p_obtain => 1, p_incoming_fks => 'preserve') $$,
  'P0001', 'pg_partition_magician: a transmute of rt is already in progress in another session',
  'C: from ANOTHER session the same conversion is still refused while the owner is alive');

-- The blocker is gone before the retry.
select dblink_exec('holder', 'commit');
select dblink_disconnect('holder');
select is((select count(*)::int from pg_locks
            where relation = 'public.rt_child'::regclass and mode = 'AccessShareLock' and granted
              and pid <> pg_backend_pid()),
  0, 'C WITNESS: the holder has released the referencing table');

-- THE DEFECT (retry). The documented remedy, from the session that owns the claim.
select lives_ok(
  $$ select dblink_exec('op', $c$ call pgpm.transmute('public.rt', 'id', 1000, p_obtain => 1,
                                   p_incoming_fks => 'preserve') $c$) $$,
  'C: the owning session re-runs transmute and is NOT refused as another session''s');
select is((select relkind::text from pg_class where oid = 'public.rt'::regclass), 'p',
  'C: the re-run converted rt');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.rt'::regclass and action = 'transmute_resume'),
  1, 'C WITNESS: it RESUMED on the recorded bound rather than starting over');
select is((select child_name::text from pgpm.part where parent_table = 'public.rt'::regclass
            and child_name = 'rt_p0000000000000000000_to_0000000000000003000'),
  'rt_p0000000000000000000_to_0000000000000003000',
  'C: the monolith carries the recorded bound [0, 3000)');
select ok(not exists (select 1 from pgpm.transmute_inflight where rel = 'rt'),
  'C: the completed re-run released the claim');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.rt'::regclass and conname = 'pgpm_monolith_bound'),
  'C: and no pgpm_monolith_bound remains on the new parent');

-- C2. THE DEFECT (abort). Same failure on a second table; the other documented remedy, from the owner.
create table public.ab (id bigint primary key, payload text);
insert into public.ab select i, 'x' from generate_series(1, 2500) i;
create table public.ab_child (id bigint primary key, ab_id bigint references public.ab (id));
insert into public.ab_child values (1, 1);

select dblink_connect('holder', 'dbname=' || current_database());
select dblink_exec('holder', 'begin');
select * from dblink('holder', 'select count(*) from public.ab_child') as t(c bigint);
select throws_ok(
  $$ select dblink_exec('op', $c$ call pgpm.transmute('public.ab', 'id', 1000, p_obtain => 1,
                                   p_incoming_fks => 'preserve', p_lock_timeout => '300ms') $c$) $$,
  '55P03', 'canceling statement due to lock timeout',
  'C2: the cutover gives up on the referencing table''s lock');
select dblink_exec('holder', 'commit');
select dblink_disconnect('holder');
select is((select owner_pid from pgpm.transmute_inflight where rel = 'ab'), (select pid from op_id),
  'C2 WITNESS: the claim is owned by the op backend');
select ok((select convalidated from pg_constraint
            where conrelid = 'public.ab'::regclass and conname = 'pgpm_monolith_bound'),
  'C2 WITNESS: the validated bound is on ab');
select throws_ok(
  $$ insert into public.ab values (9000, 'past the bound') $$,
  '23514', 'new row for relation "ab" violates check constraint "pgpm_monolith_bound"',
  'C2 WITNESS: the bound is rejecting a write past hi, which is what the abort exists to end');

-- Scope again: from a different live session the abort is still refused.
select throws_ok(
  $$ select pgpm.transmute_abort('public.ab') $$,
  'P0001', 'pg_partition_magician: cannot abort the transmute of ab -- it is still running in another session',
  'C2: from ANOTHER session the abort is still refused while the owner is alive');

select lives_ok(
  $$ select * from dblink('op', $c$ select pgpm.transmute_abort('public.ab') $c$) as t(b boolean) $$,
  'C2: the owning session aborts its own failed conversion and is NOT refused');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.ab'::regclass and conname = 'pgpm_monolith_bound'),
  'C2: the bound is gone');
select ok(not exists (select 1 from pgpm.transmute_inflight where rel = 'ab'),
  'C2: and so is the claim');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.ab'::regclass and action = 'transmute_abort'),
  1, 'C2: logged as transmute_abort');
insert into public.ab values (9000, 'past the bound');
select is((select payload from public.ab where id = 9000), 'past the bound',
  'C2 LIVENESS: the write the bound was rejecting lands on the restored table');

select dblink_disconnect('op');

select * from finish();

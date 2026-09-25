-- A preserve-managed incoming FK survives a conversion that fails after phase 1 (issue #444).
--
-- transmute runs in three transactions (#275): add the monolith bound, validate it, cut over. Under
-- p_incoming_fks => 'preserve' the incoming FK used to be DROPPED in the first of them, before the claim
-- and phase 1's commit, while the pgpm.dropped_fk row that lets restore_incoming_fks re-add it was
-- written only in the cutover. A phase 2 or 3 failure therefore lost the key with no record of it:
-- transmute_abort put the CHECK back and logged "table restored", the referencing table accepted
-- orphans, and a clean re-run had nothing left to restore. Measured on PG 17.11 against a72c5bf.
--
-- The fix moves the drop INTO the cutover, into the same transaction as the record. So the contract
-- pinned here is: a failure in phase 1 or 2 leaves the key exactly where it was (nothing dropped,
-- nothing recorded), a failure in the cutover rolls the drop back with everything else, and only a
-- completed conversion has a key to restore.
--
-- INSTRUMENT. The phase 2 failure is only reachable when the CALL runs at the top level of a session:
-- a committing procedure inside throws_ok dies at phase 1's COMMIT with 2D000 and never gets there
-- (tests/83's header), and pg_prove runs this file under ON_ERROR_STOP, so a failing top-level CALL
-- would end it. The failing conversions therefore run in a second session through dblink (as tests/60
-- and 77 already do for their second sessions): dblink_exec re-raises the remote error with its own
-- SQLSTATE and primary message, which throws_ok then pins exactly. That backend's exit is asynchronous
-- once its connection closes, so rather than poll pg_stat_activity for it (a timing race), the claim's
-- owner is cleared before the abort and the re-run, tests/101's stand-in for a session that has ended.
--
-- WITNESSES. Every "the key is still there" below is paired with proof that the conversion got as far
-- as claimed (the bound CHECK is on the table, NOT VALID after a phase 2 failure and VALIDATED after a
-- cutover failure), and the completed re-run must actually drop and record the key before restore
-- brings it back, so a preserve path that had quietly become a no-op could not pass this file.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(35);

-- ============================ A. phase 2 fails; abort; clean re-run ============================
-- The stray row 10 days out sits past the bound the conversion computes from now(), so phase 1's
-- ADD ... NOT VALID succeeds and phase 2's VALIDATE fails. Composite key, ON DELETE CASCADE.
create table public.pf (id bigint not null, created_at timestamptz not null, payload text,
                        primary key (id, created_at));
insert into public.pf select g, now() - (g || ' hours')::interval, 'x' from generate_series(1, 100) g;
insert into public.pf values (5000, now() + interval '10 days', 'stray');
create table public.pf_child (cid bigint primary key, p_id bigint not null, p_at timestamptz not null,
  constraint pf_child_fk foreign key (p_id, p_at) references public.pf (id, created_at) on delete cascade);
-- asymmetric: two children of parent 1, one each of parents 2 and 3, so a cascade can be told from a
-- missing cascade AND from a cascade of the wrong parent.
insert into public.pf_child select 11, id, created_at from public.pf where id = 1;
insert into public.pf_child select 12, id, created_at from public.pf where id = 1;
insert into public.pf_child select 21, id, created_at from public.pf where id = 2;
insert into public.pf_child select 31, id, created_at from public.pf where id = 3;

select throws_ok(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.pf', 'created_at', interval '1 day', p_incoming_fks => 'preserve') $c$) $$,
  '23514', 'check constraint "pgpm_monolith_bound" of relation "pf" is violated by some row',
  'A: the conversion fails in phase 2, on the stray');

select ok(exists (select 1 from pg_constraint
                   where conrelid = 'public.pf'::regclass and conname = 'pgpm_monolith_bound'
                     and not convalidated),
  'A WITNESS: phase 1 committed (the bound is on the table) and phase 2 did not (it is NOT VALID)');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.pf'::regclass), 1,
  'A: the claim row is still there');
select is((select relkind::text from pg_class where oid = 'public.pf'::regclass), 'r',
  'A: and the table is not partitioned');

-- THE DEFECT. Pre-fix the key was already gone here, and nothing knew it had existed.
select is((select confrelid::regclass::text from pg_constraint
            where conrelid = 'public.pf_child'::regclass and conname = 'pf_child_fk' and contype = 'f'),
  'pf', 'A: the incoming FK is still on the referencing table, referencing the table it always did');
select is((select count(*)::int from pgpm.dropped_fk where referencing_table = 'public.pf_child'::regclass), 0,
  'A: and nothing is recorded as dropped, because nothing was');
select throws_ok(
  $$ insert into public.pf_child values (99, 123456789, now()) $$,
  '23503', 'insert or update on table "pf_child" violates foreign key constraint "pf_child_fk"',
  'A: an orphan is refused while the conversion sits half done');

-- The dblink backend has ended; clear the owner it recorded (see the header) so the abort proceeds.
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null
 where parent_table = 'public.pf'::regclass;

select ok(pgpm.transmute_abort('public.pf'), 'A: transmute_abort undoes the half-done conversion');
select is(
  (select count(*)::int from pg_constraint
    where conrelid = 'public.pf'::regclass and conname = 'pgpm_monolith_bound')
  + (select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.pf'::regclass),
  0, 'A: leaving neither the bound nor the claim');
select is((select confrelid::regclass::text from pg_constraint
            where conrelid = 'public.pf_child'::regclass and conname = 'pf_child_fk' and contype = 'f'),
  'pf', 'A: the table is back exactly as it was, incoming FK included');
select throws_ok(
  $$ insert into public.pf_child values (99, 123456789, now()) $$,
  '23503', 'insert or update on table "pf_child" violates foreign key constraint "pf_child_fk"',
  'A: an orphan is refused after the abort');
delete from public.pf where id = 1;
select is((select array_agg(cid order by cid) from public.pf_child), array[21, 31]::bigint[],
  'A: ON DELETE CASCADE still fires: parent 1''s two children went with it, 21 and 31 stayed');

-- Clean re-run: with the stray gone the same call converts the table. This is the LIVENESS WITNESS for
-- the whole file: the cutover must really drop and record the key, or "still present" above would be
-- equally satisfied by a preserve path that no longer does anything.
delete from public.pf where id = 5000;
call pgpm.transmute('public.pf', 'created_at', interval '1 day', p_incoming_fks => 'preserve');

select is((select relkind::text from pg_class where oid = 'public.pf'::regclass), 'p',
  'A: the same call converts the table once the stray is gone');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.pf_child'::regclass and conname = 'pf_child_fk'),
  'A LIVENESS: the cutover dropped the incoming FK');
select is((select count(*)::int from pgpm.dropped_fk
            where parent_table = 'public.pf'::regclass and referencing_table = 'public.pf_child'::regclass
              and constraint_name = 'pf_child_fk' and restored_at is null),
  1, 'A LIVENESS: and recorded it once, against the new parent');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.pf'::regclass and action = 'drop_incoming_fk' and method = 'pf_child_fk'),
  1, 'A: with one drop_incoming_fk log row');
select is(pgpm.restore_incoming_fks('public.pf'), 1, 'A: restore_incoming_fks re-adds it');
select is((select c.confrelid::regclass::text || ' (' || r.relkind::text || ')'
             from pg_constraint c join pg_class r on r.oid = c.confrelid
            where c.conrelid = 'public.pf_child'::regclass and c.conname = 'pf_child_fk' and c.contype = 'f'),
  'pf (p)', 'A: against the new partitioned parent');
select throws_ok(
  $$ insert into public.pf_child values (99, 123456789, now()) $$,
  '23503', 'insert or update on table "pf_child" violates foreign key constraint "pf_child_fk"',
  'A: an orphan is refused after the restore');
delete from public.pf where id = 2;
select is((select array_agg(cid order by cid) from public.pf_child), array[31]::bigint[],
  'A: ON DELETE CASCADE fires through the partitioned parent: 21 went with parent 2, 31 stayed');

-- ============================ B. the cutover fails; the drop rolls back with it ============================
-- A second session holds an open transaction that has read the REFERENCING table. That touches nothing
-- in phases 1 or 2, which only take locks on the table being converted, and blocks exactly one thing in
-- the cutover: the ACCESS EXCLUSIVE the FK drop needs on the referencing table. With a short
-- p_lock_timeout the cutover gives up there, and the claim is that nothing of it survives.
--
-- The conversion's own session gets a 2 s session-level lock_timeout through the connection string.
-- The phases override it with their own, so it changes nothing here; it exists so that a regression
-- putting the drop back before the claim, where no phase timeout covers it, fails this file loudly
-- instead of hanging it on the holder's lock.
create table public.pfl (id bigint not null, created_at timestamptz not null, payload text,
                         primary key (id, created_at));
insert into public.pfl select g, now() - (g || ' hours')::interval, 'x' from generate_series(1, 100) g;
create table public.pfl_child (cid bigint primary key, p_id bigint not null, p_at timestamptz not null,
  constraint pfl_child_fk foreign key (p_id, p_at) references public.pfl (id, created_at) on delete cascade);
insert into public.pfl_child select 11, id, created_at from public.pfl where id = 1;

select dblink_connect('holder', 'dbname=' || current_database());
select dblink_exec('holder', 'begin');
select * from dblink('holder', 'select count(*) from public.pfl_child') as t(c bigint);

select throws_ok(
  $$ select dblink_exec('dbname=' || current_database() || ' options=''-c lock_timeout=2s''',
       $c$ call pgpm.transmute('public.pfl', 'created_at', interval '1 day',
                                p_incoming_fks => 'preserve', p_lock_timeout => '300ms') $c$) $$,
  '55P03', 'canceling statement due to lock timeout',
  'B: the cutover gives up on the referencing table''s lock');

select ok(exists (select 1 from pg_constraint
                   where conrelid = 'public.pfl'::regclass and conname = 'pgpm_monolith_bound'
                     and convalidated),
  'B WITNESS: phases 1 and 2 both committed (the bound is on the table and VALIDATED): the failure was in the cutover');
select is((select relkind::text from pg_class where oid = 'public.pfl'::regclass), 'r',
  'B: the table is not partitioned');
select is((select confrelid::regclass::text from pg_constraint
            where conrelid = 'public.pfl_child'::regclass and conname = 'pfl_child_fk' and contype = 'f'),
  'pfl', 'B: the incoming FK is still on the referencing table: the drop rolled back with the cutover');
select is(
  (select count(*)::int from pgpm.dropped_fk where referencing_table = 'public.pfl_child'::regclass)
  + (select count(*)::int from pgpm.log where action = 'drop_incoming_fk' and method = 'pfl_child_fk'),
  0, 'B: and neither the record nor the log row of a drop survived');

select dblink_exec('holder', 'commit');
select dblink_disconnect('holder');
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null
 where parent_table = 'public.pfl'::regclass;
call pgpm.transmute('public.pfl', 'created_at', interval '1 day', p_incoming_fks => 'preserve');

select is((select relkind::text from pg_class where oid = 'public.pfl'::regclass), 'p',
  'B: the same call completes once the lock is gone');
select is((select count(*)::int from pgpm.dropped_fk
            where parent_table = 'public.pfl'::regclass and referencing_table = 'public.pfl_child'::regclass
              and constraint_name = 'pfl_child_fk'),
  1, 'B: recording the key once');
select is(pgpm.restore_incoming_fks('public.pfl'), 1, 'B: and restore_incoming_fks re-adds it');

-- ============================ C. resume without an abort: recorded once ============================
-- Same phase 2 failure, but the operator deletes the stray and re-runs instead of aborting. The
-- re-run takes over the claim and reuses the recorded bound (tests/70), and must end with exactly one
-- record of the key and exactly one restore.
create table public.pfr (id bigint not null, created_at timestamptz not null, payload text,
                         primary key (id, created_at));
insert into public.pfr select g, now() - (g || ' hours')::interval, 'x' from generate_series(1, 100) g;
insert into public.pfr values (5000, now() + interval '10 days', 'stray');
create table public.pfr_child (cid bigint primary key, p_id bigint not null, p_at timestamptz not null,
  constraint pfr_child_fk foreign key (p_id, p_at) references public.pfr (id, created_at) on delete cascade);
insert into public.pfr_child select 11, id, created_at from public.pfr where id = 1;

select throws_ok(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.pfr', 'created_at', interval '1 day', p_incoming_fks => 'preserve') $c$) $$,
  '23514', 'check constraint "pgpm_monolith_bound" of relation "pfr" is violated by some row',
  'C: the conversion fails in phase 2, on the stray');
select is((select confrelid::regclass::text from pg_constraint
            where conrelid = 'public.pfr_child'::regclass and conname = 'pfr_child_fk' and contype = 'f'),
  'pfr', 'C: the incoming FK is still on the referencing table');

delete from public.pfr where id = 5000;
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null
 where parent_table = 'public.pfr'::regclass;
call pgpm.transmute('public.pfr', 'created_at', interval '1 day', p_incoming_fks => 'preserve');

select is((select relkind::text from pg_class where oid = 'public.pfr'::regclass), 'p',
  'C: the re-run completes');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.pfr'::regclass and action = 'transmute_resume'),
  1, 'C WITNESS: it RESUMED on the recorded bound rather than starting over');
select is((select count(*)::int from pgpm.dropped_fk where referencing_table = 'public.pfr_child'::regclass), 1,
  'C: the key is recorded exactly once');
select is(pgpm.restore_incoming_fks('public.pfr'), 1, 'C: and restored exactly once');
select is((select count(*)::int from pg_constraint
            where conrelid = 'public.pfr_child'::regclass and contype = 'f'
              and confrelid = 'public.pfr'::regclass),
  1, 'C: leaving one FK on the referencing table, pointing at the new parent');

select * from finish();

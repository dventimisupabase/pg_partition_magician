-- regrain_step's swap must reconcile EVERY captured change before it drops the source (issue #447).
--
-- THE DEFECT. After the DETACH, the swap drained the change-capture delta with a loop bounded at 100
-- passes of greatest(batch, 1000) keys, then attached the fine children, dropped the source and truncated
-- the delta, with nothing checking that the loop had stopped because the delta was empty. The comment
-- said the DETACH guaranteed termination, which is true of the writer, not of the loop. The pre-swap gate
-- bounds only what had committed before it ran: a writer that already holds a row in the source keeps the
-- DETACH waiting for its ROW EXCLUSIVE, and everything it commits during that wait lands in the delta
-- AFTER the gate. Under maintain the DETACH has a 200 ms lock_timeout, so the exposure is a writer
-- committing more than 100 * batch changes inside that window; under an operator-driven regrain_step
-- there is no timeout, and a large history purge committing during the wait is exactly this shape.
--
-- THE PROBE. Two sessions, ordered by lock state rather than by sleeps. The writer (a dblink session)
-- inserts one row into the source and holds its transaction open: that is the lock the swap's DETACH
-- must wait for. This session then runs the swap tick, which passes the gate (the writer's row is
-- uncommitted, so the delta reads empty) and blocks on the DETACH. The writer polls pg_locks until it
-- sees that ungranted ACCESS EXCLUSIVE, records the observation, and only then commits 120,001 more
-- captured changes on top of its sentinel: 120,000 inserts, then one DELETE of an already-copied row,
-- LAST, so it carries the highest pgpm_seq and is the first thing a bounded drain leaves behind. The
-- swap then proceeds with 120,002 captured keys against a batch of 1000: 121 passes, 21 past the bound.
--
-- Every negative below ("no late row is missing", "the deleted row is not resurrected") is paired with
-- a witness that the condition it denies was present: the writer's recorded observation of the swap's
-- ungranted lock, and the reconcile log showing more than 100 passes at the swap whose consumed-row
-- total equals what was captured. bench/regrain_swap_reconcile.sh drives this file against a mutant
-- with the bound put back, and `./test.sh discriminate` requires it to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(19);

-- ================================ the fixture ================================
-- A [0, 200000) monolith: 1000 rows at the bottom and one at 199999, so it spans two 100000-steps and
-- carries the explicit _to_ name from the start (a one-step child carries the bare _p<lo> form and is
-- renamed on the first tick, which this file would then have to chase). Frontier at 350000: frozen.
create table public.rs (id bigint primary key, payload text);
insert into public.rs select g, 'x' from generate_series(1, 1000) g;
insert into public.rs values (199999, 'widen');
call pgpm.transmute('public.rs', 'id', 100000);
select pgpm.obtain('public.rs');
insert into public.rs values (350000, 'frontier');

select child_name as mono from pgpm.part
  where parent_table = 'public.rs'::regclass and attached order by lo::numeric limit 1 \gset
select is(:'mono'::text, 'rs_p0000000000000000000_to_0000000000000200000'::text,
  'GUARD: the monolith is [0, 200000), ten sub-ranges of 20000, as this file assumes');

-- Drive the copy to the swap's doorstep: tick until the cursor reaches hi. The literal child name is
-- used inside the DO block because psql does not interpolate :'mono' within a dollar-quoted body; the
-- GUARD above is what makes the literal safe.
do $$
declare s text; n int := 0; v_cur text;
begin
  loop
    select regrain_cursor into v_cur from pgpm.config where parent_table = 'public.rs'::regclass;
    exit when v_cur is not null and v_cur::numeric >= 200000;
    s := pgpm.regrain_step('public.rs', 'rs_p0000000000000000000_to_0000000000000200000', '20000', 1000);
    n := n + 1;
    if n > 100 then raise exception 'regrain setup did not converge (last status: %)', s; end if;
  end loop;
end $$;

select is((select regrain_cursor from pgpm.config where parent_table = 'public.rs'::regclass), '200000',
  'GUARD: the cursor is at hi, so the next tick is the swap');
select is(pgpm._regrain_delta_count('public.rs'), 0::bigint,
  'GUARD: the delta is empty going in, so everything reconciled below arrived during the swap''s wait');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.rs'::regclass and action = 'regrain_reconcile'), 0,
  'GUARD: no reconcile pass has run yet, so every pass counted below belongs to the swap');

-- ================================ the writer ================================
-- One DO block is one transaction: the sentinel's ROW EXCLUSIVE is held from its INSERT to the block's
-- end, and every late change commits together with the observation that the swap was already waiting.
create table public.rs_witness (waiters int, seen_at timestamptz);

select dblink_connect('writer', 'dbname=' || current_database());
select dblink_send_query('writer', $w$
do $b$
declare v_waiters int := 0;
begin
  -- the write whose lock the swap must wait for; captured, and held open until this block ends
  insert into public.rs values (40000, 'sentinel');
  -- Wait for the swap to request its ACCESS EXCLUSIVE and be refused it. Bounded, so a swap that never
  -- comes fails this file on its witness instead of hanging it. The DETACH names the parent first, so
  -- the ungranted request shows against public.rs; the source is included in case that order changes.
  for i in 1 .. 1200 loop
    select count(*) into v_waiters from pg_locks
     where relation in ('public.rs'::regclass,
                        'public.rs_p0000000000000000000_to_0000000000000200000'::regclass)
       and mode = 'AccessExclusiveLock' and not granted;
    exit when v_waiters > 0;
    perform pg_sleep(0.05);
  end loop;
  insert into public.rs_witness values (v_waiters, clock_timestamp());
  -- The late changes, all landing while the swap waits: 120,000 inserts, then one DELETE of a row the
  -- copy already holds, LAST, so it sits at the highest pgpm_seq: the first casualty of a bounded drain.
  insert into public.rs select g, 'late' from generate_series(50001, 170000) g;
  delete from public.rs where id = 500;
end $b$
$w$);

-- The swap tick must not start before the writer is in place: wait for its granted ROW EXCLUSIVE.
do $$
begin
  for i in 1 .. 600 loop
    exit when exists (select 1 from pg_locks
                       where relation = 'public.rs'::regclass and mode = 'RowExclusiveLock'
                         and granted and pid <> pg_backend_pid());
    perform pg_sleep(0.05);
  end loop;
end $$;
select ok(exists (select 1 from pg_locks
                   where relation = 'public.rs'::regclass and mode = 'RowExclusiveLock'
                     and granted and pid <> pg_backend_pid()),
  'LIVENESS: the writer holds ROW EXCLUSIVE on the parent before the swap tick starts');

-- ================================ the swap ================================
-- No lock_timeout here: this is the operator-driven path the issue names, which waits for the DETACH.
select is(pgpm.regrain_step('public.rs', :'mono', '20000', 1000), 'swapped:10',
  'the swap tick completes once the writer commits');

-- Collect the writer. An error in it (a wait that gave up, a failed insert) surfaces here as an error.
select is((select count(*)::int from dblink_get_result('writer') as t(status text)), 1,
  'the writer session ran to completion');
select dblink_disconnect('writer');

-- ================================ the witnesses ================================
select is((select count(*)::int from public.rs_witness), 1,
  'WITNESS: the writer recorded exactly one observation');
select cmp_ok((select waiters from public.rs_witness), '>=', 1,
  'WITNESS: the writer saw the swap''s ungranted ACCESS EXCLUSIVE before it wrote, so its 120,002 captured changes landed while the swap waited on the DETACH');
select cmp_ok((select count(*) from pgpm.log
                where parent_table = 'public.rs'::regclass and action = 'regrain_reconcile'), '>', 100::bigint,
  'LIVENESS: the residual reconcile needed more than 100 passes, so a 100-pass bound would have bitten here');
select is((select sum(rows)::bigint from pgpm.log
            where parent_table = 'public.rs'::regclass and action = 'regrain_reconcile'), 120002::bigint,
  'LIVENESS: the passes consumed exactly the 120,002 captured keys (sentinel + 120,000 inserts + 1 delete)');

-- ================================ identity, not cardinality ================================
select is((select count(*)::int from generate_series(50001, 170000) g
            where not exists (select 1 from public.rs r where r.id = g)), 0,
  'every one of the 120,000 late inserts is present through the parent');
select is((select payload from public.rs where id = 170000), 'late',
  'the last late insert, the highest-captured key but one, is present');
select is((select payload from public.rs where id = 40000), 'sentinel',
  'the sentinel row that held the lock is present');
select ok(not exists (select 1 from public.rs where id = 500),
  'the late DELETE is honoured: id 500 is gone, not resurrected from the copy made before it');
select is((select count(*)::int from generate_series(1, 1000) g
            where g <> 500 and not exists (select 1 from public.rs r where r.id = g)), 0,
  'and every other original row (1..1000 less 500) is present');

-- ================================ the swap finished cleanly ================================
select is(to_regclass('public.rs_p0000000000000000000_to_0000000000000200000'), null::regclass,
  'the source is dropped');
select is(pgpm._regrain_delta_count('public.rs'), 0::bigint, 'the delta is cleared after the swap');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.rs'::regclass and action = 'regrain' and method = 'copy_swap_drop'), 1,
  'the swap logged its completion');

select * from finish();

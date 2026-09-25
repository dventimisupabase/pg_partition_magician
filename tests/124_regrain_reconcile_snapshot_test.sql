-- _regrain_reconcile consumes from the delta exactly the captured rows its apply statements saw (#497).
--
-- THE DEFECT. A reconcile tick read its batch watermark, its list of touched fine children, each
-- child's delete/reinsert and its final `delete from delta where pgpm_seq <= wm` as SEPARATE statements,
-- and under READ COMMITTED each statement takes its own snapshot. pgpm_seq is an identity column, so a
-- writer's captured change takes its sequence value the moment the trigger fires, inside the writer's
-- still-open transaction. A writer whose capture took a pgpm_seq BELOW the watermark but was still
-- uncommitted while the apply statements ran, and committed before the final delete, had its delta rows
-- deleted without ever being applied: the apply statements could not see them, the final delete could.
-- The fine child kept the pre-change row and the swap attached it. A committed UPDATE silently reverted.
--
-- THE FIX. The batch is materialised ONCE, as the pgpm_seq values of the eligible rows visible in a
-- single snapshot, and every later statement in the tick, the final delete included, addresses the
-- delta by that set. A capture the apply statements did not see is neither applied nor consumed; it
-- stays in the delta for the next tick, which is the tick that applies it.
--
-- THE PROBE. Three sessions, ordered by lock state rather than by sleeps. T1 (dblink) updates an
-- already-copied row and holds its transaction open, so its capture holds the LOWEST pgpm_seq of
-- anything the tick will see. This session then commits a bulk update in a later sub-range, which is
-- what the tick's batch is made of. The tick runs in its own dblink session; this session waits until
-- the tick holds its lock on the fine child it is reconciling into (it is inside the apply loop, whose
-- 100,000-key delete and reinsert last far longer than a commit), and only then commits T1. The tick's
-- final delete therefore runs in a snapshot that includes T1's committed capture, whose pgpm_seq is
-- below the batch's watermark: exactly the row the old code consumed unapplied.
--
-- Every negative below ("the UPDATE is not reverted") is paired with a witness that the condition it
-- denies was present: the tick was observed inside its apply loop when T1 committed, T1's capture was
-- in the delta with a pgpm_seq below the batch's highest, and the tick was a reconcile tick that consumed
-- the bulk batch and nothing else. Assertions are by identity: which row holds which payload, with an
-- untouched neighbour and the bulk range as controls, so a lost update and a stray reinsert cannot
-- cancel. bench/regrain_reconcile_snapshot.sh drives this file against a mutant whose final delete
-- consumes by watermark again, and `./test.sh discriminate` requires it to FAIL there.
\pset format unaligned
\pset tuples_only on
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(15);

-- ================================ the fixture ================================
-- A [0, 2000000) monolith of 300,000 rows, regrained on a 100,000 step: three fine children to copy.
-- Frontier at 3500000: frozen.
create table public.rc (id bigint primary key, payload text);
insert into public.rc select g, 'orig' from generate_series(1, 300000) g;
insert into public.rc values (1999999, 'widen');
call pgpm.transmute('public.rc', 'id', 1000000);
select pgpm.obtain('public.rc');
insert into public.rc values (3500000, 'frontier');
select child_name as mono from pgpm.part
  where parent_table = 'public.rc'::regclass and attached order by lo::numeric limit 1 \gset
select is(:'mono'::text, 'rc_p0000000000000000000_to_0000000000002000000',
  'GUARD: the monolith is [0, 2000000), as the literal child names below assume');

-- copy sub-ranges [0,100000), [100000,200000), [200000,300000): the cursor ends at 300000
do $$
declare s text; n int := 0; v_cur text;
begin
  loop
    select regrain_cursor into v_cur from pgpm.config where parent_table = 'public.rc'::regclass;
    exit when v_cur is not null and v_cur::numeric >= 300000;
    s := pgpm.regrain_step('public.rc', 'rc_p0000000000000000000_to_0000000000002000000', '100000', 1000000);
    n := n + 1;
    if n > 20 then raise exception 'regrain setup did not converge (last status: %)', s; end if;
  end loop;
end $$;
select is((select payload from public.rc_p0000000000000100000 where id = 150000), 'orig',
  'GUARD: id 150000 is already copied into its fine child, so a change to it is reconciled, not copied');
select is(pgpm._regrain_delta_count('public.rc'), 0::bigint,
  'GUARD: the delta is empty going in, so every captured row below is one this file wrote');

-- ================================ the writer T1 ================================
-- An UPDATE of an already-copied row, captured at the lowest pgpm_seq the tick will see, held open.
select dblink_connect('t1', 'dbname=' || current_database());
select dblink_exec('t1', 'begin');
select dblink_exec('t1', $$update public.rc set payload = 't1' where id = 150000$$);

-- the tick's batch: an ordinary committed bulk update in another sub-range, captured AFTER T1's change
update public.rc set payload = 'bulk' where id between 200000 and 299999;
select is(pgpm._regrain_delta_count('public.rc'), 200000::bigint,
  'LIVENESS: the bulk update is captured (old + new per row); T1''s capture is still uncommitted and invisible');

-- ================================ the tick ================================
select dblink_connect('r', 'dbname=' || current_database());
select pid as rpid from dblink('r', 'select pg_backend_pid()') as t(pid int) \gset
select set_config('t124.rpid', :'rpid', false);
select dblink_send_query('r',
  $$select pgpm.regrain_step('public.rc', 'rc_p0000000000000000000_to_0000000000002000000', '100000', 1000000)$$);

-- Wait until the tick is inside the reconcile's per-child apply: it holds ROW EXCLUSIVE on the fine child
-- of the bulk sub-range. Bounded, so a tick that never gets there fails this file on its witness below
-- instead of hanging it. Each probe is its own statement, so this session pins no snapshot or lock.
do $$
begin
  for i in 1 .. 12000 loop
    exit when exists (select 1 from pg_locks
                       where pid = current_setting('t124.rpid')::int
                         and relation = 'public.rc_p0000000000000200000'::regclass and granted);
    perform pg_sleep(0.005);
  end loop;
end $$;
select ok(exists (select 1 from pg_locks
                   where pid = :rpid and relation = 'public.rc_p0000000000000200000'::regclass and granted),
  'LIVENESS: the tick is inside its apply loop (it holds the bulk sub-range''s fine child) when T1 commits');

-- T1 commits now: its capture becomes visible to the tick's LATER statements, with a pgpm_seq below the
-- watermark the tick's batch was chosen by.
select dblink_exec('t1', 'commit');
select ok(exists (select 1 from public.rc_pgpm_regrain_delta where id = 150000),
  'LIVENESS: T1''s capture is committed and in the delta while the tick is still applying');
select cmp_ok((select min(pgpm_seq) from public.rc_pgpm_regrain_delta where id = 150000), '<',
              (select max(pgpm_seq) from public.rc_pgpm_regrain_delta where id between 200000 and 299999),
  'LIVENESS: T1''s capture sits BELOW the highest pgpm_seq of the bulk batch, so a watermark delete would take it');

-- collect the tick
select matches(status, '^reconciled:', 'the tick is a reconcile tick')
  from dblink_get_result('r') as t(status text);
select dblink_get_result('r');
select dblink_disconnect('r');
select dblink_disconnect('t1');

-- ================================ what the tick consumed ================================
select is((select rows from pgpm.log where parent_table = 'public.rc'::regclass
            and action = 'regrain_reconcile' order by id desc limit 1), 200000::bigint,
  'the tick consumed exactly the 200,000 rows of the bulk batch (old + new per updated row), and not T1''s two');
select ok(exists (select 1 from public.rc_pgpm_regrain_delta where id = 150000),
  'T1''s capture, which the tick''s apply statements never saw, is still in the delta for the next tick');

-- ================================ drive to the swap ================================
do $$
declare s text; n int := 0;
begin
  loop
    s := pgpm.regrain_step('public.rc', 'rc_p0000000000000000000_to_0000000000002000000', '100000', 1000000);
    exit when s like 'swapped:%';
    n := n + 1;
    if n > 50 then raise exception 'regrain did not swap (last status: %)', s; end if;
  end loop;
end $$;
select is(to_regclass('public.rc_p0000000000000000000_to_0000000000002000000'), null::regclass,
  'the swap ran: the source is dropped');

-- ================================ identity, not cardinality ================================
select is((select payload from public.rc where id = 250000), 'bulk',
  'the bulk update (reconciled by the observed tick) is honoured through the swap');
select is((select payload from public.rc where id = 150001), 'orig',
  'an untouched neighbour of id 150000 is unchanged');
select is((select payload from public.rc where id = 150000), 't1',
  'T1''s committed UPDATE of id 150000 is honoured through the swap: not reverted to the copy made before it');
select is(pgpm._regrain_delta_count('public.rc'), 0::bigint, 'the delta is cleared after the swap');

select * from finish();

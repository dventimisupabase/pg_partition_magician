-- Archive coverage survives a lifted write block (issue #452).
--
-- pgpm.archive_ledger is a watermark: _next_archive_chunk resumes from max(hi), and
-- _archive_fully_covered is true once that watermark reaches the child's own hi. The watermark is only
-- a true statement about the partition's contents because the write-block trigger has been on the
-- partition since the first chunk was recorded: nothing can have been written into, or deleted out of,
-- a covered range. _enforce_write_blocks used to lift the block whenever eligibility regressed, which
-- for an `id` table happens when the newest rows are deleted (the frontier is max(control)), and for
-- any table when set_retain loosens the horizon. Lifted, the partition took writes into ranges the
-- ledger already called done; re-blocked, archiving resumed from the watermark; and retire() dropped
-- the partition with those rows in it and no strategy ever having seen them.
--
-- The rule now: a block is not lifted from a child the ledger covers, and the first tick that keeps a
-- block it would otherwise have lifted logs skip_write_block_lift for that child, once. The
-- documented way to make such a partition writable again is to discard its coverage (delete its
-- pgpm.archive_ledger rows); the next tick lifts the block, and archiving starts over from lo if the
-- partition is ever blocked again. The backstop for coverage the tick finds WITHOUT its block (a
-- trigger removed by hand, or lifted by a pgpm older than this rule before an upgrade) is to discard
-- it, logged as archive_coverage_reset, for the same reason: it cannot be vouched for.
--
-- The invariant every case pins, by identity rather than count: the set of rows in the partition when
-- it drops is exactly the set of rows the strategy was handed. The strategy here RECORDS what it is
-- handed, so that is a question about which ids, not how many.
create extension if not exists pgtap;

select plan(45);

create schema pgpm_test114;

-- Every row the strategy is handed lands here, keeping its payload, so a row handed twice (once per
-- archiving pass) shows up as two copies and a row never handed shows up as absent.
create table pgpm_test114.handed (parent regclass, id bigint, payload text);
create function pgpm_test114.recorder(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_rows bigint; v_result pgpm.archive_result;
begin
  execute format('insert into pgpm_test114.handed (parent, id, payload) select %s::regclass, id, payload from public.%I where id >= %L and id < %L',
                 p_parent::oid, p_child, p_lo, p_hi);
  get diagnostics v_rows = row_count;
  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  return v_result;
end;
$$;

-- ======================= case A: the `id` frontier moves back (newest rows deleted) =======================
-- 399 rows, ids 1..400 with 5 left out: 5 is the hole the late write will aim at, inside the range the
-- first chunk covers. With step 500 the monolith is [0,500); the frontier row 700 puts the horizon at
-- grid_floor(700 - 200) = 500, so the monolith is eligible and gets blocked and archived.
create table public.cl114a (id bigint primary key, payload text);
insert into public.cl114a select g, repeat('x', 100) from generate_series(1, 400) g where g <> 5;
call pgpm.transmute('public.cl114a', 'id', 500, p_retain => 200, p_paused => false, p_obtain => 2);
select pgpm.obtain('public.cl114a');
insert into public.cl114a values (700, 'frontier');
update pgpm.config set retain_batch = 0, archive_byte_budget = 2000,
       archive_fn = 'pgpm_test114.recorder(regclass,name,text,text)'::regprocedure
 where parent_table = 'public.cl114a'::regclass;
select child_name as mono_a from pgpm.part where parent_table = 'public.cl114a'::regclass and lo = '0' \gset

call pgpm.maintain('public.cl114a');
call pgpm.maintain('public.cl114a');
call pgpm.maintain('public.cl114a');

select ok(pgpm._is_write_blocked('public.cl114a', :'mono_a'),
  'LIVENESS A: the monolith is write-blocked after crossing the horizon');
select is((select count(*)::int from pgpm.archive_ledger
            where parent_table = 'public.cl114a'::regclass and child_name = :'mono_a'),
  3, 'LIVENESS A: three ticks recorded three chunks (one per tick at the default archive_batch)');
select ok(not pgpm._archive_fully_covered('public.cl114a', :'mono_a'),
  'LIVENESS A: coverage is still partial, so the partition is in the mid-archive state the defect needs');
select cmp_ok((select max(hi::numeric) from pgpm.archive_ledger
                where parent_table = 'public.cl114a'::regclass and child_name = :'mono_a'),
  '>', 5::numeric,
  'LIVENESS A: the covered range already reaches past id 5, so a late write of id 5 lands in a range the ledger calls done');
select results_eq(
  $$ select id from pgpm_test114.handed where parent = 'public.cl114a'::regclass and id <= 6 order by id $$,
  $$ values (1::bigint), (2), (3), (4), (6) $$,
  'LIVENESS A: ids 1,2,3,4,6 were handed to the strategy and 5 was not, because 5 does not exist yet');

-- THE REGRESSION. The newest row goes, so the frontier is max(id) = 400 and the horizon is
-- grid_floor(400 - 200) = 0: by the tick's own eligibility rule the monolith (hi 500) is no longer
-- eligible, and before this fix that lifted its block.
delete from public.cl114a where id = 700;
select ok(pgpm._native_gt('id', '500',
            (select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'public.cl114a'::regclass)),
  'LIVENESS A: the monolith''s hi is above the new horizon, so the lift condition is present');

call pgpm.maintain('public.cl114a');

select ok(exists (select 1 from pg_trigger where tgname = 'pgpm_write_block'
                   and tgrelid = format('public.%I', :'mono_a')::regclass),
  'the block STAYS on a partition the ledger covers although retention no longer reaches it');
select results_eq(
  $$ select action, lo, hi from pgpm.log
      where parent_table = 'public.cl114a'::regclass and action = 'skip_write_block_lift' $$,
  $$ values ('skip_write_block_lift'::text, '0'::text, '500'::text) $$,
  'and the tick says why, once, naming the partition''s own range');
select throws_like(
  $$ insert into public.cl114a values (5, 'LATE') $$,
  '%past its retention boundary%',
  'so the late write into the covered range is refused rather than landing behind the archive''s back');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.cl114a'::regclass and action = 'skip_write_block'),
  0, 'keeping the block is the rule, not a caught error: no skip_write_block row was written');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.cl114a'::regclass and action = 'archive_coverage_reset'),
  0, 'and the coverage was kept, not discarded');

call pgpm.maintain('public.cl114a');

select is((select count(*)::int from pgpm.log
            where parent_table = 'public.cl114a'::regclass and action = 'skip_write_block_lift'),
  1, 'a second tick in the same state does not log it again');
select is((select count(*)::int from pgpm.archive_ledger
            where parent_table = 'public.cl114a'::regclass and child_name = :'mono_a'),
  5, 'archiving carried on under the kept block: two more chunks in two more ticks');

-- The frontier moves on again, the monolith is eligible again, and retention is allowed to drop it.
-- Its contents are frozen by the block, so what is in it now is what the drop destroys.
insert into public.cl114a values (700, 'frontier');
create table pgpm_test114.at_drop_a as select id, payload from public.cl114a where id < 500;
update pgpm.config set retain_batch = null where parent_table = 'public.cl114a'::regclass;
do $$ declare i int := 0; v_status text; begin
  while i < 100 and exists (select 1 from pgpm.part where parent_table = 'public.cl114a'::regclass and lo = '0') loop
    call pgpm.maintain('public.cl114a', v_status);
    i := i + 1;
  end loop;
end $$;

select results_eq(
  $$ select action, lo, hi from pgpm.log where parent_table = 'public.cl114a'::regclass and action = 'retain_drop' $$,
  $$ values ('retain_drop'::text, '0'::text, '500'::text) $$,
  'the monolith was dropped by retention once coverage completed');
select is((select count(*)::int from (select id from pgpm_test114.at_drop_a
                                       except select id from pgpm_test114.handed where parent = 'public.cl114a'::regclass) s),
  0, 'IDENTITY A: every row in the partition when it dropped had been handed to the strategy');
select is((select count(*)::int from (select id from pgpm_test114.handed where parent = 'public.cl114a'::regclass
                                       except select id from pgpm_test114.at_drop_a) s),
  0, 'IDENTITY A: and the strategy was handed nothing that was not in the partition');
select is((select count(*)::int from pgpm_test114.at_drop_a), 399,
  'the partition held its 399 original rows and nothing else: the refused write is in neither the table nor the archive');

-- ============================ case B: set_retain loosens the horizon ============================
create table public.cl114b (id bigint primary key, payload text);
insert into public.cl114b select g, repeat('x', 100) from generate_series(1, 400) g where g <> 5;
call pgpm.transmute('public.cl114b', 'id', 500, p_retain => 200, p_paused => false, p_obtain => 2);
select pgpm.obtain('public.cl114b');
insert into public.cl114b values (700, 'frontier');
update pgpm.config set retain_batch = 0, archive_byte_budget = 2000,
       archive_fn = 'pgpm_test114.recorder(regclass,name,text,text)'::regprocedure
 where parent_table = 'public.cl114b'::regclass;
select child_name as mono_b from pgpm.part where parent_table = 'public.cl114b'::regclass and lo = '0' \gset

call pgpm.maintain('public.cl114b');
call pgpm.maintain('public.cl114b');
call pgpm.maintain('public.cl114b');

select ok(pgpm._is_write_blocked('public.cl114b', :'mono_b'),
  'LIVENESS B: the monolith is write-blocked');
select is((select count(*)::int from pgpm.archive_ledger
            where parent_table = 'public.cl114b'::regclass and child_name = :'mono_b'),
  3, 'LIVENESS B: with three chunks of partial coverage recorded');

-- Loosening is the documented always-safe direction: horizon = grid_floor(700 - 500) = 0.
select pgpm.set_retain('public.cl114b', '500');
select ok(pgpm._native_gt('id', '500',
            (select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'public.cl114b'::regclass)),
  'LIVENESS B: after loosening, the monolith''s hi is above the horizon: the lift condition is present');

call pgpm.maintain('public.cl114b');

select ok(pgpm._is_write_blocked('public.cl114b', :'mono_b'),
  'a loosened retain does not lift the block from a covered partition');
select results_eq(
  $$ select action, lo, hi from pgpm.log
      where parent_table = 'public.cl114b'::regclass and action = 'skip_write_block_lift' $$,
  $$ values ('skip_write_block_lift'::text, '0'::text, '500'::text) $$,
  'and logs the kept block once, against the partition''s range');
select throws_like(
  $$ insert into public.cl114b values (5, 'LATE') $$,
  '%past its retention boundary%',
  'a late write into the covered range is still refused');

-- THE DOCUMENTED WAY OUT. The operator discards the partition's coverage; the block has nothing left
-- to protect and the next tick lifts it.
delete from pgpm.archive_ledger where parent_table = 'public.cl114b'::regclass and child_name = :'mono_b';
call pgpm.maintain('public.cl114b');

select ok(not exists (select 1 from pg_trigger where tgname = 'pgpm_write_block'
                       and tgrelid = format('public.%I', :'mono_b')::regclass),
  'WITNESS B: with its coverage discarded, the block is lifted: pg_trigger holds no pgpm_write_block on the monolith');
select lives_ok($$ insert into public.cl114b values (5, 'LATE') $$,
  'WITNESS B: and the late write succeeds');
select is((select payload from public.cl114b where id = 5), 'LATE',
  'WITNESS B: it is in the table');

-- Retention reaches the monolith again. Set directly: set_retain refuses to re-arm a drop the loosened
-- value had disarmed, which is its own contract and not what this file is about.
update pgpm.config set retain = '200' where parent_table = 'public.cl114b'::regclass;
call pgpm.maintain('public.cl114b');

select ok(pgpm._is_write_blocked('public.cl114b', :'mono_b'),
  're-blocked once retention reaches it again');
select results_eq(
  format($$ select lo, count(*)::int from pgpm.archive_ledger
             where parent_table = 'public.cl114b'::regclass and child_name = %L group by lo $$, :'mono_b'),
  $$ values ('0'::text, 1) $$,
  'archiving started over from the partition''s lo, not from the discarded watermark');

create table pgpm_test114.at_drop_b as select id, payload from public.cl114b where id < 500;
update pgpm.config set retain_batch = null where parent_table = 'public.cl114b'::regclass;
do $$ declare i int := 0; v_status text; begin
  while i < 100 and exists (select 1 from pgpm.part where parent_table = 'public.cl114b'::regclass and lo = '0') loop
    call pgpm.maintain('public.cl114b', v_status);
    i := i + 1;
  end loop;
end $$;

select results_eq(
  $$ select action, lo, hi from pgpm.log where parent_table = 'public.cl114b'::regclass and action = 'retain_drop' $$,
  $$ values ('retain_drop'::text, '0'::text, '500'::text) $$,
  'the monolith was dropped once the second pass covered it');
select is((select count(*)::int from pgpm_test114.handed
            where parent = 'public.cl114b'::regclass and id = 5 and payload = 'LATE'),
  1, 'IDENTITY B: row 5, written while the block was lifted, was handed to the strategy before the drop');
select is((select count(*)::int from (select id from pgpm_test114.at_drop_b
                                       except select id from pgpm_test114.handed where parent = 'public.cl114b'::regclass) s),
  0, 'IDENTITY B: every row in the partition when it dropped had been handed to the strategy');
select is((select count(*)::int from (select id from pgpm_test114.handed where parent = 'public.cl114b'::regclass
                                       except select id from pgpm_test114.at_drop_b) s),
  0, 'IDENTITY B: and the strategy was handed nothing that was not in the partition');
select is((select count(*)::int from pgpm_test114.handed where parent = 'public.cl114b'::regclass and id = 1),
  2, 'row 1 was handed twice, once per pass: the second pass really did start from lo');

-- ==================== case C: coverage found without its block is discarded ====================
-- The state an install upgrading into this rule inherits when an older pgpm lifted a covered
-- partition's block, and the state a trigger removed by hand leaves. Modelled directly: drop the
-- trigger. Eligibility never changes here (the frontier row stays), so no lift is ever due and
-- skip_write_block_lift must not appear.
create table public.cl114c (id bigint primary key, payload text);
insert into public.cl114c select g, repeat('x', 100) from generate_series(1, 400) g where g <> 5;
call pgpm.transmute('public.cl114c', 'id', 500, p_retain => 200, p_paused => false, p_obtain => 2);
select pgpm.obtain('public.cl114c');
insert into public.cl114c values (700, 'frontier');
update pgpm.config set retain_batch = 0, archive_byte_budget = 2000,
       archive_fn = 'pgpm_test114.recorder(regclass,name,text,text)'::regprocedure
 where parent_table = 'public.cl114c'::regclass;
select child_name as mono_c from pgpm.part where parent_table = 'public.cl114c'::regclass and lo = '0' \gset

call pgpm.maintain('public.cl114c');
call pgpm.maintain('public.cl114c');
call pgpm.maintain('public.cl114c');

select ok(pgpm._is_write_blocked('public.cl114c', :'mono_c'),
  'LIVENESS C: the monolith is write-blocked');
select is((select count(*)::int from pgpm.archive_ledger
            where parent_table = 'public.cl114c'::regclass and child_name = :'mono_c'),
  3, 'LIVENESS C: with three chunks of partial coverage recorded');

select format('drop trigger pgpm_write_block on public.%I', :'mono_c') \gexec

select ok(not pgpm._is_write_blocked('public.cl114c', :'mono_c'),
  'WITNESS C: the block is gone while three chunks of coverage remain');
select lives_ok($$ insert into public.cl114c values (5, 'LATE') $$,
  'WITNESS C: and a late write into the covered range lands');

call pgpm.maintain('public.cl114c');

select results_eq(
  $$ select action, lo, hi, rows from pgpm.log
      where parent_table = 'public.cl114c'::regclass and action = 'archive_coverage_reset' $$,
  $$ values ('archive_coverage_reset'::text, '0'::text, '500'::text, 3::bigint) $$,
  'coverage found without its block is discarded, and the log says how many chunks went');
select ok(pgpm._is_write_blocked('public.cl114c', :'mono_c'),
  'the block is back on the still-eligible partition');
select results_eq(
  format($$ select lo, count(*)::int from pgpm.archive_ledger
             where parent_table = 'public.cl114c'::regclass and child_name = %L group by lo $$, :'mono_c'),
  $$ values ('0'::text, 1) $$,
  'the ledger holds only this tick''s first chunk, from lo: the three stale chunks are gone');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.cl114c'::regclass and action = 'skip_write_block_lift'),
  0, 'nothing was refused here: the partition stayed eligible throughout, so no lift was ever due');

create table pgpm_test114.at_drop_c as select id, payload from public.cl114c where id < 500;
update pgpm.config set retain_batch = null where parent_table = 'public.cl114c'::regclass;
do $$ declare i int := 0; v_status text; begin
  while i < 100 and exists (select 1 from pgpm.part where parent_table = 'public.cl114c'::regclass and lo = '0') loop
    call pgpm.maintain('public.cl114c', v_status);
    i := i + 1;
  end loop;
end $$;

select results_eq(
  $$ select action, lo, hi from pgpm.log where parent_table = 'public.cl114c'::regclass and action = 'retain_drop' $$,
  $$ values ('retain_drop'::text, '0'::text, '500'::text) $$,
  'the monolith was dropped once the fresh pass covered it');
select is((select count(*)::int from pgpm_test114.handed
            where parent = 'public.cl114c'::regclass and id = 5 and payload = 'LATE'),
  1, 'IDENTITY C: row 5, written while the block was absent, was handed to the strategy before the drop');
select is((select count(*)::int from (select id from pgpm_test114.at_drop_c
                                       except select id from pgpm_test114.handed where parent = 'public.cl114c'::regclass) s),
  0, 'IDENTITY C: every row in the partition when it dropped had been handed to the strategy');
select is((select count(*)::int from (select id from pgpm_test114.handed where parent = 'public.cl114c'::regclass
                                       except select id from pgpm_test114.at_drop_c) s),
  0, 'IDENTITY C: and the strategy was handed nothing that was not in the partition');

select * from finish();

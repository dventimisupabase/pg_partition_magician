-- The WRITE side of regrain's copy contract (issue #267).
--
-- tests/48_regrain_copy_contract_test.sql already pins the three properties the copy model was ADOPTED
-- for, and all three are read-side: a plain read of the parent never undercounts mid-regrain, the source
-- is never deleted from, and snapshot() does not double-count the in-flight copies. Nobody wrote the
-- other half, and there the copy model is simply wrong.
--
-- regrain_step's copy is resume-safe three ways -- a `>= max(dest.ctl)` high-water bound, a `not exists`
-- anti-join on the reused key, and a cursor that advances past a completed sub-range and never returns.
-- None of the three is a RECONCILE: the copy only ever ADDS rows and only ever moves FORWARD. The swap
-- then drops the source, so the copy becomes the authority for everything that changed after it ran.
--
-- The contract these tests assert, which any correct implementation must satisfy however it is built:
--   COMMITTED DML AGAINST THE SOURCE, MADE WHILE A REGRAIN IS IN FLIGHT, SURVIVES THE SWAP.
--
-- Each case drives regrain_step tick by tick, which is how maintain feathers it, and interleaves the DML
-- BETWEEN ticks. It deliberately does not use pgpm.regrain(): that driver loops in one transaction, so
-- nothing can interleave inside it and it would mask every defect here.
--
-- Fixtures are sparse (ids 10,20,...,2500) so there are free slots inside an already-copied sub-range,
-- and the monolith is COARSE ([0,3000), three grid steps) so #266 does not confound the result.
create extension if not exists pgtap;
begin;
select plan(10);

create or replace function pg_temp.mk(p_rel text) returns void language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_rel);
  execute format('insert into public.%I select g*10, ''x'' from generate_series(1, 250) g', p_rel);
  perform pgpm.transmute(format('public.%I', p_rel)::regclass, 'id', 1000);
  execute format('insert into public.%I values (900000, ''frontier'')', p_rel);   -- freeze the monolith
end $$;

-- drive regrain_step to the swap, one tick at a time
create or replace function pg_temp.finish_regrain(p_rel text, p_batch int) returns text language plpgsql as $$
declare s text; n int := 0;
begin
  loop
    s := pgpm.regrain_step(format('public.%I', p_rel)::regclass,
                           (p_rel || '_p0000000000000000000_to_0000000000000003000')::name, '100', p_batch);
    exit when s like 'swapped:%';
    n := n + 1;
    if n > 500 then raise exception 'regrain did not converge'; end if;
  end loop;
  return s;
end $$;

-- ============================ control: the happy path still works ============================
select pg_temp.mk('wc0');
select pgpm.regrain_step('public.wc0','wc0_p0000000000000000000_to_0000000000000003000','100',50);
select pg_temp.finish_regrain('wc0', 50);

select is((select count(*)::int from public.wc0), 251,
  'control: a feathered regrain with no concurrent DML is lossless');

select is(
  (select count(*)::int from pgpm.part p
    where p.parent_table = 'public.wc0'::regclass and p.attached
      and p.lo::numeric >= 0 and p.hi::numeric <= 3000),
  30, 'control: it produces all 30 fine children');

-- ============================ INSERT into a COMPLETED sub-range ============================
-- batch 50 finishes [0,100) (9 rows) on the first tick and advances the cursor, so the sub-range is
-- never revisited. A row inserted into it afterwards is copied by nothing.
select pg_temp.mk('wc1');
select pgpm.regrain_step('public.wc1','wc1_p0000000000000000000_to_0000000000000003000','100',50);
insert into public.wc1 values (55, 'inserted-into-completed-subrange');
select pg_temp.finish_regrain('wc1', 50);

select ok(
  exists(select 1 from public.wc1 where id = 55),
  'a committed INSERT into an already-copied sub-range survives the swap');

-- ============================ INSERT below the high-water mark ============================
-- batch 5 leaves [0,100) mid-copy with max(dest.id) = 50, so the copy's `s.id >= 50` bound excludes
-- anything inserted below it.
select pg_temp.mk('wc2');
select pgpm.regrain_step('public.wc2','wc2_p0000000000000000000_to_0000000000000003000','100',5);
insert into public.wc2 values (15, 'inserted-below-high-water');
select pg_temp.finish_regrain('wc2', 5);

select ok(
  exists(select 1 from public.wc2 where id = 15),
  'a committed INSERT below the destination''s high-water mark survives the swap');

-- ============================ DELETE ============================
select pg_temp.mk('wc3');
select pgpm.regrain_step('public.wc3','wc3_p0000000000000000000_to_0000000000000003000','100',50);
delete from public.wc3 where id = 50;
select pg_temp.finish_regrain('wc3', 50);

select ok(
  not exists(select 1 from public.wc3 where id = 50),
  'a committed DELETE stays deleted: the swap does not resurrect it');

-- ============================ UPDATE ============================
select pg_temp.mk('wc4');
select pgpm.regrain_step('public.wc4','wc4_p0000000000000000000_to_0000000000000003000','100',50);
update public.wc4 set payload = 'CORRECTED' where id = 60;
select pg_temp.finish_regrain('wc4', 50);

select is(
  (select payload from public.wc4 where id = 60), 'CORRECTED',
  'a committed UPDATE keeps its new value: the swap does not revert it');

-- ============================ all four interleaved ============================
-- Real workloads mix them, and the reconcile has to handle one key being touched more than once.
--
-- The inserts and the delete are deliberately ASYMMETRIC (two in, one out). A symmetric mix makes the
-- row count useless as an assertion: a lost INSERT and a resurrected DELETE cancel exactly, so count(*)
-- comes out right while both rows are wrong. That is the same shape of blind assertion that let this bug
-- live in tests/48 -- counts and read-side properties, never identity.
select pg_temp.mk('wc5');
select pgpm.regrain_step('public.wc5','wc5_p0000000000000000000_to_0000000000000003000','100',50);
insert into public.wc5 values (55, 'new'), (65, 'new');
delete from public.wc5 where id = 50;
update public.wc5 set payload = 'CORRECTED' where id = 60;
update public.wc5 set payload = 'TWICE' where id = 60;      -- same key touched twice
select pg_temp.finish_regrain('wc5', 50);

select is((select count(*)::int from public.wc5), 252,
  'mixed DML: row count is 252 = 250 + frontier + 2 inserts - 1 delete (asymmetric, so nothing cancels)');

select is((select count(*)::int from public.wc5 where id in (55, 65)), 2,
  'mixed DML: both committed INSERTs survive');

select ok(not exists(select 1 from public.wc5 where id = 50),
  'mixed DML: the committed DELETE stays deleted');

select is((select payload from public.wc5 where id = 60), 'TWICE',
  'mixed DML: a key touched twice ends on its LAST committed value');

select * from finish();
rollback;

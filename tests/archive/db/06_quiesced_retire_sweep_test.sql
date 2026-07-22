-- The regression this stack's unification work caught: a self_driving table's retire
-- sweep must run UNCONDITIONALLY every archive.tick() call, not only right after a fresh
-- range was archived. Otherwise a table that has QUIESCED (nothing new to archive, ever
-- again) could never retry a partition whose drop failed once for a reason unrelated to
-- archiving -- it would stay stuck forever, since no future tick() would ever touch it
-- again. Simulated the same way as the live verification behind this fix: a SECOND
-- pre_drop hook (alongside archive.file_gate) that deliberately fails exactly one
-- partition's drop, standing in for an external, archiving-unrelated failure.
select plan(7);

create schema if not exists archive_test;
create function archive_test.fail_one(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
begin
  if p_lo = '60000' then
    raise exception 'simulated external drop failure for %', p_child;
  end if;
end;
$$;

select mk_archive_table('a6', 50000, 10000, 30000);   -- monolith [0, 60000), premakes 4 ahead
insert into public.a6 (id, payload) select g, 'y' from generate_series(60001, 60005) g;
insert into public.a6 (id, payload) select g, 'z' from generate_series(70001, 70005) g;
insert into public.a6 (id, payload) values (110000, 'frontier');

select pgpm.hook_register('public.a6', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select pgpm.hook_register('public.a6', 'pre_drop', 'archive_test.fail_one(regclass,name,text,text)');
-- boundary_rule = byte_budget with a generous byte_budget: the whole eligible span
-- [0, 80000) (same boundary math as 01/02/05) fits in a single chunk, so the archiving
-- side of this test is not what is under test here -- the retire sweep is.
select mk_archive_config('a6', 'byte_budget', 'self_driving', 'ndjson_single');

-- archive.tick() is a PROCEDURE that commits internally, so it must be a bare top-level
-- CALL (see 01's own note); its success is proven by the assertions below.
call archive.tick();

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a6'::regclass),
  1, 'the byte-budget rule archived [0,80000) as one chunk (well within the default byte_budget)');

-- archive.file_gate's own overlap-recount bookkeeping (defense in depth) touches this
-- SAME wide ledger row on every retire attempt within its range, decrementing it by
-- each dropped partition's own share -- so by the time 2 of the 3 covered partitions
-- have actually dropped, rows_archived has already netted down from 50010 to just the
-- 5 rows still live in the one partition stuck behind the failing hook.
select is(
  (select rows_archived from archive.ledger where parent_table = 'public.a6'::regclass and lo = '0'),
  5::bigint, 'rows_archived nets down to the 5 rows still live in the un-dropped partition');

select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.a6'::regclass and lo = '60000' and attached),
  1, 'the partition whose drop hook raised stays attached -- per-partition isolation, not a whole-sweep abort');

select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.a6'::regclass and lo in ('0', '70000') and attached),
  0, 'the other two covered partitions dropped despite the third one''s failure');

-- the outage is over: fail_one no longer raises for lo = 60000.
create or replace function archive_test.fail_one(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
begin
end;
$$;

call archive.tick();   -- nothing new to archive; the retire sweep runs unconditionally regardless

select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.a6'::regclass and lo = '60000' and attached),
  0, 'the previously-stuck partition is retried and dropped, even though nothing new was archived this tick');

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a6'::regclass),
  1, 'no new archiving happened on the second tick -- this was purely a retire-sweep retry');

select is(
  (select rows_archived from archive.ledger where parent_table = 'public.a6'::regclass and lo = '0'),
  0::bigint, 'once the retry succeeds, rows_archived nets down to zero -- nothing live remains in the archived range');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

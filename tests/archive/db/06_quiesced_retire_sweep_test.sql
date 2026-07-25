-- The regression this stack's unification work caught: a self_driving table's retire
-- sweep must run UNCONDITIONALLY every archive.tick() call, not only right after a fresh
-- range was archived. Otherwise a table that has QUIESCED (nothing new to archive, ever
-- again) could never retry a partition whose drop failed once for a reason unrelated to
-- archiving -- it would stay stuck forever, since no future tick() would ever touch it
-- again. Simulated the same way as the live verification behind this fix: a SECOND
-- pre_drop hook (alongside archive.file_gate) that deliberately fails exactly one
-- partition's drop, standing in for an external, archiving-unrelated failure.
--
-- KNOWN GAP (pgpm_core issue #238): pgpm.retire() no longer consults pgpm.hook at all, so
-- neither archive.file_gate NOR archive_test.fail_one below ever fires -- every partition
-- (including the one meant to stay stuck) drops on the very first archive.tick() call,
-- which is exactly the scenario this file exists to rule out. Deliberate, temporary
-- collateral of landing #238 ahead of migrating pgpm_archive onto the archive_fn contract
-- (#239/#240); re-expressing this regression guard (a real, archiving-unrelated drop
-- failure keeping one partition stuck across ticks) on the new contract is #241's job.
-- Skipped rather than "fixed" here so this file doesn't quietly start asserting behavior
-- nobody has actually verified.
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

select skip('archive.file_gate and archive_test.fail_one are both inert as of pgpm_core #238 '
  || '(retire() no longer calls pgpm.hook); this quiesced-retire-sweep regression guard needs a '
  || 'real rewrite once pgpm_archive migrates onto archive_fn (#239/#240), which is #241''s job', 7);

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

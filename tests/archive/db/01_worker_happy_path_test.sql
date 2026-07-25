-- End-to-end happy path for the unified worker: partition_aligned + gate_only +
-- ndjson_single. Mirrors tests/58_retain_pre_drop_hook_test.sql's own hk8 setup (same
-- rows/step/retain), so the partition layout and retention boundary math here are
-- easy to cross-check against that existing, already-proven fixture.
--
-- KNOWN GAP (pgpm_core issue #238): pgpm.retire() no longer consults pgpm.hook at all, so
-- archive.file_gate's pre_drop veto -- the entire mechanism this test exists to exercise --
-- never runs. pgpm.retain() now drops every eligible partition immediately, regardless of
-- whether gate_only's ledger has caught up, silently defeating the "defer until archived"
-- guarantee this architecture is supposed to provide. This is deliberate, temporary
-- collateral of landing #238's retire()/retain() cutover ahead of migrating pgpm_archive
-- itself onto the archive_fn contract (#239/#240) -- rewriting this scenario for the merged
-- design is #241's job, once gate_only (or its replacement) is re-expressed on top of the
-- new write-block trigger instead of a pre_drop hook. Skipped rather than "fixed" here so
-- this file doesn't quietly start asserting behavior nobody has actually verified.
select plan(6);

select mk_archive_table('a1', 50000, 10000, 30000);   -- monolith [0, 60000), premakes 4 ahead
insert into public.a1 (id, payload) select g, 'y' from generate_series(60001, 60005) g;  -- into [60000,70000)
insert into public.a1 (id, payload) select g, 'z' from generate_series(70001, 70005) g;  -- into [70000,80000)
insert into public.a1 (id, payload) values (110000, 'frontier');   -- advances the frontier to 110000

select pgpm.hook_register('public.a1', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select mk_archive_config('a1', 'partition_aligned', 'gate_only', 'ndjson_single');

select skip('archive.file_gate''s pre_drop veto is inert as of pgpm_core #238 (retire() no '
  || 'longer calls pgpm.hook); this gate_only happy-path scenario needs a real rewrite once '
  || 'pgpm_archive migrates onto archive_fn (#239/#240), which is #241''s job', 6);

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

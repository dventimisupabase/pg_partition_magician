-- End-to-end happy path for the unified worker: partition_aligned + gate_only +
-- ndjson_single. Mirrors tests/58_retain_pre_drop_hook_test.sql's own hk8 setup (same
-- rows/step/retain), so the partition layout and retention boundary math here are
-- easy to cross-check against that existing, already-proven fixture.
select plan(6);

select mk_archive_table('a1', 50000, 10000, 30000);   -- monolith [0, 60000), premakes 4 ahead
insert into public.a1 (id, payload) select g, 'y' from generate_series(60001, 60005) g;  -- into [60000,70000)
insert into public.a1 (id, payload) select g, 'z' from generate_series(70001, 70005) g;  -- into [70000,80000)
insert into public.a1 (id, payload) values (110000, 'frontier');   -- advances the frontier to 110000

select pgpm.hook_register('public.a1', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select mk_archive_config('a1', 'partition_aligned', 'gate_only', 'ndjson_single');

-- boundary = grid_floor(110000 - 30000, 10000) = 80000: eligible = monolith [0,60000),
-- [60000,70000), [70000,80000) -- nothing archived yet, so the gate must defer all three.
select is(pgpm.retain('public.a1'), 0,
  'the gate defers every eligible drop before anything has been archived');

-- archive.tick() is a PROCEDURE that commits internally (between chunks of work), so it
-- must be a bare top-level CALL -- PL/pgSQL forbids issuing COMMIT unless the call chain
-- traces back to a top-level CALL, and wrapping it in any function (lives_ok included)
-- breaks that chain. Its success is proven by the assertions below, not by lives_ok.
call archive.tick();

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a1'::regclass),
  3, 'tick wrote one ledger row per eligible partition-aligned range');

select is(
  (select coalesce(sum(rows_archived), 0)::bigint from archive.ledger where parent_table = 'public.a1'::regclass),
  50010::bigint, 'rows_archived sums to the monolith (50000) plus the two live inserts (5 + 5)');

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a1'::regclass and child_name is null),
  0, 'a partition-aligned range always populates the ledger''s child_name convenience column');

select is(pgpm.retain('public.a1'), 3,
  'the gate now allows all 3 drops since the ledger fully covers them');

select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.a1'::regclass and attached and hi::bigint <= 80000),
  0, 'the 3 eligible partitions are gone after retain');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

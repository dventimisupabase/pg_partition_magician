-- drop_trigger = self_driving: archive.tick() alone -- no manual pgpm.retain() call --
-- both archives every eligible range AND retires the ones it just covered, in the same
-- call. Same layout/boundary math as 01 (mirrors tests/58_retain_pre_drop_hook_test.sql).
select plan(3);

select mk_archive_table('a2', 50000, 10000, 30000);   -- monolith [0, 60000), premakes 4 ahead
insert into public.a2 (id, payload) select g, 'y' from generate_series(60001, 60005) g;
insert into public.a2 (id, payload) select g, 'z' from generate_series(70001, 70005) g;
insert into public.a2 (id, payload) values (110000, 'frontier');

-- file_gate is registered as the defense-in-depth backstop, same as a real self_driving
-- deployment would (docs/archive-strategies-overview.md): the sweep below only ever
-- calls pgpm.retire() once the ledger already proves coverage, so it never actually fires.
select pgpm.hook_register('public.a2', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select mk_archive_config('a2', 'partition_aligned', 'self_driving', 'ndjson_single');

-- archive.tick() is a PROCEDURE that commits internally, so it must be a bare top-level
-- CALL (see 01's own note); its success is proven by the assertions below.
call archive.tick();

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a2'::regclass),
  3, 'tick archived all 3 eligible ranges');

select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.a2'::regclass and attached and hi::bigint <= 80000),
  0, 'the same tick() call already retired the 3 newly-archived partitions -- no manual retain() needed');

select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.a2'::regclass and action = 'retain_drop'),
  3, 'the drops went through the ordinary retire()/pgpm.log path, same as a manual retain() would log');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

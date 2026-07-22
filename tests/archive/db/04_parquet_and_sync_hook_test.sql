-- format = parquet, plus the module's OTHER, structurally separate architecture: the
-- synchronous archive.to_s3_parquet pre_drop hook, which archives a partition INLINE
-- inside retain()'s own drop transaction (no ledger, no gate, no archive.config.
-- boundary_rule/drop_trigger involvement -- just the connection settings).
select plan(7);

-- --- Part A: the paced worker, dispatched to the parquet encode/upload step -------------

select mk_archive_table('a4', 5000, 1000, 3000);   -- monolith [0, 6000), premakes 4 ahead
insert into public.a4 (id, payload) select g, 'y' from generate_series(6001, 6005) g;   -- into [6000,7000)
insert into public.a4 (id, payload) select g, 'z' from generate_series(7001, 7005) g;   -- into [7000,8000)
insert into public.a4 (id, payload) values (11000, 'frontier');   -- advances the frontier to 11000

select pgpm.hook_register('public.a4', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select mk_archive_config('a4', 'partition_aligned', 'gate_only', 'parquet', false);

-- boundary = grid_floor(11000 - 3000, 1000) = 8000: eligible = monolith [0,6000),
-- [6000,7000), [7000,8000), same shape as 01/02 scaled down by 10.
-- archive.tick() is a PROCEDURE that commits internally, so it must be a bare top-level
-- CALL (see 01's own note); its success is proven by the assertions below.
call archive.tick();

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a4'::regclass),
  3, 'tick wrote one ledger row per eligible range');

select is(
  (select coalesce(sum(rows_archived), 0)::bigint from archive.ledger where parent_table = 'public.a4'::regclass),
  5010::bigint, 'rows_archived sums to the monolith (5000) plus the two live inserts (5 + 5)');

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a4'::regclass and s3_key like '%.parquet'),
  3, 'every uploaded object key carries the parquet extension -- proof format dispatch actually took effect');

select is(pgpm.retain('public.a4'), 3,
  'the gate allows all 3 drops since the ledger fully covers them');

-- --- Part B: the synchronous hook, independent of the paced worker entirely -------------

select mk_archive_table('a4b', 60, 10, 20);   -- monolith [0, 70), premakes 4 ahead
insert into public.a4b (id, payload) values (71, 'y');    -- into [70,80)
insert into public.a4b (id, payload) values (109, 'frontier');   -- advances the frontier to 109

select pgpm.hook_register('public.a4b', 'pre_drop', 'archive.to_s3_parquet(regclass,name,text,text)');
select mk_archive_config('a4b', 'partition_aligned', 'gate_only', 'parquet', false);

-- boundary = grid_floor(109 - 20, 10) = 80: eligible = monolith [0,70), [70,80).
select is(pgpm.retain('public.a4b'), 2,
  'the synchronous hook archives each eligible partition inline, inside retain()''s own drop transaction');

select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.a4b'::regclass and attached and hi::bigint <= 80),
  0, 'both eligible partitions actually dropped');

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a4b'::regclass),
  0, 'the synchronous architecture writes no ledger row -- structurally separate from the paced worker');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

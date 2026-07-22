-- archive.archive_partition's forward-only guard: archive.file_gate's fast path trusts the
-- ledger watermark to mean "everything below this is archived", which is only true if
-- coverage stays gap-free from wherever the ledger starts. Calling archive_partition out
-- of ascending-lo order must be refused (archive.tick()/run_all always call it in order;
-- this exercises what happens if an operator calls it manually, out of order, instead).
-- Same layout as 01 (mirrors tests/58_retain_pre_drop_hook_test.sql): eligible partitions
-- in lo order are the monolith [0,60000), then [60000,70000), then [70000,80000).
--
-- archive_partition is a PROCEDURE that commits internally once past the guard, so a
-- successful call must be a bare top-level CALL, not wrapped in lives_ok (see 01's own
-- note); and CALL's argument list cannot contain a subquery, so the child names below are
-- captured into psql variables with \gset first, then substituted in as literals.
select plan(5);

select mk_archive_table('a5', 50000, 10000, 30000);
insert into public.a5 (id, payload) select g, 'y' from generate_series(60001, 60005) g;
insert into public.a5 (id, payload) select g, 'z' from generate_series(70001, 70005) g;
insert into public.a5 (id, payload) values (110000, 'frontier');
select mk_archive_config('a5', 'partition_aligned', 'gate_only', 'ndjson_single');

select child_name as child_0     from pgpm.part where parent_table = 'public.a5'::regclass and lo = '0' \gset
select child_name as child_60000 from pgpm.part where parent_table = 'public.a5'::regclass and lo = '60000' \gset
select child_name as child_70000 from pgpm.part where parent_table = 'public.a5'::regclass and lo = '70000' \gset

select throws_like(
  format($$ call archive.archive_partition('public.a5', %L) $$, :'child_60000'),
  '%out of order%',
  'archiving [60000,70000) before the monolith [0,60000) is refused by the forward-only guard');

select throws_like(
  format($$ call archive.archive_partition('public.a5', %L) $$, :'child_70000'),
  '%out of order%',
  'archiving [70000,80000) before anything else is archived is refused the same way');

call archive.archive_partition('public.a5', :'child_0');

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a5'::regclass and lo = '0'),
  1, 'archiving the monolith first (the actual next-expected range) succeeds');

call archive.archive_partition('public.a5', :'child_60000');

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a5'::regclass),
  2, 'now that the watermark has advanced to 60000, archiving [60000,70000) is the correct next range');

-- re-archiving the ALREADY-ledgered monolith is exempt from the guard: it overwrites its
-- own row rather than extending the frontier, so order does not matter for it.
call archive.archive_partition('public.a5', :'child_0');

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a5'::regclass),
  2, 're-archiving lo=0 upserted its existing row rather than adding a third');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

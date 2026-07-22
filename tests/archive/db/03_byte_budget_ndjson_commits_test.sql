-- boundary_rule = byte_budget, format = ndjson_commits: unlike 01/02's partition-aligned
-- rule, this one carves the eligible span into byte-sized chunks that do not line up
-- with partition boundaries at all -- proven here by checking the ledger directly
-- (contiguous [0, 200) coverage, more than one row, no child_name on any of them).
select plan(6);

select mk_archive_table('a3', 300, 100, 100);   -- ids 1..300, step 100, retain 100
-- frontier = 300 (a grid boundary); frozen floor = grid_floor(300,100) = 300;
-- retention boundary = grid_floor(300 - 100, 100) = 200 -- the eligible span is [0, 200).
select mk_archive_config('a3', 'byte_budget', 'gate_only', 'ndjson_commits', false, 800, 8 * 1024 * 1024);

-- archive.tick() is a PROCEDURE that commits internally, so it must be a bare top-level
-- CALL (see 01's own note); its success is proven by the assertions below.
call archive.tick();

select cmp_ok(
  (select count(*)::int from archive.ledger where parent_table = 'public.a3'::regclass), '>', 1,
  'the byte-budget rule splits the eligible span into more than one ledger row');

-- ids start at 1 (identity), not 0, so the grid range [0,200) holds 199 real rows (1..199).
select is(
  (select coalesce(sum(rows_archived), 0)::bigint from archive.ledger where parent_table = 'public.a3'::regclass),
  199::bigint, 'rows_archived sums to exactly the eligible span (ids 1..199)');

select is(
  (select min(lo::bigint) from archive.ledger where parent_table = 'public.a3'::regclass), 0::bigint,
  'coverage starts at the table''s grid anchor');

select is(
  (select max(hi::bigint) from archive.ledger where parent_table = 'public.a3'::regclass), 200::bigint,
  'coverage ends exactly at the retention boundary, not a moment earlier or later');

select is(
  (select count(*)::int from (
     select lo::bigint as lo, lag(hi::bigint) over (order by lo::bigint) as prev_hi
       from archive.ledger where parent_table = 'public.a3'::regclass
   ) t where prev_hi is not null and prev_hi <> lo),
  0, 'the chunks are contiguous -- no gaps and no overlaps between consecutive ledger rows');

select is(
  (select count(*)::int from archive.ledger where parent_table = 'public.a3'::regclass and child_name is not null),
  0, 'unlike a partition-aligned range, a byte-budget chunk never populates child_name');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

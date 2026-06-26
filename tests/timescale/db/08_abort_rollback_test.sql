-- Failure and rollback (E). Up to the cutover nothing is irreversible: the copy only writes a separate
-- destination, so the source is untouched and the copy is droppable (E1). The cutover itself is one
-- transaction that commits whole or rolls back whole: if a step inside it fails, the source survives
-- intact (E2). Autocommit, disposable-db.
select plan(6);

-- E1: nothing irreversible before the cutover. Run only the copy phase, then prove the source is intact.
select mk_plain_hypertable('e1', 30, '1 day', '5 days');
call pgpm.from_hypertable_copy('e1', 'ts');
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'e1'),
  1, 'E1: the source is still a hypertable after the copy phase');
select is((select count(*)::int from e1), 30, 'E1: the source still has all its rows');
select ok(to_regclass('public.e1_pgpm_dest') is not null, 'E1: the destination copy is a separate table');
drop table e1_pgpm_dest;   -- abort before cutover: drop the copy, the source loses nothing
select is((select count(*)::int from e1), 30, 'E1: dropping the destination leaves the source intact');

-- E2: a failure inside the cutover transaction rolls back whole. A view on the source makes the cutover's
-- DROP TABLE (no CASCADE) fail mid-swap; the whole cutover transaction must roll back, leaving the source.
select mk_plain_hypertable('e2', 30, '1 day', '5 days');
create view e2_v as select * from e2;
call pgpm.from_hypertable_copy('e2', 'ts');
select throws_ok(
  $$ call pgpm.from_hypertable_cutover('e2', 'ts', interval '1 month') $$,
  NULL, NULL,
  'E2: the cutover fails when another object depends on the source');
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'e2'),
  1, 'E2: the source hypertable survives whole (the swap transaction rolled back)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

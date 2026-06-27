-- Disk-estimate pre-flight (A4). The online copy writes a full second table before cutover, so the
-- migration transiently needs roughly the source's current size in extra disk (reclaimed when the old
-- hypertable is dropped at cutover). preflight raises a NOTICE with that estimate; the estimate itself is a
-- callable helper (testable, and useful for sizing a volume ahead of time). Autocommit, disposable-db.
select plan(2);

select mk_plain_hypertable('hp_disk', 240, '1 day', '10 days');   -- populated, multiple chunks

select ok(
  pgpm.from_hypertable_disk_estimate('hp_disk') > 0,
  'the disk estimate is positive for a populated hypertable');
select is(
  pgpm.from_hypertable_disk_estimate('hp_disk'),
  (select coalesce(sum(pg_total_relation_size(format('%I.%I', chunk_schema, chunk_name)::regclass)), 0)::bigint
     from timescaledb_information.chunks
    where hypertable_schema = 'public' and hypertable_name = 'hp_disk'),
  'the estimate equals the total on-disk size of all chunks');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

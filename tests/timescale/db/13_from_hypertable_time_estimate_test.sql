-- Time estimate (A4 companion). from_hypertable_time_estimate gives a ROUGH online-copy ETA from the chunk
-- sizes and an assumed effective throughput; the cutover's index rebuild and an optional refine are extra.
-- It is a pure read-only function (no COMMIT), so it is transaction-safe, but it lives in db/ alongside the
-- disk-estimate test it mirrors. Autocommit, disposable-db.
select plan(3);

select mk_plain_hypertable('hp_t', 2000, '1 day', '20 days');

select ok(
  pgpm.from_hypertable_time_estimate('hp_t') > interval '0',
  'the time estimate is positive for a populated hypertable');

-- monotonic: a lower assumed throughput must give a longer estimate
select ok(
  pgpm.from_hypertable_time_estimate('hp_t', 1) > pgpm.from_hypertable_time_estimate('hp_t', 100),
  'a lower assumed throughput (MiB/s) yields a longer estimate');

-- the formula, at an explicit rate: estimate = bytes / (mibps * 1 MiB)
select is(
  pgpm.from_hypertable_time_estimate('hp_t', 10),
  make_interval(secs => (pgpm.from_hypertable_disk_estimate('hp_t') / (10 * 1048576.0))::double precision),
  'the estimate equals bytes / (mibps * 1 MiB) at an explicit throughput');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

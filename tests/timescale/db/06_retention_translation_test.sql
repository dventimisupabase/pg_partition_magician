-- Retention translation (C1). On Apache TimescaleDB there is no readable drop_chunks POLICY to inherit
-- (add_retention_policy is a TSL/Community feature, absent on the Apache fleet pgpm targets), so the
-- operator declares the data-lifecycle intent explicitly via p_retain -- exactly as transmute() takes it.
-- from_hypertable carries p_retain into pgpm's retain so the intent is not lost at migration. (When the
-- caller leaves p_retain null, from_hypertable still best-effort reads a policy if one exists, but on
-- Apache there is none.) Autocommit, disposable-db.
select plan(2);

select mk_keyed_hypertable('hp_ret', 240, '1 day', '10 days');   -- a keyed hypertable (no policy on Apache)

-- the operator supplies the retention window explicitly (the Apache-correct path)
call pgpm.from_hypertable('hp_ret', 'ts', interval '1 month', p_retain => interval '90 days', p_paused => false);

select is(
  (select retain::interval from pgpm.config where parent_table = 'hp_ret'::regclass),
  interval '90 days',
  'the operator-supplied retention (p_retain) was carried into pgpm retain');
select is(
  (select relkind::text from pg_class where oid = 'hp_ret'::regclass),
  'p', 'the table migrated to a partitioned table');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

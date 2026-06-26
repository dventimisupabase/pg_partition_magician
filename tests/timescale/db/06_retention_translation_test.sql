-- Retention translation (C1). A hypertable's drop_chunks policy is the operator's data-lifecycle intent;
-- it must not be silently lost on migration. When the caller does not pass p_retain, from_hypertable reads
-- the source's drop_chunks interval (timescaledb_information.jobs, proc_name='policy_retention',
-- config->>'drop_after') and carries it into pgpm's retain. Autocommit, disposable-db.
select plan(2);

select mk_hypertable_with_retention('hp_ret', interval '90 days');   -- keyed hypertable + 90-day policy

call pgpm.from_hypertable('hp_ret', 'ts', interval '1 month', p_paused => false);   -- p_retain left null

select is(
  (select retain::interval from pgpm.config where parent_table = 'hp_ret'::regclass),
  interval '90 days',
  'the 90-day drop_chunks policy was translated into pgpm retain');
select is(
  (select relkind::text from pg_class where oid = 'hp_ret'::regclass),
  'p', 'the table migrated to a partitioned table');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

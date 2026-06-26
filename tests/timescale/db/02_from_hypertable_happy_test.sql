-- Happy-path migration of a keyed hypertable, end to end. from_hypertable is a procedure that COMMITs
-- per chunk and at cutover, so it is called as a bare statement (not wrapped by lives_ok/throws_ok,
-- which use savepoints) and the result state is asserted afterwards. Autocommit, disposable-db.
select plan(6);

select mk_keyed_hypertable('hp_mig', 240, '1 day', '10 days');
create table hp_mig_snap as select * from hp_mig;     -- fidelity baseline

call pgpm.from_hypertable('hp_mig', 'ts', interval '1 month', p_paused => false);

-- handoff occurred: the original name now resolves to a pgpm-managed partitioned table
select is(
  (select relkind::text from pg_class where oid = 'hp_mig'::regclass),
  'p', 'the migrated table is a native partitioned table');
select is(
  (select count(*)::int from pgpm.config where parent_table = 'hp_mig'::regclass),
  1, 'it is registered in pgpm.config');

-- extraction fidelity: every row present, none altered or duplicated
select is((select count(*)::int from hp_mig), 240, 'row count preserved through the migration');
select ok(rows_equal('hp_mig', 'hp_mig_snap'), 'row fidelity: EXCEPT empty both directions');

-- the reused key survived (a unique constraint, since the source had no PK)
select is(
  (select count(*)::int from pg_constraint where conrelid = 'hp_mig'::regclass and contype = 'u'),
  1, 'the unique constraint survived the migration');

-- Timescale teardown: the hypertable catalog row is gone
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hp_mig'),
  0, 'no _timescaledb hypertable catalog row remains for the old name');

select * from finish();

drop table if exists hp_mig cascade;
drop table if exists hp_mig_snap cascade;

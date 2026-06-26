-- The headline case: migrate a KEYLESS hypertable (no PK, no unique constraint) end to end. This is the
-- common "Timescale as a partition manager" shape -- create_hypertable makes the time column NOT NULL but
-- adds no key -- so it must migrate. from_hypertable copies it out and transmute partitions it keyless,
-- synthesizing no key (faithful). Autocommit, disposable-db (the procedure COMMITs).
select plan(6);

select mk_plain_hypertable('hp_kl', 240, '1 day', '10 days');   -- keyless time hypertable
drop table if exists hp_kl_snap;
create table hp_kl_snap as select * from hp_kl;                  -- fidelity baseline

call pgpm.from_hypertable('hp_kl', 'ts', interval '1 month', p_paused => false);

select is(
  (select relkind::text from pg_class where oid = 'hp_kl'::regclass),
  'p', 'the keyless hypertable is now a native partitioned table');
select is(
  (select count(*)::int from pgpm.config where parent_table = 'hp_kl'::regclass),
  1, 'it is registered in pgpm.config');
select is((select count(*)::int from hp_kl), 240, 'row count preserved through the migration');
select ok(rows_equal('hp_kl', 'hp_kl_snap'), 'row fidelity: EXCEPT empty both directions');
select is(
  (select count(*)::int from pg_constraint where conrelid = 'hp_kl'::regclass and contype in ('p', 'u')),
  0, 'no key was synthesized (faithful to the keyless source)');
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hp_kl'),
  0, 'no _timescaledb hypertable catalog row remains for the old name');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

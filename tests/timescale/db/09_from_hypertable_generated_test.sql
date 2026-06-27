-- Generated columns survive a hypertable migration. CREATE TABLE (LIKE ... INCLUDING GENERATED) gives the
-- destination the generated column; the copy omits it from its INSERT list (it recomputes), so the
-- migration succeeds and the generated value is correct in the result. Autocommit, disposable-db.
select plan(3);

select mk_hypertable_generated('hp_gen', 30);

call pgpm.from_hypertable('hp_gen', 'ts', interval '1 month', p_paused => false);

select is(
  (select relkind::text from pg_class where oid = 'hp_gen'::regclass),
  'p', 'the generated-column hypertable migrated to a partitioned table');
select is((select count(*)::int from hp_gen), 30, 'all rows present');
select is(
  (select count(*)::int from hp_gen where cents = amount * 100),
  30, 'the generated column is correct on every migrated row');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

-- Exact identity-sequence preservation. transmute seeds the migrated table's identity sequence past
-- max(id), which is correct when the sequence sits right at its max. But a sequence can be AHEAD of max(id)
-- -- from rolled-back inserts, sequence caching, or deleted high rows -- and then seeding to max(id)+1 would
-- hand back out ids the source had already moved past. from_hypertable captures the source sequence's own
-- position and advances the migrated sequence to it, so the next generated id continues from where the
-- source left off, not from max(id)+1. Autocommit, disposable-db.
select plan(3);

select mk_hypertable_composite_pk('hp_seq', 100);   -- id identity 1..100, PK (id, ts); sequence last_value = 100

-- push the source sequence well past max(id) (a gap a naive max(id)+1 reseed would re-issue)
select setval(pg_get_serial_sequence('hp_seq', 'id'), 200);   -- is_called => next source value is 201

call pgpm.from_hypertable('hp_seq', 'ts', interval '1 day', p_paused => false);

select is(
  (select relkind::text from pg_class where oid = 'hp_seq'::regclass),
  'p', 'the table migrated to a native partitioned table');
select is(
  (select attidentity::text from pg_attribute where attrelid = 'hp_seq'::regclass and attname = 'id'),
  'd', 'id is still an identity column after migration');

-- a fresh insert that omits id must continue from the SOURCE sequence position (201), not max(id)+1 (101)
insert into hp_seq (ts, body) values (now() - interval '5 days', 'new');
select is(
  (select id from hp_seq where body = 'new'),
  201::bigint, 'the next id continues from the source sequence position, not max(id)+1');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

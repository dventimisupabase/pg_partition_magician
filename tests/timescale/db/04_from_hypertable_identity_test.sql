-- Identity/sequence continuity. A hypertable with a composite PK (id, ts) and an IDENTITY sequence on id
-- must keep that identity through the migration: CREATE TABLE (LIKE ...) does not carry identity, so
-- from_hypertable re-establishes it on the destination before the transmute handoff (which then reseeds
-- the sequence past the max existing id). After migration, an insert that omits id must succeed and get a
-- fresh, non-colliding value -- new writes continue unbroken. Autocommit, disposable-db (the procedure COMMITs).
select plan(4);

select mk_hypertable_composite_pk('hp_id', 100);

call pgpm.from_hypertable('hp_id', 'ts', interval '1 month', p_paused => false);

-- the identity property survived the migration
select is(
  (select count(*)::int from pg_attribute
    where attrelid = 'hp_id'::regclass and attname = 'id' and attidentity in ('a', 'd') and not attisdropped),
  1, 'id is still an identity column after migration');

-- a new row that omits id auto-generates one (fails outright if identity was lost), and the sequence was
-- reseeded past the existing max so it does not collide with a migrated row (a collision would be a PK error).
insert into hp_id (ts, body) values (now(), 'new');

select is((select count(*)::int from hp_id), 101, 'the new row inserted without an explicit id');
select is((select count(distinct id)::int from hp_id), 101, 'every id is distinct (the sequence did not collide)');
select cmp_ok(
  (select id from hp_id where body = 'new'), '>', 100::bigint,
  'the new id continues past the migrated maximum (no reuse of an existing value)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

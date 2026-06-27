-- Pre-flight refusals for from_hypertable. Tests pgpm.from_hypertable_preflight (a side-effect-free
-- function, so the refusals are savepoint-wrappable by throws_ok/lives_ok). Fixtures are loaded by the
-- harness before this file. Apache-only: pgpm targets Apache TimescaleDB, which has no continuous
-- aggregates (a TSL/Community feature), so a hypertable on the target fleet can never carry one and that
-- refusal is not exercised here. Runs in autocommit (disposable-db), like the rest of the db/ track.
select plan(3);

-- a keyed hypertable (UNIQUE on the control column) is accepted
select mk_keyed_hypertable('ph_ok');
select lives_ok(
  $$ select pgpm.from_hypertable_preflight('ph_ok', 'ts') $$,
  'preflight accepts a hypertable whose control column is in a unique constraint');

-- a keyless hypertable (no PK / unique constraint) is ALSO accepted: transmute partitions it keyless
-- (create_hypertable makes the time column NOT NULL, so the keyless contract is satisfied)
select mk_plain_hypertable('ph_keyless');
select lives_ok(
  $$ select pgpm.from_hypertable_preflight('ph_keyless', 'ts') $$,
  'preflight accepts a keyless hypertable (migrated keyless)');

-- a second (space) dimension is refused (pgpm is single-key RANGE)
select mk_hypertable_space('ph_space');
select throws_like(
  $$ select pgpm.from_hypertable_preflight('ph_space', 'ts') $$,
  'pg_partition_magician:%dimension%',
  'preflight refuses a multi-dimension (space-partitioned) hypertable');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

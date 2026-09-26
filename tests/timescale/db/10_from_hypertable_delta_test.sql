-- Trigger-based change capture (D2). Beyond append-only: with p_track_changes => true the copy installs an
-- AFTER INSERT/UPDATE/DELETE row trigger on the source, so UPDATEs and DELETEs to already-copied rows that
-- arrive during the online window are reconciled at cutover, not just late appends. Reconciliation is by the
-- reused key (PK or unique constraint), so it needs a key: a keyless table refuses tracking up front.
-- Autocommit, disposable-db.
select plan(9);

select mk_keyed_hypertable('hp_d2', 240, '1 day', '10 days');   -- UNIQUE (device_id, ts), device_id = g

-- PHASE 1: online bulk copy WITH change tracking. The source stays live.
call pgpm.from_hypertable_copy('hp_d2', 'ts', p_track_changes => true);

-- Regression for #170: the delta now carries a pgpm_seq ordering column, but a direct cutover WITHOUT any
-- online drain must still reconcile the whole (undrained) delta under the lock -- the under-lock pass is the
-- correctness backstop. (The cutover's default-on pre-drain finds the residual already below its threshold
-- here, so it does no online work; the assertions below confirm the under-lock reconcile is unaffected.)
select ok(
  exists(select 1 from information_schema.columns
          where table_name = 'hp_d2_pgpm_delta' and column_name = 'pgpm_seq'),
  'the delta carries the pgpm_seq ordering column (and the undrained cutover still reconciles correctly)');

-- writes that arrive DURING the online window, against ALREADY-COPIED rows. random()*100 is in [0,100), so
-- temp = -1 uniquely marks the updated rows; an append-only catch-up would miss all three change kinds.
update hp_d2 set temp = -1 where device_id <= 5;                 -- 5 UPDATEs to copied rows
delete from hp_d2 where device_id > 235;                        -- 5 DELETEs of copied rows (236..240)
insert into hp_d2 (ts, device_id, temp)                         -- 3 brand-new appends
  select now() + (g || ' hours')::interval, 1000 + g, 7 from generate_series(1, 3) g;

-- PHASE 2: cutover replays the delta against the live source, swaps, hands off.
call pgpm.from_hypertable_cutover('hp_d2', 'ts', interval '1 month', p_paused => false);

select is(
  (select relkind::text from pg_class where oid = 'hp_d2'::regclass),
  'p', 'the table migrated to a native partitioned table');
select is((select count(*)::int from hp_d2), 238, 'row count reflects the deletes and appends (240 - 5 + 3)');
select is(
  (select count(*)::int from hp_d2 where temp = -1),
  5, 'in-flight UPDATEs to already-copied rows were captured and reconciled');
select is(
  (select count(*)::int from hp_d2 where device_id between 236 and 240),
  0, 'in-flight DELETEs of already-copied rows were captured and reconciled');
select is(
  (select count(*)::int from hp_d2 where device_id >= 1000),
  3, 'in-flight appends were captured');
select ok(
  to_regclass('public.hp_d2_pgpm_delta') is null,
  'the change-capture delta table is cleaned up at cutover');
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hp_d2'),
  0, 'the hypertable was torn down');

-- change tracking needs a key to reconcile by: a keyless table refuses it up front (fail fast, not a silent
-- fallback to append-only that would lose updates/deletes).
select mk_plain_hypertable('hp_d2_keyless', 30, '1 day', '5 days');
-- Pinned to the refusal's own message (#522): a copy that did NOT refuse would commit per chunk and die
-- with 2D000 "invalid transaction termination" inside the wrapper, which the previous NULL, NULL accepted.
select throws_like(
  $$ call pgpm.from_hypertable_copy('hp_d2_keyless', 'ts', p_track_changes => true) $$,
  'pg_partition_magician: from_hypertable_copy(%, p_track_changes => true) needs a key to reconcile changes by%',
  'p_track_changes on a keyless table is refused (no key to reconcile by)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

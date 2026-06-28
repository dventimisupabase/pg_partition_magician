-- Online delta drain (issue #170). With p_track_changes, the in-flight insert/update/delete backlog can be
-- reconciled into the destination ONLINE, in bounded micro-batches, BEFORE the cutover takes its lock -- so
-- the locked window applies only a tiny residual instead of the whole online-copy backlog. This test proves
-- the changes land in the dest while the source is still a live hypertable (not just at cutover), that the
-- cutover still finishes any post-drain residual, that a threshold leaves a residual for the cutover, that a
-- single step reconciles a bounded batch, and that tracking is refused on a nullable key column.
-- Autocommit, disposable-db.
select plan(27);

-- =====================================================================================================
-- Main flow: copy with tracking, change rows, drain ONLINE, assert the dest converged before any cutover.
-- =====================================================================================================
select mk_keyed_hypertable('hp_drain', 240, '1 day', '10 days');   -- UNIQUE (device_id, ts), device_id = g
call pgpm.from_hypertable_copy('hp_drain', 'ts', p_track_changes => true);

select ok(
  exists(select 1 from information_schema.columns
          where table_name = 'hp_drain_pgpm_delta' and column_name = 'pgpm_seq'),
  'the delta carries a pgpm_seq ordering column for incremental draining');

-- in-flight writes against ALREADY-COPIED rows. random()*100 is in [0,100), so temp = -1 uniquely marks
-- the updated rows. device_id 7 -> 500 is a KEY-CHANGING update (the trigger logs OLD + NEW).
update hp_drain set temp = -1 where device_id <= 5;                 -- 5 UPDATEs
delete from hp_drain where device_id > 235;                         -- 5 DELETEs (236..240)
insert into hp_drain (ts, device_id, temp)                          -- 3 brand-new appends
  select now() + (g || ' hours')::interval, 1000 + g, 7 from generate_series(1, 3) g;
update hp_drain set device_id = 500 where device_id = 7;            -- 1 key-changing UPDATE

select cmp_ok((select count(*)::int from hp_drain_pgpm_delta), '>', 0,
  'the trigger logged the in-flight changes into the delta');

-- DRAIN ONLINE: the source is still a live hypertable, no lock is taken.
call pgpm.from_hypertable_drain_delta('hp_drain', 'ts');

select is((select count(*)::int from hp_drain_pgpm_delta), 0,
  'the online drain emptied the delta (drained to the default threshold 0)');

-- the DEST already reflects every change BEFORE any cutover -- the whole point of #170.
select is((select count(*)::int from hp_drain_pgpm_dest), 238,
  'dest row count reflects deletes + appends online (240 - 5 + 3), before cutover');
select is((select count(*)::int from hp_drain_pgpm_dest where temp = -1), 5,
  'in-flight UPDATEs were applied to the dest online');
select is((select count(*)::int from hp_drain_pgpm_dest where device_id between 236 and 240), 0,
  'in-flight DELETEs were applied to the dest online');
select is((select count(*)::int from hp_drain_pgpm_dest where device_id >= 1000), 3,
  'in-flight appends were applied to the dest online');
select is((select count(*)::int from hp_drain_pgpm_dest where device_id = 7), 0,
  'a key-changing UPDATE removed the OLD key from the dest online');
select is((select count(*)::int from hp_drain_pgpm_dest where device_id = 500), 1,
  'a key-changing UPDATE inserted the NEW key into the dest online');

-- MORE changes after the drain: the cutover (pre-drain + under-lock pass) must still catch these.
update hp_drain set temp = -2 where device_id = 6;                  -- 1 post-drain UPDATE
delete from hp_drain where device_id = 234;                        -- 1 post-drain DELETE

call pgpm.from_hypertable_cutover('hp_drain', 'ts', interval '1 month', p_paused => false);

select is((select relkind::text from pg_class where oid = 'hp_drain'::regclass), 'p',
  'the table migrated to a native partitioned table');
select is((select count(*)::int from hp_drain), 237,
  'final row count reflects all changes (238 - 1 post-drain delete)');
select is((select count(*)::int from hp_drain where temp = -2), 1,
  'a post-drain UPDATE was caught by the cutover');
select is((select count(*)::int from hp_drain where device_id = 234), 0,
  'a post-drain DELETE was caught by the cutover');
select is((select count(*)::int from hp_drain where device_id >= 1000), 3,
  'the appends survived the cutover');
select ok(to_regclass('public.hp_drain_pgpm_delta') is null,
  'the change-capture delta table is cleaned up at cutover');
select ok(to_regclass('public.hp_drain_pgpm_drainkey') is null,
  'no throwaway drain key index is created -- the copy-built reused-key index is used and adopted (#175)');
select ok(
  exists(select 1 from pg_constraint where conrelid = 'hp_drain'::regclass and contype = 'u'),
  'the reused unique key was adopted onto the migrated parent (from the copy-built index, #175)');
select ok(
  not exists(select 1 from information_schema.columns where table_name = 'hp_drain' and column_name = 'pgpm_seq'),
  'the final table carries no pgpm_seq column');

-- =====================================================================================================
-- A single step reconciles a bounded batch (the loop primitive, hand-drivable).
-- =====================================================================================================
select mk_keyed_hypertable('hp_step', 60, '1 day', '6 days');
call pgpm.from_hypertable_copy('hp_step', 'ts', p_track_changes => true);
update hp_step set temp = -1 where device_id <= 30;                 -- 30 dirty keys (60 delta rows: old + new)
select cmp_ok(pgpm.from_hypertable_drain_delta_step('hp_step', 'ts', 10)::int, '>', 0,
  'a single drain step reconciles a bounded batch (returns the keys it cleared)');
-- one bounded step processes its batch and stops: the rest of the backlog is left for later batches.
select cmp_ok((select count(*)::int from hp_step_pgpm_delta), '>', 0,
  'a single bounded step does not empty the delta (the rest remains for later batches)');

-- =====================================================================================================
-- A threshold stops the online drain early, leaving a residual the cutover finishes under the lock.
-- =====================================================================================================
select mk_keyed_hypertable('hp_thr', 60, '1 day', '6 days');
call pgpm.from_hypertable_copy('hp_thr', 'ts', p_track_changes => true);
update hp_thr set temp = -1 where device_id <= 30;                  -- 30 dirty keys
-- batch 7, threshold 5: 30 -> 23 -> 16 -> 9 -> 2 (stops with 2 <= 5 left)
call pgpm.from_hypertable_drain_delta('hp_thr', 'ts', p_batch => 7, p_threshold => 5);
select cmp_ok((select count(*)::int from hp_thr_pgpm_delta), '<=', 5,
  'draining with a threshold leaves at most the threshold residual');
select cmp_ok((select count(*)::int from hp_thr_pgpm_delta), '>', 0,
  'draining with a threshold stops before empty (a residual remains for the cutover)');
call pgpm.from_hypertable_cutover('hp_thr', 'ts', interval '1 month', p_paused => false);
select is((select count(*)::int from hp_thr where temp = -1), 30,
  'the cutover reconciled the threshold residual the online drain left behind');

-- =====================================================================================================
-- The cutover's AUTOMATIC pre-drain actually drains a backlog above its threshold (exercises the nested
-- cutover -> drain_delta -> step + per-batch COMMIT path), then the under-lock pass finishes the residual.
-- =====================================================================================================
select mk_keyed_hypertable('hp_auto', 60, '1 day', '6 days');
call pgpm.from_hypertable_copy('hp_auto', 'ts', p_track_changes => true);
update hp_auto set temp = -1 where device_id <= 30;                 -- 60 delta rows, well above a small batch
-- a direct cutover with a small batch: the pre-drain loops (committing per batch) down to the threshold,
-- then the brief lock finishes the rest. No manual from_hypertable_drain_delta call.
call pgpm.from_hypertable_cutover('hp_auto', 'ts', interval '1 month', p_drain_batch => 7, p_paused => false);
select is((select relkind::text from pg_class where oid = 'hp_auto'::regclass), 'p',
  'the cutover auto-pre-drain migrated the table');
select is((select count(*)::int from hp_auto where temp = -1), 30,
  'the cutover auto-pre-drain reconciled the whole backlog (online batches + under-lock residual)');
select ok(to_regclass('public.hp_auto_pgpm_drainkey') is null,
  'the cutover dropped the drain key index its own pre-drain built');

-- =====================================================================================================
-- Tracking is refused on a key with a nullable (non-control) column: a NULL key component can never be
-- reconciled (row-constructor IN never matches NULL), so refuse rather than silently lose the change.
-- =====================================================================================================
create table hp_null (ts timestamptz not null, device_id bigint, temp double precision,
                      constraint hp_null_key unique (device_id, ts));
select create_hypertable('hp_null', 'ts', chunk_time_interval => interval '1 day');
insert into hp_null (ts, device_id, temp)
  select now() - (g || ' hours')::interval, g, g from generate_series(1, 10) g;
select throws_ok(
  $$ call pgpm.from_hypertable_copy('hp_null', 'ts', p_track_changes => true) $$,
  NULL, NULL,
  'p_track_changes on a key with a nullable column is refused (a NULL key can never be reconciled)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

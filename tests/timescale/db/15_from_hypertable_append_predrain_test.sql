-- Append-only online pre-drain (issue #174). Without p_track_changes, the cutover catches up rows appended
-- past the copy watermark. This drains that tail ONLINE, in bounded batches, before the lock -- so the
-- locked catch-up applies only the final tail. It is the simpler sibling of the #170 delta drain: purely
-- additive (no delta, no reconcile, no key), so it works on a KEYLESS hypertable (the common shape). This
-- proves the appends land in the dest while the source is still a live hypertable (not just at cutover),
-- that a single step copies a bounded batch, that a threshold leaves a tail the cutover finishes, and that
-- the cutover still catches post-drain appends. Autocommit, disposable-db.
select plan(15);

-- Stamp a keyless hypertable whose data ends BEFORE now() (headroom), so the "appended after the copy"
-- rows can sit in the recent PAST -- above the copy watermark but at/under now(). transmute bounds the
-- monolith at the grid boundary just above now() (it assumes no row is dated beyond the current interval),
-- so appends must be <= now(); future-dated appends are an unrelated data shape that transmute rejects.
create or replace function mk_past_keyless(p_name text, p_rows int, p_start_ago interval, p_end_ago interval)
returns void language plpgsql as $$
begin
  execute format('drop table if exists %I cascade', p_name);
  execute format('create table %I (ts timestamptz not null, device_id bigint, temp double precision)', p_name);
  perform create_hypertable(p_name, 'ts', chunk_time_interval => interval '1 day');
  execute format('insert into %I (ts, device_id, temp)
    select now() - %L::interval + (g * ((%L::interval - %L::interval) / %s)), (g %% 10), random()*100
    from generate_series(1, %s) g', p_name, p_start_ago, p_start_ago, p_end_ago, p_rows, p_rows);
end $$;

-- =====================================================================================================
-- Main flow: keyless hypertable (data ending ~2 days ago), copy WITHOUT tracking, append recent-past rows,
-- drain ONLINE, assert the dest gained them before any cutover.
-- =====================================================================================================
select mk_past_keyless('hp_app', 240, interval '10 days', interval '2 days');   -- keyless, data in now-10d .. now-2d
call pgpm.from_hypertable_copy('hp_app', 'ts');                                 -- no tracking => append-only catch-up

select ok(to_regclass('public.hp_app_pgpm_delta') is null,
  'append-only path installs no delta table (no change tracking)');
select is((select count(*)::int from hp_app_pgpm_dest), 240,
  'the copy populated the dest with all 240 existing rows');

-- rows appended AFTER the copy watermark (~now-2d), against the still-live hypertable, in the recent past
insert into hp_app (ts, device_id, temp)
  select now() - interval '1 day' + (g || ' minutes')::interval, 1000 + g, 7 from generate_series(1, 20) g;

-- DRAIN ONLINE: the source is still a live hypertable, no lock is taken
call pgpm.from_hypertable_drain_appends('hp_app', 'ts');

select is((select count(*)::int from hp_app_pgpm_dest), 260,
  'the online append-drain copied the 20 appends into the dest (240 + 20), before any cutover');
select is((select count(*)::int from hp_app_pgpm_dest where device_id >= 1000), 20,
  'the appended rows are present in the dest online');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hp_app'), 1,
  'the source is still a live hypertable (the drain is online)');

-- more appends after the drain (later than the drained tail), then cutover catches them
insert into hp_app (ts, device_id, temp)
  select now() - interval '12 hours' + (g || ' minutes')::interval, 2000 + g, 9 from generate_series(1, 10) g;

call pgpm.from_hypertable_cutover('hp_app', 'ts', interval '1 month', p_paused => false);

select is((select relkind::text from pg_class where oid = 'hp_app'::regclass), 'p',
  'the table migrated to a native partitioned table');
select is((select count(*)::int from hp_app), 270,
  'final count = 240 copied + 20 pre-drained + 10 post-drain appends');
select is((select count(*)::int from hp_app where device_id >= 2000), 10,
  'the post-drain appends were caught by the cutover');
select ok(to_regclass('public.hp_app_pgpm_dest') is null,
  'the dest was swapped into place (no leftover _pgpm_dest)');

-- =====================================================================================================
-- A single step copies a bounded batch (the loop primitive, hand-drivable).
-- =====================================================================================================
select mk_past_keyless('hp_app2', 100, interval '5 days', interval '1 day');
call pgpm.from_hypertable_copy('hp_app2', 'ts');
insert into hp_app2 (ts, device_id, temp)
  select now() - interval '12 hours' + (g || ' minutes')::interval, 3000 + g, 1 from generate_series(1, 30) g;
select ok(
  pgpm.from_hypertable_drain_appends_step('hp_app2', 'ts', 10, (select max(ts)::text from hp_app2_pgpm_dest)) is not null,
  'a single append-drain step returns the advanced watermark');
select cmp_ok((select count(*)::int from hp_app2_pgpm_dest), '>', 100,
  'the step copied a bounded batch of appends into the dest');
select cmp_ok((select count(*)::int from hp_app2_pgpm_dest), '<', 130,
  'the step copied only its batch (10), not all 30 appends');

-- =====================================================================================================
-- A threshold stops the online drain early, leaving a tail the cutover finishes under the lock.
-- =====================================================================================================
select mk_past_keyless('hp_app3', 100, interval '5 days', interval '1 day');
call pgpm.from_hypertable_copy('hp_app3', 'ts');
insert into hp_app3 (ts, device_id, temp)
  select now() - interval '12 hours' + (g || ' minutes')::interval, 4000 + g, 1 from generate_series(1, 30) g;
-- batch 7, threshold 5: 30 -> 23 -> 16 -> 9 -> 2 past-watermark (stops with 2 <= 5 left)
call pgpm.from_hypertable_drain_appends('hp_app3', 'ts', p_batch => 7, p_threshold => 5);
select cmp_ok((select count(*)::int from hp_app3 where ts > (select max(ts) from hp_app3_pgpm_dest)), '<=', 5,
  'draining with a threshold leaves at most the threshold residual');
select cmp_ok((select count(*)::int from hp_app3 where ts > (select max(ts) from hp_app3_pgpm_dest)), '>', 0,
  'draining with a threshold stops before empty (a tail remains for the cutover)');
call pgpm.from_hypertable_cutover('hp_app3', 'ts', interval '1 month', p_paused => false);
select is((select count(*)::int from hp_app3 where device_id >= 4000), 30,
  'the cutover caught the threshold tail the online drain left behind (all 30 appends present)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

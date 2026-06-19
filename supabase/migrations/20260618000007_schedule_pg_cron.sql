-- =============================================================================
-- 07. Drive the drain from inside Postgres with pg_cron.
--
-- The job is scheduled but the drain is GATED by partition_migration.control
-- .is_paused (default true). So `supabase db reset` does NOT start moving data,
-- and tests stay deterministic. To run the live drain:
--
--   update partition_migration.control set is_paused = false;   -- start
--   update partition_migration.control set is_paused = true;    -- pause
--
-- Notes:
--   * Locally, pg_cron is preloaded in the Supabase Postgres image.
--   * On hosted Supabase, enable pg_cron via the dashboard first.
--   * If pg_cron is unavailable, this migration degrades gracefully and the
--     drain can still be run via:  select partition_migration.drain_all();
-- =============================================================================

do $$
begin
  create extension if not exists pg_cron;
exception when others then
  raise notice 'pg_cron unavailable (%): drain must be run manually via partition_migration.drain_all()', sqlerrm;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- Replace any existing job of the same name (idempotent across resets).
    perform cron.unschedule('drain-messages')
      where exists (select 1 from cron.job where jobname = 'drain-messages');

    perform cron.schedule(
      'drain-messages',
      '10 seconds',
      'call partition_migration.drain_step()'
    );
    raise notice 'Scheduled pg_cron job "drain-messages" (every 10s, paused by default).';
  end if;
exception when others then
  raise notice 'Could not schedule pg_cron job (%): use partition_migration.drain_all() instead', sqlerrm;
end;
$$;

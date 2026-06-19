-- =============================================================================
-- DEMO: hand the seeded, unpartitioned public.messages table to
-- pg_partition_magician.
--
-- adopt() does the online swap (rename -> partitioned parent -> attach old table
-- as DEFAULT, zero data movement) and premakes the next 4 monthly partitions.
-- Maintenance (premake + retention + drain) is left PAUSED so `supabase db reset`
-- does not start moving data and tests stay deterministic. To run the live drain:
--
--   update pgpm.config set paused = false;            -- start
--   select * from pgpm.status();                      -- watch
--   select pgpm.check_default('public.messages');     -- rows still in DEFAULT
--
-- Or drive it synchronously (ignores pause), including the open/current month:
--
--   select pgpm.drain_all('public.messages', p_include_open => true);
-- =============================================================================

select pgpm.adopt(
  p_parent       => 'public.messages',
  p_control      => 'created_at',
  p_interval     => '1 month',
  p_premake      => 4,
  p_retention    => null,      -- keep everything in this demo
  p_drain_batch  => 5000,
  p_paused       => true
);

-- Schedule maintenance via pg_cron (no-op while paused). Degrades gracefully if
-- pg_cron is unavailable; you can always call pgpm.maintenance_all() by hand.
do $$
begin
  create extension if not exists pg_cron;
exception when others then
  raise notice 'pg_cron unavailable (%): run select pgpm.maintenance_all() manually', sqlerrm;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('pgpm-maintenance')
      where exists (select 1 from cron.job where jobname = 'pgpm-maintenance');
    perform cron.schedule('pgpm-maintenance', '30 seconds', 'call pgpm.maintenance_all()');
    raise notice 'Scheduled pg_cron job "pgpm-maintenance" (every 30s, paused by default).';
  end if;
exception when others then
  raise notice 'Could not schedule pg_cron job (%): use pgpm.maintenance_all() instead', sqlerrm;
end;
$$;

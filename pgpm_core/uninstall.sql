-- Uninstall pg_partition_magician.
--
-- Removes the MANAGER (schema pgpm) and its scheduled maintenance, but NOT your
-- data: tables that were transmuted remain partitioned tables; their partitions and
-- rows are untouched. Only the tooling (config, registry, functions, views, the
-- pg_cron job) goes away.
--
-- Run with: psql --single-transaction -f pgpm_core/uninstall.sql

-- Unschedule every pgpm cron job (matched by prefix so this stays correct as the
-- cron surface evolves). Best-effort and tolerant of missing pg_cron / privileges.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname) from cron.job where jobname like 'pgpm%';
  end if;
exception
  when undefined_table then null;
  when undefined_function then null;
  when insufficient_privilege then null;
end;
$$;

drop schema if exists pgpm cascade;

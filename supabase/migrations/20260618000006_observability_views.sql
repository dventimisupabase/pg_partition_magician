-- =============================================================================
-- 06. Observability (design doc, Part IX).
--
-- The DEFAULT-partition strategy makes progress directly measurable: rows left
-- in DEFAULT, per-window state, dead tuples, autovacuum activity, table size.
-- That is what makes the migration controllable -- you can watch it and pause.
-- =============================================================================

-- Per-window progress: how much is left in DEFAULT for each month-window.
create or replace view partition_migration.progress as
select
  w.window_start,
  w.window_end,
  w.staging_table,
  w.state,
  w.rows_moved,
  (
    select count(*)
      from public.messages_default d
     where d.created_at >= w.window_start
       and d.created_at <  w.window_end
  ) as rows_remaining_in_default,
  w.started_at,
  w.last_batch_at,
  w.attached_at
from partition_migration.windows w
order by w.window_start desc;

-- Storage / vacuum health of the DEFAULT partition during the drain.
create or replace view partition_migration.health as
select
  s.relname,
  s.n_live_tup,
  s.n_dead_tup,
  s.last_vacuum,
  s.last_autovacuum,
  s.vacuum_count,
  s.autovacuum_count,
  pg_size_pretty(pg_total_relation_size(s.relid)) as total_size,
  (select count(*)        from public.messages_default) as rows_remaining_total,
  (select min(created_at) from public.messages_default) as oldest_remaining
from pg_stat_user_tables s
where s.schemaname = 'public'
  and s.relname   = 'messages_default';

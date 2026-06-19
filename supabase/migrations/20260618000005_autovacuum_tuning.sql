-- =============================================================================
-- 05. Treat the drain as controlled maintenance (design doc, Part VII).
--
-- The drain DELETEs rows from messages_default continuously, producing dead
-- tuples. Rather than fighting bloat after the fact, make autovacuum aggressive
-- on the DEFAULT partition so cleanup capacity stays AHEAD of dead-tuple
-- production: trigger on an absolute threshold (not a scale factor of a huge
-- table), and give it a higher cost budget with a small delay.
-- =============================================================================

alter table public.messages_default set (
  autovacuum_vacuum_scale_factor    = 0.0,
  autovacuum_vacuum_threshold       = 1000,
  autovacuum_analyze_scale_factor   = 0.0,
  autovacuum_analyze_threshold      = 1000,
  autovacuum_vacuum_cost_limit      = 2000,
  autovacuum_vacuum_cost_delay      = 2
);

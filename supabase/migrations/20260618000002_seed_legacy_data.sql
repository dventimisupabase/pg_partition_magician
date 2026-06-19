-- =============================================================================
-- 02. Seed the UNPARTITIONED table -- BEFORE conversion.
--
-- This runs as a migration (not seed.sql) on purpose: Supabase runs seed.sql
-- AFTER all migrations, i.e. after conversion. Seeding here guarantees the data
-- exists in the single unpartitioned table first, so the conversion in 03 has a
-- realistic "large existing table" to adopt as its DEFAULT partition.
--
-- Scale knob (no file edit required):
--   ALTER DATABASE postgres SET poc.seed_count = 1000000;
--   supabase db reset
-- =============================================================================

select public.generate_messages(
  coalesce(current_setting('poc.seed_count', true)::int, 50000),
  6  -- months of history
);

analyze public.messages;

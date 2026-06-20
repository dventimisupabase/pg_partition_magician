# Changelog

## [Unreleased]

- `build_pk_concurrently(parent, control)`: a procedure that builds the default's
  composite PK index ONLINE before `adopt`, so the cutover stays metadata-only even on
  very large tables (at ~300M rows the previous in-transaction build was a ~28-minute
  write-blocking window). `CREATE INDEX CONCURRENTLY` can't run inside a function, but it
  can from a pg_cron worker, so this schedules the CIC as a cron job, polls until the
  index is valid, then unschedules. Entirely inside pgpm (no DDL handed to the operator),
  using the existing pg_cron dependency. `adopt` then detects the pre-built index by its
  columns and promotes it; it falls back to the in-transaction build when none exists.

## [0.1.0] - 2026-06-19

Initial release of pg_partition_magician.

- Pure-SQL online RANGE-partition manager (schema `pgpm`); only runtime dependency is pg_cron.
- Partition dimensions: `time`, `id` (bigint/numeric, incl. Snowflake-style), `uuidv7`/ULID-as-uuid. float/double rejected.
- `adopt` / `adopt_by_id` / `adopt_by_uuidv7`: online conversion of an existing table (attach as DEFAULT, no rebuild of the default's PK index).
- premake ahead of the write frontier; paced microbatch drain of the DEFAULT's closed tail (scan-skip attach); retention; maintenance via pg_cron.
- Incoming-FK handling: refuse by default, opt-in drop+record, and `generate_fk_recovery()`.
- Three install channels (psql / bundle / dbdev-TLE) built from one source; PG 15-18 channel test matrix; 53 pgTAP tests.

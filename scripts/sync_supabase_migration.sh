#!/usr/bin/env bash
# Regenerate the Supabase install migration from the single source of truth,
# sql/pg_partition_magician.sql. Supabase migrations can't `\i` an external file,
# so the module is inlined into the migration. Run after editing the module:
#
#   scripts/sync_supabase_migration.sh
#
# CI runs this and fails on drift (so the copy can never get stale).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sql/pg_partition_magician.sql"
OUT="$ROOT/supabase/migrations/20260618000003_install_pg_partition_magician.sql"
[ -f "$SRC" ] || { echo "sync: missing $SRC" >&2; exit 1; }

{
  echo "-- GENERATED FILE -- do not edit."
  echo "-- Source of truth: sql/pg_partition_magician.sql"
  echo "-- Regenerate with: scripts/sync_supabase_migration.sh"
  echo
  cat "$SRC"
} > "$OUT"

echo "Synced $OUT from $SRC"

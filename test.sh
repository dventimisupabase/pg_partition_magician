#!/usr/bin/env bash
# Channel test matrix for pg_partition_magician.
#
# For each PostgreSQL version, install the module through each distribution
# channel, load the demo migrations as fixtures, run the pgTAP suite, and verify
# a clean uninstall.
#
#   ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all]
#
# Channels:
#   psql    sql/pg_partition_magician.sql via psql -f         (the source)
#   bundle  scripts/build_install_bundle.sh output            (Supabase SQL editor)
#   dbdev   scripts/build_dbdev_package.sh output (minified)  (dbdev / TLE / CREATE EXTENSION)
set -euo pipefail

cd "$(dirname "$0")"

VERSION="all"
CHANNEL="all"
for arg in "$@"; do
  case "$arg" in
    --channel=*) CHANNEL="${arg#--channel=}" ;;
    15|16|17|18|all) VERSION="$arg" ;;
    *) echo "usage: ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all]"; exit 1 ;;
  esac
done

if command -v docker-compose &>/dev/null; then DC="docker-compose"; else DC="docker compose"; fi
[ "$CHANNEL" = "all" ] && CHANNELS=(psql bundle dbdev) || CHANNELS=("$CHANNEL")
[ -n "${CI:-}" ] && BUILD_PROGRESS="--progress=plain" || BUILD_PROGRESS=""

VER=$(awk -F"'" '/default_version/ {print $2}' extension.control)
DBDEV_PKG="dist/pg_partition_magician--${VER}.sql"
BUNDLE="dist/pg_partition_magician-bundle.sql"

# Build the channel artifacts on the host (version-independent).
echo ">>> Building install artifacts..."
scripts/build_install_bundle.sh sql/pg_partition_magician.sql "$BUNDLE"
scripts/build_dbdev_package.sh  sql/pg_partition_magician.sql "$DBDEV_PKG"
if grep -nE '^\\' "$BUNDLE" "$DBDEV_PKG"; then
  echo "ERROR: a packaged artifact still contains psql metacommands"; exit 1
fi

psql_run() { $DC --profile "$1" exec -T "$2" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "${@:3}"; }

install_channel() {  # <channel> <profile> <service>
  case "$1" in
    psql)   psql_run "$2" "$3" --single-transaction -f /repo/sql/pg_partition_magician.sql >/dev/null ;;
    bundle) psql_run "$2" "$3" -f "/repo/$BUNDLE" >/dev/null ;;
    dbdev)  psql_run "$2" "$3" --single-transaction -f "/repo/$DBDEV_PKG" >/dev/null ;;
    *) echo "unknown channel $1"; exit 1 ;;
  esac
}

load_fixtures() {  # <profile> <service> -- the demo migrations double as fixtures
  local p="$1" s="$2"
  psql_run "$p" "$s" -c "ALTER DATABASE postgres SET poc.seed_count = 8000; ALTER DATABASE postgres SET poc.events_count = 4000;" >/dev/null
  psql_run "$p" "$s" -f /repo/supabase/migrations/20260618000001_create_messages_unpartitioned.sql >/dev/null
  psql_run "$p" "$s" -f /repo/supabase/migrations/20260618000002_seed_legacy_data.sql >/dev/null
  psql_run "$p" "$s" -f /repo/supabase/migrations/20260618000004_adopt_messages_demo.sql >/dev/null
  psql_run "$p" "$s" -f /repo/supabase/migrations/20260618000005_adopt_id_and_uuid_demos.sql >/dev/null
}

uninstall_and_verify() {  # <profile> <service>
  local p="$1" s="$2" result
  psql_run "$p" "$s" --single-transaction -f /repo/sql/uninstall.sql >/dev/null
  result=$($DC --profile "$p" exec -T "$s" psql -U postgres -d postgres -tA -c "
    select (select count(*) from pg_namespace where nspname='pgpm'),
           (select count(*) from cron.job where jobname like 'pgpm%')")
  if [ "$result" != "0|0" ]; then
    echo "ERROR: uninstall left state behind (schemas|cron='$result', expected 0|0)"; return 1
  fi
}

reset_demo() {  # <profile> <service> -- drop fixture tables so the next channel is clean
  psql_run "$1" "$2" -c "
    drop table if exists public.messages, public.events_id, public.events_uuid cascade;
    drop function if exists public.generate_messages(int, int);" >/dev/null
}

run_version() {  # <pg_version>
  local v="$1" s="postgres$1" p="pg$1"
  echo; echo "========================================="
  echo "PostgreSQL $v -- channels: ${CHANNELS[*]}"
  echo "========================================="
  $DC --profile "$p" down -v 2>/dev/null || true
  $DC --profile "$p" build $BUILD_PROGRESS
  $DC --profile "$p" up -d

  for _ in $(seq 1 60); do
    $DC --profile "$p" exec -T "$s" psql -U postgres -tAc 'select 1' >/dev/null 2>&1 && break; sleep 1
  done
  psql_run "$p" "$s" -c "create extension if not exists pg_cron; create extension if not exists pgtap;" >/dev/null

  for ch in "${CHANNELS[@]}"; do
    echo "--- channel: $ch ---"
    install_channel "$ch" "$p" "$s"
    load_fixtures "$p" "$s"
    $DC --profile "$p" exec -T "$s" sh -c 'pg_prove --timer -U postgres -d postgres /repo/supabase/tests/*.sql'
    uninstall_and_verify "$p" "$s"
    reset_demo "$p" "$s"
    echo "PG $v / $ch: PASS"
  done
  $DC --profile "$p" down -v
  echo "PostgreSQL $v: PASS"
}

if [ "$VERSION" = "all" ]; then
  for v in 15 16 17 18; do run_version "$v"; done
else
  run_version "$VERSION"
fi
echo; echo "All requested tests passed."

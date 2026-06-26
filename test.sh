#!/usr/bin/env bash
# Channel test matrix for pg_partition_magician.
#
# For each PostgreSQL version, install the module through each distribution
# channel, load the demo migrations as fixtures, run the pgTAP suite, and verify
# a clean uninstall.
#
#   ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all]
#   ./test.sh timescale                  # the from_hypertable track (TimescaleDB 2.16.1 / PG15)
#
# Channels:
#   psql    sql/pg_partition_magician.sql via psql -f         (the source)
#   bundle  scripts/build_install_bundle.sh output            (dashboard SQL editor)
#   dbdev   scripts/build_dbdev_package.sh output (minified)  (dbdev / TLE / CREATE EXTENSION)
#
# The `timescale` track is separate: it needs TimescaleDB (its own image), is PG15-only, and is NOT part
# of the default matrix. It exercises pgpm.from_hypertable against real hypertables (tests/timescale/).
set -euo pipefail

cd "$(dirname "$0")"

VERSION="all"
CHANNEL="all"
TRACK="matrix"
for arg in "$@"; do
  case "$arg" in
    --channel=*) CHANNEL="${arg#--channel=}" ;;
    15|16|17|18|all) VERSION="$arg" ;;
    timescale) TRACK="timescale" ;;
    *) echo "usage: ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all] | timescale"; exit 1 ;;
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

load_fixtures() {  # <profile> <service> -- build the demo tables for the pgTAP suite
  local p="$1" s="$2"
  psql_run "$p" "$s" -c "ALTER DATABASE postgres SET poc.seed_count = 8000; ALTER DATABASE postgres SET poc.events_count = 4000;" >/dev/null
  psql_run "$p" "$s" -f /repo/fixtures/demo.sql >/dev/null
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
    $DC --profile "$p" exec -T "$s" sh -c 'pg_prove --timer -U postgres -d postgres /repo/tests/*.sql'
    uninstall_and_verify "$p" "$s"
    reset_demo "$p" "$s"
    echo "PG $v / $ch: PASS"
  done
  $DC --profile "$p" down -v
  echo "PostgreSQL $v: PASS"
}

# The from_hypertable track. TimescaleDB-only, PG15, run against each version in the Supabase fleet that
# matters (TS_VERSIONS, default the two big clusters: 2.9.1 and 2.16.1). Each tests/timescale/db/*.sql runs
# against a fresh throwaway database (disposable-db) because from_hypertable is a procedure that COMMITs
# (per chunk and at cutover) and so cannot be wrapped in a rolled-back transaction. We drive psql directly
# and scan the TAP output for failures (the Alpine image carries pgTAP but not pg_prove).
run_timescale() {
  local prof="timescale" svc="timescale" fail=0 f db out ver
  for ver in ${TS_VERSIONS:-2.9.1 2.16.1}; do
    export TS_VERSION="$ver"   # docker-compose interpolates this into the image tag + build arg
    echo; echo "========================================="
    echo "TimescaleDB $ver / pg15 -- from_hypertable"
    echo "========================================="
    $DC --profile "$prof" down -v 2>/dev/null || true
    $DC --profile "$prof" build $BUILD_PROGRESS
    $DC --profile "$prof" up -d
    # Wait for the REAL server. The official postgres entrypoint runs a temporary init server on the unix
    # socket only (no TCP listener); probing over TCP therefore succeeds ONLY once the real server is up,
    # avoiding the "database system is shutting down" race where a socket probe catches the temp init
    # server right before it restarts (TimescaleDB's heavier init widens that window).
    for _ in $(seq 1 90); do
      $DC --profile "$prof" exec -T -e PGPASSWORD=postgres "$svc" \
        psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1 && break
      sleep 1
    done

    for f in tests/timescale/db/*.sql; do
      db="t_$(basename "$f" .sql | tr -cd 'a-z0-9_')"
      echo "--- ${f##*/} (db: $db) ---"
      $DC --profile "$prof" exec -T "$svc" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
        -c "drop database if exists $db" -c "create database $db" \
        -c "alter database $db set client_min_messages = warning" >/dev/null
      $DC --profile "$prof" exec -T "$svc" psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -q \
        -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null
      $DC --profile "$prof" exec -T "$svc" psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -q \
        --single-transaction -f /repo/sql/pg_partition_magician.sql >/dev/null
      $DC --profile "$prof" exec -T "$svc" psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -q \
        -f /repo/sql/from_hypertable.sql >/dev/null
      $DC --profile "$prof" exec -T "$svc" psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -q \
        -f /repo/tests/timescale/fixtures.sql >/dev/null
      # -tA gives clean TAP (no table chrome); no ON_ERROR_STOP so every assertion reports.
      out=$($DC --profile "$prof" exec -T "$svc" psql -U postgres -d "$db" -tAq -f "/repo/$f" 2>&1)
      echo "$out" | grep -E '^(ok|not ok|1\.\.|# )' || true
      if echo "$out" | grep -qE '^not ok|^# Looks like you failed|ERROR:'; then
        echo "FAIL ($ver): $f"; fail=1
      fi
      $DC --profile "$prof" exec -T "$svc" psql -U postgres -d postgres -q -c "drop database if exists $db" >/dev/null
    done

    $DC --profile "$prof" down -v
  done
  if [ "$fail" -ne 0 ]; then echo "TimescaleDB track: FAIL"; return 1; fi
  echo "TimescaleDB track: PASS"
}

if [ "$TRACK" = "timescale" ]; then
  run_timescale
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$VERSION" = "all" ]; then
  for v in 15 16 17 18; do run_version "$v"; done
else
  run_version "$VERSION"
fi
echo; echo "All requested tests passed."

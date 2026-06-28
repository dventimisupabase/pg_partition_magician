#!/usr/bin/env bash
# Channel test matrix for pg_partition_magician.
#
# For each PostgreSQL version, install the module through each distribution
# channel, load the demo migrations as fixtures, run the pgTAP suite, and verify
# a clean uninstall.
#
#   ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all]
#   ./test.sh timescale                  # the from_hypertable track (TimescaleDB 2.16.1 / PG15)
#   ./test.sh observe                    # the pg_flight_recorder observability track (PG15)
#
# Channels:
#   psql    pgpm_core/install.sql via psql -f         (the source)
#   bundle  scripts/build_install_bundle.sh output            (dashboard SQL editor)
#   dbdev   scripts/build_dbdev_package.sh output (minified)  (dbdev / TLE / CREATE EXTENSION)
#
# The `timescale` track is a separate invocation (it needs TimescaleDB on its own image and is PG15-only, so
# `./test.sh` with no args does not run it), but CI's default Test Suite calls it on every push/PR via the
# reusable .github/workflows/timescale.yml. It exercises pgpm.from_hypertable against real hypertables
# (tests/timescale/).
#
# The `observe` track is also separate: it installs the OPTIONAL pgpm_observe module on top of the core,
# both with and without pg_flight_recorder present, and asserts the gate + the impact_report /
# feathering_validation correlation against PGFR telemetry (tests/observe/). PGFR is vendored under
# bench/vendor/ and needs only pg_cron, so the track runs on the stock pgpm_test:15 image.
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
    observe) TRACK="observe" ;;
    *) echo "usage: ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all] | timescale | observe"; exit 1 ;;
  esac
done

if command -v docker-compose &>/dev/null; then DC="docker-compose"; else DC="docker compose"; fi
[ "$CHANNEL" = "all" ] && CHANNELS=(psql bundle dbdev) || CHANNELS=("$CHANNEL")
[ -n "${CI:-}" ] && BUILD_PROGRESS="--progress=plain" || BUILD_PROGRESS=""

VER=$(awk -F"'" '/default_version/ {print $2}' pgpm_core/extension.control)
DBDEV_PKG="dist/pg_partition_magician--${VER}.sql"
BUNDLE="dist/pg_partition_magician-bundle.sql"

# Build the channel artifacts on the host (version-independent).
echo ">>> Building install artifacts..."
scripts/build_install_bundle.sh pgpm_core/install.sql "$BUNDLE"
scripts/build_dbdev_package.sh  pgpm_core/install.sql "$DBDEV_PKG"
if grep -nE '^\\' "$BUNDLE" "$DBDEV_PKG"; then
  echo "ERROR: a packaged artifact still contains psql metacommands"; exit 1
fi

psql_run() { $DC --profile "$1" exec -T "$2" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "${@:3}"; }

install_channel() {  # <channel> <profile> <service>
  case "$1" in
    psql)   psql_run "$2" "$3" --single-transaction -f /repo/pgpm_core/install.sql >/dev/null ;;
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
  psql_run "$p" "$s" --single-transaction -f /repo/pgpm_core/uninstall.sql >/dev/null
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

# The from_hypertable track. PG15 + Apache TimescaleDB, run on the Supabase fleet image
# (public.ecr.aws/supabase/postgres -- the Apache edition the migration actually targets; it ships
# timescaledb, pgTAP, and the timescaledb shared_preload preloaded, so there is no image build). Each
# tests/timescale/db/*.sql runs against a fresh throwaway database (disposable-db) because from_hypertable
# commits (per chunk and at cutover) and so cannot be wrapped in a rolled-back transaction. We drive psql
# over TCP (with PGPASSWORD, since the managed image does not trust the local socket) and scan the TAP
# output for failures (the runner does not need pg_prove). To exercise a second fleet TimescaleDB version,
# add the supabase/postgres:15 tag that bundles it to TS_PG_TAGS (e.g. an older tag for the 2.9.x cluster).
run_timescale() {
  local prof="timescale" svc="timescale" fail=0 f db out tag
  local px=( --profile "$prof" exec -T -e PGPASSWORD=postgres "$svc" psql -h 127.0.0.1 -U postgres )
  for tag in ${TS_PG_TAGS:-15.14.1.127}; do
    export TS_PG_TAG="$tag"   # docker-compose interpolates this into the supabase/postgres image tag
    echo; echo "========================================="
    echo "Apache TimescaleDB via supabase/postgres:$tag / pg15 -- from_hypertable"
    echo "========================================="
    $DC --profile "$prof" down -v 2>/dev/null || true
    # ECR Public rate-limits ANONYMOUS pulls, and CI runners share source IPs, so a single image pull often
    # trips "toomanyrequests: Rate exceeded" and the suite never runs. Pull explicitly with growing backoff
    # first (the throttle is transient); once the image is cached, `up` reuses it (default pull policy =
    # missing). Left operand of `&&`, so a failed pull is not fatal under `set -e`.
    for attempt in 1 2 3 4 5; do
      $DC --profile "$prof" pull "$svc" && break
      echo "  image pull attempt $attempt hit a rate limit; backing off $((attempt * 15))s..."
      sleep $((attempt * 15))
    done
    $DC --profile "$prof" up -d
    # Wait for the REAL server over TCP. The postgres entrypoint runs a temporary init server on the unix
    # socket only, so a TCP probe succeeds ONLY once the real server is up -- avoiding the "database system
    # is shutting down" race (supabase/postgres's heavier init widens that window).
    for _ in $(seq 1 120); do
      $DC "${px[@]}" -tAc 'select 1' >/dev/null 2>&1 && break
      sleep 1
    done
    echo "  edition: timescaledb $($DC "${px[@]}" -d postgres -tAc "select default_version||' ('||current_setting('timescaledb.license')||')' from pg_available_extensions where name='timescaledb'" 2>/dev/null | tr -d '\r')"

    for f in tests/timescale/db/*.sql; do
      db="t_$(basename "$f" .sql | tr -cd 'a-z0-9_')"
      echo "--- ${f##*/} (db: $db) ---"
      $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
        -c "drop database if exists $db" -c "create database $db" \
        -c "alter database $db set client_min_messages = warning" >/dev/null
      $DC "${px[@]}" -d "$db" -v ON_ERROR_STOP=1 -q \
        -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null
      $DC "${px[@]}" -d "$db" -v ON_ERROR_STOP=1 -q \
        --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
      $DC "${px[@]}" -d "$db" -v ON_ERROR_STOP=1 -q -f /repo/pgpm_hypertable/install.sql >/dev/null
      $DC "${px[@]}" -d "$db" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null
      # -tA gives clean TAP (no table chrome); no ON_ERROR_STOP so every assertion reports.
      out=$($DC "${px[@]}" -d "$db" -tAq -f "/repo/$f" 2>&1)
      echo "$out" | grep -E '^(ok|not ok|1\.\.|# )' || true
      if echo "$out" | grep -qE '^not ok|^# Looks like you failed|ERROR:'; then
        echo "FAIL ($tag): $f"; fail=1
      fi
      $DC "${px[@]}" -d postgres -q -c "drop database if exists $db" >/dev/null
    done

    $DC --profile "$prof" down -v
  done
  if [ "$fail" -ne 0 ]; then echo "TimescaleDB track: FAIL"; return 1; fi
  echo "TimescaleDB track: PASS"
}

run_observe() {  # pg_flight_recorder observability track: gate (PGFR absent) + correlation (PGFR present)
  local prof="pg15" svc="postgres15" fail=0 out
  local px=( --profile "$prof" exec -T "$svc" psql -U postgres )
  local pgfr="/repo/bench/vendor/pg_flight_recorder"          # container path (repo mounted at /repo)
  local pgfr_host="bench/vendor/pg_flight_recorder"           # host path (bench/vendor is gitignored)
  local pgfr_repo="https://github.com/dventimisupabase/pg_flight_recorder"
  local pgfr_sha="34517280f70b67ae8c8f99d18515550b629c9cd2"   # pin for reproducible CI
  # Clone-on-demand: PGFR is a vendored external repo (bench/vendor is gitignored), so it is absent on a
  # fresh checkout / in CI. Pull it at the pinned SHA when missing; a full clone so the SHA is reachable.
  if [ ! -f "$pgfr_host/pgfr_record/install.sql" ]; then
    echo ">>> cloning pg_flight_recorder@${pgfr_sha:0:7} into $pgfr_host"
    rm -rf "$pgfr_host"; mkdir -p "$(dirname "$pgfr_host")"
    git clone --quiet "$pgfr_repo" "$pgfr_host"
    git -C "$pgfr_host" checkout --quiet "$pgfr_sha"
  fi
  echo; echo "========================================="
  echo "pg_flight_recorder observability track (pg15)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true   # fresh container: the with-PGFR phase installs into postgres
  $DC --profile "$prof" up -d
  for _ in $(seq 1 90); do $DC "${px[@]}" -d postgres -tAc 'select 1' >/dev/null 2>&1 && break; sleep 1; done

  run_observe_file() {  # <db> <test-file> -- run one pgTAP file, collect TAP, flag failures
    local db="$1" f="$2"
    echo "--- ${f##*/} (db: $db) ---"
    out=$($DC "${px[@]}" -d "$db" -tAq -f "$f" 2>&1)
    echo "$out" | grep -E '^(ok|not ok|1\.\.|# )' || true
    if echo "$out" | grep -qE '^not ok|^# Looks like you failed|ERROR:'; then echo "FAIL: $f"; fail=1; fi
  }

  # 1) PGFR ABSENT: the optional module installs and gates without pg_flight_recorder. pgpm core needs no
  #    pg_cron to install, and pg_cron can only be created in cron.database_name -- so this fresh db omits it.
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "drop database if exists t_obs_nopgfr" -c "create database t_obs_nopgfr" >/dev/null
  $DC "${px[@]}" -d t_obs_nopgfr -v ON_ERROR_STOP=1 -q -c "create extension if not exists pgtap;" >/dev/null
  $DC "${px[@]}" -d t_obs_nopgfr -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  $DC "${px[@]}" -d t_obs_nopgfr -v ON_ERROR_STOP=1 -q -f /repo/pgpm_observe/install.sql >/dev/null
  run_observe_file t_obs_nopgfr /repo/tests/observe/db/01_no_pgfr_test.sql
  $DC "${px[@]}" -d postgres -q -c "drop database if exists t_obs_nopgfr" >/dev/null

  # 2) PGFR PRESENT: pg_flight_recorder requires pg_cron, which lives only in cron.database_name (postgres),
  #    so this runs in the postgres db. The test wraps itself in BEGIN/ROLLBACK, so it leaves no state.
  #    disable() unschedules PGFR's cron so the synthetic snapshots in the test stay deterministic.
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists pg_cron; create extension if not exists pgtap;" >/dev/null
  # The vendored PGFR install is best-effort (|| true): without pg_stat_statements preloaded (the test image
  # does not) its statement collector errors, and psql then exits non-zero even though the schema is fully
  # built -- which would otherwise trip `set -e`. We verify the schema actually landed with the guard below.
  $DC "${px[@]}" -d postgres -q -f "$pgfr/pgfr_record/install.sql"  >/dev/null 2>&1 || true
  $DC "${px[@]}" -d postgres -q -f "$pgfr/pgfr_analyze/install.sql" >/dev/null 2>&1 || true
  if [ "$($DC "${px[@]}" -d postgres -tAc "select count(*) from pg_namespace where nspname='pgfr_analyze'" | tr -d '[:space:]')" != "1" ]; then
    echo "FAIL: pg_flight_recorder (pgfr_analyze) did not install"; $DC --profile "$prof" down -v; return 1
  fi
  $DC "${px[@]}" -d postgres -q -c "select pgfr_record.disable()" >/dev/null 2>&1 || true
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -f /repo/pgpm_observe/install.sql >/dev/null
  run_observe_file postgres /repo/tests/observe/db/02_with_pgfr_test.sql

  $DC --profile "$prof" down -v
  if [ "$fail" -ne 0 ]; then echo "observe track: FAIL"; return 1; fi
  echo "observe track: PASS"
}

if [ "$TRACK" = "timescale" ]; then
  run_timescale
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "observe" ]; then
  run_observe
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$VERSION" = "all" ]; then
  for v in 15 16 17 18; do run_version "$v"; done
else
  run_version "$VERSION"
fi
echo; echo "All requested tests passed."

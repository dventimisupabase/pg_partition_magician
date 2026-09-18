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
#   ./test.sh archive                    # the pgpm_archive track (PG17 + pgsql-http + MinIO)
#   ./test.sh perf                       # the data-coupled lock and work guards (PG17)
#   ./test.sh discriminate               # prove each of those guards fails when its defect is present
#   ./test.sh locktrace                  # eBPF lock-boundary observation (PG17, Linux only)
#   ./test.sh lockview                   # the lock-sequence renderer's eBPF capture (PG17, Linux only)
#   ./test.sh ci                         # EVERY track CI runs, in one go
#
# `all` means all four PostgreSQL VERSIONS, not all tracks. The timescale, observe, archive, perf,
# discriminate, locktrace and lockview tracks each need their own image or service, so `./test.sh all` deliberately skips them
# and a green run of it does NOT mean CI will be green. That gap is real: a change to
# pgpm_core/install.sql broke the archive track's fixture while `./test.sh all` stayed green from end
# to end, and only the PR's archive job caught it. Use `./test.sh ci` before pushing anything that
# touches pgpm_core, which every one of these tracks installs.
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
# The `observe` track is also separate: pgpm_core ships pg_flight_recorder (PGFR) correlation functions
# (observe_window/impact_report) that are always present but only do anything
# useful with PGFR installed (the PGFR-absent gate is a plain test in the main suite,
# tests/65_observe_no_pgfr_test.sql). This track installs the vendored PGFR and asserts the
# impact_report correlation against its telemetry (tests/observe/). PGFR is
# vendored under bench/vendor/ and needs only pg_cron, so the track runs on the stock pgpm_test:15 image.
#
# The `archive` track is also separate: it installs the OPTIONAL pgpm_archive module on top of the
# core and exercises it against a real MinIO container standing in for S3 (tests/archive/). Its own
# image (pgpm_test:17-archive) adds pgsql-http on top of the stock pg17 image. Like the default matrix,
# it runs every tests/archive/db/*.sql via pg_prove in ONE DATABASE PER FILE, each one cloned from a
# template (pgpm_arch_tmpl) that carries the fixtures and both modules. These files used to isolate
# themselves with BEGIN/ROLLBACK against one shared database, which stopped being possible once the
# fixture's pgpm.transmute became a committing PROCEDURE (#275): transaction control is illegal inside
# an explicit transaction block. Cloning gives back the isolation the rollback provided, and gives it
# for real, since a rollback never undid anything these tests pushed to MinIO. After the pgTAP
# suite, it also runs scripts/verify_parquet.py/verify_parquet_range.py (a venv-installed Python
# step, not psql) against the same running instance: independent-reader (pyarrow + DuckDB)
# verification of archive._pq_to_parquet/_range, ported into this repo proper from a standalone
# prototype (prototypes/parquet-writer/, removed) once that prototype's code was fully absorbed
# into pgpm_archive/install.sql.
# It is a standalone, path-filtered CI workflow (like `observe`'s), not wired into the default Test
# Suite or the release gate.
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
    archive) TRACK="archive" ;;
    perf) TRACK="perf" ;;
    discriminate) TRACK="discriminate" ;;
    locktrace) TRACK="locktrace" ;;
    lockview) TRACK="lockview" ;;
    ci) TRACK="ci" ;;
    *) echo "usage: ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all] | timescale | observe | archive | perf | discriminate | locktrace | lockview | ci"; exit 1 ;;
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

# Wait for the REAL server, over TCP (#317).
#
# The postgres entrypoint starts a TEMPORARY init server to run its init scripts, then shuts it down and
# starts the real one. That temporary server listens on the UNIX SOCKET ONLY. So a socket probe can
# succeed against it and hand back a connection that dies moments later -- the next command fails with
# `No such file or directory` on the socket, or `the database system is shutting down`, one or two
# seconds after compose reported the container Started. A TCP probe cannot see the init server at all, so
# it succeeds only once the real one is accepting connections.
#
# The timescale track hit this first and fixed it there (supabase/postgres's heavier init widens the
# window). The matrix and the observe/archive tracks raced it too, just rarely enough to look like bad
# luck: it surfaced as one PG17 job of four failing while the other three passed the same commit.
#
# `up -d --wait` is NOT the fix, which is why it is not used here: the compose healthcheck is
# `pg_isready -U postgres`, which also goes over the socket and so is satisfied by the very init server
# this is trying to see past.
#
# Fails LOUDLY on exhaustion. The loops this replaces fell through to the first real command, which then
# reported the same confusing connection error -- so a genuinely dead container looked identical to a
# slow one, and the log pointed at the wrong statement.
wait_pg() {  # <profile> <service> [seconds]
  local prof="$1" svc="$2" n="${3:-90}"
  for _ in $(seq 1 "$n"); do
    $DC --profile "$prof" exec -T -e PGPASSWORD=postgres "$svc" \
       psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "ERROR: $svc did not accept TCP connections within ${n}s (container up but never ready)" >&2
  return 1
}

psql_run() { $DC --profile "$1" exec -T "$2" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "${@:3}"; }
# same, but against an arbitrary database: the pgTAP suite now runs one database PER FILE
psql_db()  { $DC --profile "$1" exec -T "$2" psql -U postgres -d "$3" -v ON_ERROR_STOP=1 "${@:4}"; }

install_channel() {  # <channel> <profile> <service> [db]
  local db="${4:-postgres}"
  case "$1" in
    psql)   psql_db "$2" "$3" "$db" --single-transaction -f /repo/pgpm_core/install.sql >/dev/null ;;
    bundle) psql_db "$2" "$3" "$db" -f "/repo/$BUNDLE" >/dev/null ;;
    dbdev)  psql_db "$2" "$3" "$db" --single-transaction -f "/repo/$DBDEV_PKG" >/dev/null ;;
    *) echo "unknown channel $1"; exit 1 ;;
  esac
}

load_fixtures() {  # <profile> <service> [db] -- build the demo tables for the pgTAP suite
  local p="$1" s="$2" db="${3:-postgres}"
  psql_db "$p" "$s" "$db" -c "ALTER DATABASE \"$db\" SET poc.seed_count = 8000; ALTER DATABASE \"$db\" SET poc.events_count = 4000;" >/dev/null
  psql_db "$p" "$s" "$db" -f /repo/fixtures/demo.sql >/dev/null
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

  wait_pg "$p" "$s" 60
  psql_run "$p" "$s" -c "create extension if not exists pg_cron; create extension if not exists pgtap;" >/dev/null

  for ch in "${CHANNELS[@]}"; do
    echo "--- channel: $ch ---"
    # The pgTAP suite runs ONE DATABASE PER FILE. It used to run every file against `postgres`, isolated
    # by wrapping each in BEGIN/ROLLBACK -- but a committing PROCEDURE cannot be called inside a
    # transaction block ("invalid transaction termination"), and transmute/maintain/drain_all are
    # procedures now. Isolation therefore has to come from the database, not from a transaction.
    #
    # Installing the channel and loading the fixtures per file would cost ~0.5 s each; building one
    # template and cloning it costs ~0.1 s (measured), so the suite stays fast enough to keep running on
    # every push.
    psql_run "$p" "$s" -c "drop database if exists pgpm_tmpl" >/dev/null
    psql_run "$p" "$s" -c "create database pgpm_tmpl" >/dev/null
    psql_db "$p" "$s" pgpm_tmpl -c "create extension if not exists pgtap;" >/dev/null
    install_channel "$ch" "$p" "$s" pgpm_tmpl
    load_fixtures "$p" "$s" pgpm_tmpl

    local n=0 failed=0 pg_ready=""
    for f in tests/*.sql; do
      local b db; b="$(basename "$f")"; n=$((n + 1)); db="pgpm_t$n"
      if [ "$b" = "31_schedule_test.sql" ] || [ "$b" = "78_retain_detach_dispatch_test.sql" ]; then
        # pg_cron can only be created in the database named by cron.database_name (postgres on these
        # images: "can only create extension in database postgres"), so these files cannot run in a
        # per-file clone. They get `postgres`, which the uninstall check below installs into anyway.
        # 31 covers schedule()/unschedule(); 78 covers retire() dispatching a concurrent detach to the
        # standing pgpm_detach job (#268). Both leave the cron state clean for the next file.
        db=postgres
        # Set `postgres` up ONCE per channel, however many files land here. fixtures/demo.sql CREATEs
        # its tables, so a second load fails on "relation messages already exists" -- and with
        # ON_ERROR_STOP under `set -e` that takes the whole version down, which is exactly what adding
        # a second file to this branch did.
        if [ "$pg_ready" != "$ch" ]; then
          install_channel "$ch" "$p" "$s"
          load_fixtures "$p" "$s"
          pg_ready="$ch"
        fi
      else
        psql_run "$p" "$s" -c "drop database if exists $db" >/dev/null
        psql_run "$p" "$s" -c "create database $db template pgpm_tmpl" >/dev/null
      fi
      if ! $DC --profile "$p" exec -T "$s" sh -c "pg_prove --timer -U postgres -d $db /repo/tests/$b"; then
        failed=$((failed + 1))
      fi
      [ "$db" = postgres ] || psql_run "$p" "$s" -c "drop database if exists $db" >/dev/null
    done
    psql_run "$p" "$s" -c "drop database if exists pgpm_tmpl" >/dev/null
    [ "$failed" -eq 0 ] || { echo "PG $v / $ch: FAIL ($failed file(s))"; return 1; }

    # the uninstall check still needs a database with the channel installed
    install_channel "$ch" "$p" "$s"
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
    # This track is where the TCP-probe rule was learned; wait_pg now carries it for every track.
    wait_pg "$prof" "$svc" 120
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

run_observe() {  # pg_flight_recorder observability track: impact_report correlation
                 # against a real PGFR install (the PGFR-absent gate is tests/65 in the main suite)
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
  echo "pg_flight_recorder correlation track (pg15)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true
  $DC --profile "$prof" up -d
  wait_pg "$prof" "$svc" 90

  run_observe_file() {  # <db> <test-file> -- run one pgTAP file, collect TAP, flag failures
    local db="$1" f="$2"
    echo "--- ${f##*/} (db: $db) ---"
    out=$($DC "${px[@]}" -d "$db" -tAq -f "$f" 2>&1)
    echo "$out" | grep -E '^(ok|not ok|1\.\.|# )' || true
    if echo "$out" | grep -qE '^not ok|^# Looks like you failed|ERROR:'; then echo "FAIL: $f"; fail=1; fi
  }

  # pg_flight_recorder requires pg_cron, which lives only in cron.database_name (postgres), so this runs in
  # the postgres db. The test wraps itself in BEGIN/ROLLBACK, so it leaves no state. disable() unschedules
  # PGFR's cron so the synthetic snapshots in the test stay deterministic.
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
  run_observe_file postgres /repo/tests/observe/db/with_pgfr_test.sql

  $DC --profile "$prof" down -v
  if [ "$fail" -ne 0 ]; then echo "observe track: FAIL"; return 1; fi
  echo "observe track: PASS"
}

# The pgpm_archive track: PG17 + pgsql-http against a real MinIO container standing in for S3.
# Builds one template database (pgpm_arch_tmpl) carrying the fixtures and both modules, then runs
# every tests/archive/db/*.sql via pg_prove against its OWN clone of it -- the same one-database-per-file
# pattern the default matrix uses, for the same reason (the clone loop below states it in full). MinIO
# has no docker-compose service of its own for the `mc` client, so bucket setup runs as a one-off
# `docker run` against the network name pinned in docker-compose.yml (pgpm_test_net) rather than a
# compose-managed service.
run_archive() {
  local prof="archive" svc="archive" fail=0
  local px=( --profile "$prof" exec -T "$svc" psql -U postgres )
  local net="pgpm_test_net"
  echo; echo "========================================="
  echo "Archive track: pgpm_archive against MinIO (pg17 + pgsql-http)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true
  $DC --profile "$prof" build $BUILD_PROGRESS archive
  $DC --profile "$prof" up -d

  wait_pg "$prof" "$svc" 60
  for _ in $(seq 1 60); do
    docker run --rm --network "$net" curlimages/curl -sf http://minio:9000/minio/health/live >/dev/null 2>&1 && break
    sleep 1
  done
  # quay.io, not Docker Hub: minio/mc hit the same "pull access denied" break as the minio/minio
  # server image did (docker-compose.yml), for the same reason -- see the comment there.
  docker run --rm --network "$net" --entrypoint sh quay.io/minio/mc -c \
    "mc alias set local http://minio:9000 minioadmin minioadmin && mc mb -p local/archive-test-bucket" >/dev/null

  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
  # One database PER FILE, cloned from a template, exactly as the main suite does. These tests used to
  # isolate themselves with begin/rollback, which stopped being possible once the fixture's
  # pgpm.transmute became a committing PROCEDURE (#275): transaction control is illegal inside an
  # explicit transaction block. Cloning gives back the isolation the rollback provided, and gives it
  # for real -- a rollback never undid anything the tests pushed to MinIO anyway.
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists pgpm_arch_tmpl" >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "create database pgpm_arch_tmpl" >/dev/null
  $DC "${px[@]}" -d pgpm_arch_tmpl -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
  $DC "${px[@]}" -d pgpm_arch_tmpl -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null
  $DC "${px[@]}" -d pgpm_arch_tmpl -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  $DC "${px[@]}" -d pgpm_arch_tmpl -v ON_ERROR_STOP=1 -q -f /repo/pgpm_archive/install.sql >/dev/null

  local an=0
  for af in tests/archive/db/*.sql; do
    local ab adb; ab="$(basename "$af")"; an=$((an + 1)); adb="pgpm_a$an"
    $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $adb" >/dev/null
    $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "create database $adb template pgpm_arch_tmpl" >/dev/null
    $DC --profile "$prof" exec -T "$svc" sh -c "pg_prove --timer -U postgres -d $adb /repo/tests/archive/db/$ab" \
      || fail=1
    $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $adb" >/dev/null
  done
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists pgpm_arch_tmpl" >/dev/null

  # The independent-reader verification below connects to `postgres`, so that database still needs the
  # extensions and both installers.
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -f /repo/pgpm_archive/install.sql >/dev/null

  # Independent-reader verification (pyarrow + DuckDB, scripts/verify_parquet*.py): runs on the
  # host against the archive service's published port (5520), not inside the container like the
  # pgTAP suite above -- these are plain psycopg2 scripts, not psql. Reuses a venv across runs
  # (only (re)installs requirements the first time) since pyarrow/DuckDB are not instant to
  # install; safe to delete .venv-verify to force a clean reinstall.
  echo "--- independent-reader verification (pyarrow + DuckDB) ---"
  if [ ! -d .venv-verify ]; then
    python3 -m venv .venv-verify
    .venv-verify/bin/pip install -q -r scripts/requirements-verify.txt
  fi
  .venv-verify/bin/python scripts/verify_parquet.py "postgresql://postgres:postgres@localhost:5520/postgres" \
    || fail=1
  .venv-verify/bin/python scripts/verify_parquet_range.py "postgresql://postgres:postgres@localhost:5520/postgres" \
    || fail=1

  echo "--- LZ77 match-finder memory guard (issue #366) ---"
  bash "$(dirname "$0")/bench/archive_lz77_memory.sh" pgpm_test-archive pgpm_lz77mem || fail=1

  echo "--- column encode memory guard (issue #368) ---"
  bash "$(dirname "$0")/bench/archive_encode_memory.sh" pgpm_test-archive pgpm_encodemem || fail=1

  echo "--- DEFLATE encoder memory guard (issue #370) ---"
  bash "$(dirname "$0")/bench/archive_deflate_memory.sh" pgpm_test-archive pgpm_deflatemem || fail=1

  $DC --profile "$prof" down -v
  if [ "$fail" -ne 0 ]; then echo "archive track: FAIL"; return 1; fi
  echo "archive track: PASS"
}

# ------------------------------------------------------------------------------------------------------
# The `perf` track: guard against data-coupled locks and data-coupled work (issues #267, #275).
#
# NOT part of the pgTAP suite, and deliberately so, for two reasons that outlive any one isolation scheme.
# The lock guards need a SECOND SESSION observing a first one mid-operation (a reader under a short
# lock_timeout while the O(rows) scan runs), and a pgTAP file is one session, so the regression they exist
# to catch would be invisible written as one. The work guards read pg_stat_all_tables scan counters, which
# are flushed at TRANSACTION END: measured, a seq scan of 20000 rows reports growth of 0 when read inside
# the same transaction and 20000 across transactions, so the sample has to be taken in a later transaction
# than the work it measures. Every tick in the harness runs in its own transaction, which is also how
# maintain drives it in production.
run_perf() {
  local prof="pg17" svc="postgres17" c="pgpm_test-17"
  $DC --profile "$prof" up -d --wait "$svc"
  psql_run "$prof" "$svc" -q -f /repo/pgpm_core/install.sql >/dev/null
  local rc=0
  bash "$(dirname "$0")/bench/regrain_perf.sh"   "$c" pgpm_perf  /repo/pgpm_core/install.sql || rc=1
  bash "$(dirname "$0")/bench/transmute_lock.sh" "$c" pgpm_perf2                              || rc=1
  bash "$(dirname "$0")/bench/transmute_cutover_order.sh" "$c" pgpm_perf11                    || rc=1
  bash "$(dirname "$0")/bench/transmute_lock_timeout.sh" "$c" pgpm_perf7                      || rc=1
  bash "$(dirname "$0")/bench/maintain_lock.sh" "$c" pgpm_perf3                              || rc=1
  bash "$(dirname "$0")/bench/restore_fk_lock.sh" "$c" pgpm_perf5                            || rc=1
  bash "$(dirname "$0")/bench/retire_detach_lock.sh" "$c" pgpm_perf6                          || rc=1
  bash "$(dirname "$0")/bench/upgrade_in_place.sh" "$c" pgpm_perf8                            || rc=1
  bash "$(dirname "$0")/bench/frontier_drought.sh" "$c" pgpm_perf9                            || rc=1
  bash "$(dirname "$0")/bench/regrain_outgoing_fk_lock.sh" "$c" pgpm_perf10                    || rc=1
  bash "$(dirname "$0")/bench/obtain_backoff_headroom.sh" "$c" pgpm_perf12                     || rc=1
  $DC --profile "$prof" down -v
  if [ "$rc" -ne 0 ]; then echo "perf track: FAIL"; return 1; fi
  echo "perf track: PASS"
}

# The `discriminate` track: prove the guards above actually catch what they exist for.
#
# A green guard is not evidence -- it is green when the defect is absent, and just as green when the
# guard never observed anything. This repo has shipped the second kind six times. bench/discriminate.sh
# rebuilds install.sql with each defect put back and requires the matching guard to FAIL. It is a
# separate track because it runs every guard a second time and so costs about double the perf track.
run_discriminate() {
  local prof="pg17" svc="postgres17" c="pgpm_test-17"
  # The one archive-scoped mutation (#366) needs the archive track's own image (pgsql-http isn't
  # in the plain core image postgres17 uses) -- brought up alongside, the same way run_archive
  # does. MinIO comes up with it (both share profiles: ["archive"] in docker-compose.yml) but
  # goes unused: the LZ77 memory guard never touches S3.
  local aprof="archive" asvc="archive" ca="pgpm_test-archive"
  $DC --profile "$prof" up -d --wait "$svc"
  $DC --profile "$aprof" build $BUILD_PROGRESS "$asvc"
  $DC --profile "$aprof" up -d
  wait_pg "$aprof" "$asvc" 60
  local rc=0
  bash "$(dirname "$0")/bench/discriminate.sh" "$c" "$ca" || rc=1
  $DC --profile "$aprof" down -v
  $DC --profile "$prof" down -v
  return "$rc"
}

# The `locktrace` track: OBSERVE a maintenance tick's lock boundaries with eBPF rather than inferring
# them from a reader probe's timeout (issue #383, phases 1 and 2).
#
# Self-contained on purpose: it runs the guard AND its mutation, rather than adding the mutation to
# the shared `discriminate` track. The guard needs eBPF, which needs a privileged container and the
# host's kernel headers -- fine on Linux and on GitHub's runners, structurally impossible on Docker
# Desktop for Mac. Folding it into `discriminate` would make that track, and so `ci`, unrunnable on a
# laptop, which #383 explicitly rules out: the deterministic pg_locks technique stays the local tool
# and tracing is a CI-time confirmation layer. Keeping the mutation in bench/mutations/ and selecting
# it with --track means it is still built, run and required to fail by the same machinery as every
# other guard's -- separated, not exempted.
#
# Not part of `ci` for the same reason. Its own workflow is #383's phase 3.
run_locktrace() {
  local prof="locktrace" svc="locktrace" c="pgpm_test-locktrace"
  echo; echo "========================================="
  echo "Lock-trace track: eBPF lock boundaries (pg17 + bench/lock_probe.py)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true
  $DC --profile "$prof" build $BUILD_PROGRESS "$svc"
  $DC --profile "$prof" up -d
  wait_pg "$prof" "$svc" 60
  local rc=0
  bash "$(dirname "$0")/bench/lock_trace.sh" "$c" pgpm_lt || rc=1
  # Green on correct code is not evidence -- the standing lesson of this repo. Build the same
  # commit-boundary defect maintain_lock.sh's mutant models, and require THIS guard to fail on it.
  bash "$(dirname "$0")/bench/discriminate.sh" --track=locktrace "$c" || rc=1
  $DC --profile "$prof" down -v
  if [ "$rc" -ne 0 ]; then echo "locktrace track: FAIL"; return 1; fi
  echo "locktrace track: PASS"
}

# The `lockview` track: gate the lock-sequence renderer's eBPF CAPTURE half (issue #398).
#
# DIFFERENT IN KIND from `locktrace`, which sits next to it and shares its container. That track
# gates pgpm's own commit boundaries, using bench/lock_probe.py as its instrument. This one asserts
# nothing about pgpm at all -- it gates the INSTRUMENT: that bench/lock_view.py still attaches, still
# filters catalogs in the kernel, still produces a capture the consumer will agree to draw, and --
# the half that matters -- still pairs an aborted lock wait with its OWN request instead of leaving
# it for the next catalog return to steal.
#
# WHY IT EXISTS AT ALL, given the renderer gates no merge and its design spec listed "No CI job"
# among its non-goals. That reasoning holds for the figure and not for the probe. Nothing ships on
# the figure, but an instrument that fabricates a grant tells its reader the confident opposite of
# the truth, and until this track there was nothing between a simplification of those twenty lines
# of BPF C and the defect coming back. The spec's Non-goals section has been amended with this
# reasoning rather than silently contradicted.
#
# Steps 3 and 4 were added after the track first shipped, and the gap they close is worth naming:
# both demos were ALREADY in this workflow's path filter, so editing either one FIRED this job,
# which then went green having never executed the file that changed. That is worse than no gate at
# all -- an absent check is visibly absent, while a green one that ran nothing reads as assurance.
# Every demo named in the filter is now actually run by the track.
#
# FOUR STEPS, and they cover different failures:
#
#   1. bench/lock_view.sh end to end over a real maintain_all() tick. Covers attach, in-kernel
#      filtering, the name snapshots and the format contract. These failures are already loud on
#      their own (an attach error is fatal and named, a missing catalog filter shows up as tens of
#      thousands of events, a malformed capture is refused outright by plot_lock_view.py), so this
#      step's value is running the whole pipeline the way a human actually would, not novel coverage.
#   2. bench/lock_timeout_pairing_demo.sh. THIS is the step that gates the silent defect, and the
#      only step here that would have caught it: the fabricated grant reported
#      {"dropped": 0, "unmatched": 0}, loaded cleanly through the consumer, and was refused by
#      nothing. Measured against a hand-reverted probe (the mutation the demo's own header
#      describes): 2 lock events instead of 1, a fabricated wait_ns of 100541273 against a 100 ms
#      lock_timeout, and unmatched 0 instead of 1 -- three of its six checks flip, while BOTH its
#      liveness witnesses stay green, so the failure is attributable to the defect rather than to a
#      fixture that quietly did nothing.
#   3. bench/lock_view_prefix_demo.sh. Gates the enlistment primer. lock_view.py enlists a backend
#      only on its FIRST touch of a target oid, so a lock that same backend took earlier in the
#      traced statement is invisible, and a truncated prefix renders as a complete sequence with no
#      refusal anywhere to catch it. It needs no mutation because it is self-discriminating by
#      construction: its case 1 runs UNPRIMED and REQUIRES the defect to reproduce against the
#      unmodified probe, so the two cases cannot both pass unless the primer is what made the
#      difference.
#   4. bench/lock_view_names_scope_demo.sh. Gates the schema-scoped managed_parent join in
#      bench/sql/lockview_names.sql: two managed parents sharing a bare relname in different schemas
#      used to fold their children onto whichever parent's row happened to read last,
#      nondeterministically. The one step here needing no eBPF -- it is a plain SQL correctness
#      check -- but it belongs in THIS track regardless, because this is the track whose path filter
#      fires when that query changes. Measured against the join reverted to bare-name-only: both
#      row-count checks go to "got 2, want 1".
#
# THE FIXTURE has to survive plot_lock_view.py's `strong` refusal, which rejects any capture carrying
# no ShareRowExclusive/Exclusive/AccessExclusive mark, on the grounds that "a tick that did nothing
# renders as a calm, correct-looking figure". So it is built to make the MEASURED tick actually drop
# a partition: retain's DROP takes ACCESS EXCLUSIVE on the parent, and that is the strong mark. This
# is deliberate, not incidental -- a fixture with nothing to do would make this track fail on its own
# setup, which is the failure shape hardest to tell apart from a real defect.
run_lockview() {
  local prof="locktrace" svc="locktrace" c="pgpm_test-locktrace" db="lv_ci"
  echo; echo "========================================="
  echo "Lock-view track: eBPF capture for the lock-sequence renderer (pg17 + bench/lock_view.py)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true
  $DC --profile "$prof" build $BUILD_PROGRESS "$svc"
  $DC --profile "$prof" up -d
  wait_pg "$prof" "$svc" 60
  local rc=0

  # matplotlib for bench/plot_lock_view.py, in its own venv (Ruling 8a). A venv rather than a bare
  # pip install because the runner's python may be PEP 668 externally-managed, where installing into
  # it is refused outright. Reused across runs; delete .venv-lockview to force a clean reinstall.
  if [ ! -d .venv-lockview ]; then
    python3 -m venv .venv-lockview
    .venv-lockview/bin/pip install -q matplotlib
  fi

  docker exec "$c" psql -U postgres -q -c "drop database if exists $db" >/dev/null
  docker exec "$c" psql -U postgres -q -c "create database $db" >/dev/null
  docker exec "$c" psql -U postgres -d "$db" -q -v ON_ERROR_STOP=1 -f /repo/pgpm_core/install.sql >/dev/null

  local lvq=(docker exec "$c" psql -U postgres -d "$db" -qtA -c)

  # A managed table whose retention will have something to drop in the measured tick. Small on
  # purpose: unlike bench/lock_trace.sh's fixture, nothing here needs a WIDE window for a probe to
  # land inside -- a trace either contains the strong mark or it does not.
  "${lvq[@]}" "create table public.lv (id bigint primary key, v text)" >/dev/null
  "${lvq[@]}" "insert into public.lv select g, 'x' from generate_series(1,100) g" >/dev/null
  "${lvq[@]}" "call pgpm.transmute('public.lv','id',100000::bigint, p_retain => 100000::bigint, p_paused => false)" >/dev/null

  # One warm-up tick, with nothing yet eligible for retention, so the MEASURED tick below is the
  # first one that drops anything.
  "${lvq[@]}" "call pgpm.maintain_all()" >/dev/null

  # Now advance the frontier past the oldest partition, so retention has a drop to make. The ceiling
  # is read back rather than assumed, since transmute builds the grid during the cutover.
  local hi
  hi=$("${lvq[@]}" "select max(hi::bigint) from pgpm.part where parent_table='public.lv'::regclass")
  "${lvq[@]}" "insert into public.lv values ($((hi-1)), 'advances past the oldest partition')" >/dev/null

  # --- step 1: the whole pipeline, end to end -----------------------------------------------------
  local out
  if out=$(bash "$(dirname "$0")/bench/lock_view.sh" "$c" "$db" 'public.lv' "call pgpm.maintain_all()" ci 2>&1); then
    echo "$out"
    case "$out" in
      *"dropped=0"*) echo "PASS  the capture reports dropped=0" ;;
      *) echo "FAIL  the capture did not report dropped=0"; rc=1 ;;
    esac
    case "$out" in
      *"unmatched=0"*) echo "PASS  the capture reports unmatched=0" ;;
      *) echo "FAIL  the capture did not report unmatched=0"; rc=1 ;;
    esac
  else
    echo "$out"
    echo "FAIL  bench/lock_view.sh did not complete; see the refusal or error above"
    rc=1
  fi

  # --- step 2: the pairing proof, which is the half that discriminates ----------------------------
  if bash "$(dirname "$0")/bench/lock_timeout_pairing_demo.sh" "$c" "$db"; then
    echo "PASS  the request/return pairing proof holds"
  else
    echo "FAIL  the request/return pairing proof did not hold"
    rc=1
  fi

  # --- step 3: the enlistment primer, against a live capture --------------------------------------
  if bash "$(dirname "$0")/bench/lock_view_prefix_demo.sh" "$c" "$db"; then
    echo "PASS  the enlistment primer closes the prefix-loss gap"
  else
    echo "FAIL  the enlistment primer proof did not hold"
    rc=1
  fi

  # --- step 4: the schema-scoped name fold (plain SQL; the one step needing no eBPF) ---------------
  # Given its OWN database, never $db: this demo creates and DROPS the database it is handed, so
  # passing it the track's fixture database would destroy what steps 1 to 3 depend on.
  if bash "$(dirname "$0")/bench/lock_view_names_scope_demo.sh" "$c" lv_scope_ci; then
    echo "PASS  the managed_parent join stays scoped by the parent's own schema"
  else
    echo "FAIL  the schema-scoped name fold proof did not hold"
    rc=1
  fi

  $DC --profile "$prof" down -v
  if [ "$rc" -ne 0 ]; then echo "lockview track: FAIL"; return 1; fi
  echo "lockview track: PASS"
}

if [ "$TRACK" = "perf" ]; then
  run_perf
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "locktrace" ]; then
  run_locktrace
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "lockview" ]; then
  run_lockview
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "discriminate" ]; then
  run_discriminate
  echo; echo "All requested tests passed."
  exit 0
fi

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

if [ "$TRACK" = "archive" ]; then
  run_archive
  echo; echo "All requested tests passed."
  exit 0
fi

# `ci`: everything the CI workflows run, in one invocation, so "green locally" can mean the same thing
# as "green in CI". Every track runs to completion rather than stopping at the first failure, because
# when a core change breaks several you want the whole list.
#
# Each track is a CHILD INVOCATION of this script, not a direct call to its run_* function. Two reasons.
# `cmd || handler` disables errexit for the whole of cmd, including inside a function it calls, and
# several of these functions rely on `set -e` to abort on a failed install step -- so calling them
# directly under `||` would let a broken install run on and report a worse failure, or none. A child
# process re-runs `set -euo pipefail` for itself and keeps that intact. It is also exactly how CI
# invokes them, one track per job, which is the behaviour this target exists to reproduce.
if [ "$TRACK" = "ci" ]; then
  # A string, not an array: macOS ships bash 3.2, where expanding an EMPTY array under `set -u` is an
  # "unbound variable" error -- so the all-passed path would be the one that broke.
  ci_failed=""
  ci_skipped=""
  for v in 15 16 17 18; do "$0" "$v" || ci_failed="$ci_failed pg$v"; done
  for t in timescale observe archive perf discriminate; do
    "$0" "$t" || ci_failed="$ci_failed $t"
  done

  # locktrace needs eBPF: a privileged container AND the host's own kernel headers. That is fine on
  # Linux and on GitHub's runners, and structurally impossible on Docker Desktop for Mac, whose
  # linuxkit VM publishes no headers for its bespoke kernel (#383, confirmed structurally rather than
  # as a missing package). So it runs wherever it can run, and anywhere else it is reported SKIPPED --
  # never silently, and never as passed.
  #
  # The condition is the KERNEL ALONE, deliberately: not a probe for debugfs, headers or privileged
  # containers. A Linux box that cannot actually trace should FAIL here, loudly, because "a guard this
  # never actually ran is unverified" is the rule the rest of this harness already runs on, and a
  # prerequisite check would quietly convert a broken setup into a green run -- the precise failure
  # this repo keeps shipping. Non-Linux is the one case where the track is impossible rather than
  # broken, so it is the one case that skips.
  if [ "$(uname -s)" = "Linux" ]; then
    "$0" locktrace || ci_failed="$ci_failed locktrace"
    "$0" lockview  || ci_failed="$ci_failed lockview"
  else
    ci_skipped=" locktrace and lockview (need Linux; eBPF cannot run on $(uname -s))"
  fi

  echo; echo "========================================="
  if [ -z "$ci_failed" ]; then
    if [ -n "$ci_skipped" ]; then
      # Deliberately NOT folded into the PASS line's meaning: this run did not verify that track, and
      # saying so plainly is the whole point of reporting a skip at all.
      echo "ci: PASS, except SKIPPED --$ci_skipped"
      echo "    Those tracks were NOT verified on this machine. CI does run them on Linux"
      echo "    (.github/workflows/locktrace.yml and lockview.yml), so a PR still covers them."
    else
      echo "ci: PASS (every track CI runs)"
    fi
    echo; echo "All requested tests passed."
    exit 0
  fi
  echo "ci: FAIL --$ci_failed"
  exit 1
fi

if [ "$VERSION" = "all" ]; then
  for v in 15 16 17 18; do run_version "$v"; done
else
  run_version "$VERSION"
fi
echo; echo "All requested tests passed."

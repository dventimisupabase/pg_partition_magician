#!/usr/bin/env bash
# Prove bench/lock_view.sh's enlistment primer closes the prefix-loss gap in bench/lock_view.py
# (issue #392 review, finding 1). RUN BY CI as step 3 of the `lockview` track (./test.sh lockview,
# .github/workflows/lockview.yml). The assertion needs a live eBPF capture, so it cannot live in
# bench/lock_view_selftest.py, which runs with no eBPF, no container and no Linux, by design.
#
# Until that wiring existed, this file sat in the workflow's path filter WITHOUT being executed by
# it: editing this demo fired the job, which then went green having never run the file that changed.
# An absent check is visibly absent; a green one that ran nothing reads as assurance.
#
# THE DEFECT
#
# bench/lock_view.py enlists a backend into `watched` only once that backend touches one of the
# enlisted oids. Any lock that SAME backend took EARLIER in the same statement is invisible: `LOCK
# other; LOCK target;`, traced as one statement against an unenlisted backend, loses `other`
# outright -- nothing in the probe or bench/plot_lock_view.py refuses on it, so a truncated prefix
# renders as a complete sequence.
#
# THE FIX (bench/lock_view.sh) primes enlistment: immediately before the traced SQL, it issues a
# trivial `select 1 from <first enlisted relation> limit 0` as its own `-c`, in the SAME
# `docker exec ... psql -c ... -c ...` invocation (one backend, one pid). The reviewer's suggested
# alternative -- identify the backend via pg_backend_pid() before executing the statement -- was
# rejected: pg_backend_pid() reports the pid inside the CONTAINER's namespace, eBPF reports the pid
# inside the kernel's INITIAL namespace, and they do not agree (measured on this fixture: 145
# against 71,504), so nothing here or in bench/lock_view.py ever joins on it.
#
# WHAT THIS SCRIPT DOES
#
# Enlists ONLY `lv_prefix_target`'s oid (a real bench/lock_view.sh run enlists every relation
# named on its command line; this reproduces the single-relation shape the finding names) and
# traces `LOCK lv_prefix_other; LOCK lv_prefix_target;` as one statement, twice, against the SAME
# unmodified probe:
#
#   1. UNPRIMED -- reproduces the defect directly: `lv_prefix_other`'s lock is expected to be
#      MISSING from the capture, because the backend is not yet watched when it takes that lock.
#   2. PRIMED -- exactly what bench/lock_view.sh now issues: `lv_prefix_other`'s lock is expected
#      to be PRESENT, because the primer's own touch of the target enlists the backend before the
#      traced statement runs at all.
#
# WHAT TO LOOK FOR
#
# PASS on both checks. The first one's PASS IS the discrimination proof: it reproduces the defect
# this fix closes, against the identical, unmodified bench/lock_view.py the fix's own runs use --
# the fix lives entirely in how bench/lock_view.sh invokes the traced SQL, not in the probe.
#
# USAGE
#
#   bench/lock_view_prefix_demo.sh <container> <db>
#   bench/lock_view_prefix_demo.sh pgpm_test-locktrace lv_prefix
#
# PREREQUISITES
#
#   The locktrace compose profile, up and healthy: docker compose --profile locktrace up -d
#   <db> must already exist in that container (createdb <db> first if it does not).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
OTHER=public.lv_prefix_other
TARGET=public.lv_prefix_target
EVENTS=/tmp/pgpm_prefix_demo.jsonl
PLOG=/tmp/pgpm_prefix_demo.log
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-70s %s\n' "$1" "$2"
  else printf 'FAIL  %-70s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

if ! docker exec "$C" python3 -c 'import bcc' 2>/dev/null; then
  echo "error: $C has no bcc. Start the locktrace service:" >&2
  echo "  docker compose --profile locktrace up -d" >&2
  exit 1
fi

q "drop table if exists $OTHER" >/dev/null
q "drop table if exists $TARGET" >/dev/null
q "create table $OTHER (id int)" >/dev/null
q "create table $TARGET (id int)" >/dev/null
TARGET_OID=$(q "select '$TARGET'::regclass::oid")
OTHER_OID=$(q "select '$OTHER'::regclass::oid")
[ -n "$TARGET_OID" ] && [ -n "$OTHER_OID" ] || { echo "error: fixture tables did not resolve to oids" >&2; exit 1; }

SQL="LOCK TABLE $OTHER IN ACCESS SHARE MODE; LOCK TABLE $TARGET IN ACCESS SHARE MODE;"

# Runs one capture, watching ONLY $TARGET_OID (matching a single-relation `bench/lock_view.sh ...
# "$TARGET" "$SQL"` invocation), with or without the primer. Prints "true" or "false" on stdout:
# whether $OTHER_OID's lock made it into the capture.
run_case() {
  local primed="$1"
  docker exec "$C" sh -c "rm -f $EVENTS $PLOG"
  docker exec -d "$C" sh -c "python3 /repo/bench/lock_view.py $TARGET_OID $EVENTS > $PLOG 2>&1"

  local ready=false
  for _ in $(seq 1 30); do
    if docker exec "$C" grep -q '^READY' "$PLOG" 2>/dev/null; then ready=true; break; fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    echo "error: probe never became READY" >&2
    docker exec "$C" cat "$PLOG" >&2
    docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
    echo "unknown"
    return 1
  fi

  if [ "$primed" = "true" ]; then
    docker exec "$C" psql -U postgres -d "$DB" -qtA \
      -c "select 1 from $TARGET limit 0" -c "$SQL" >/dev/null 2>&1
  else
    docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$SQL" >/dev/null 2>&1
  fi

  docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
  for _ in $(seq 1 30); do
    docker exec "$C" pgrep -f lock_view.py >/dev/null 2>&1 || break
    sleep 1
  done

  # A trailing comma pins the match to the exact oid field, not a numeric prefix of it
  # (json.dumps's default separators put a space after the colon and a comma after the value).
  if docker exec "$C" sh -c "grep -q '\"oid\": $OTHER_OID,' $EVENTS"; then
    echo true
  else
    echo false
  fi
}

echo "case 1: UNPRIMED (reproduces the pre-fix defect against the unmodified probe)"
unprimed_seen=$(run_case false)
check "unprimed: other's lock is captured (expected MISSING -- this IS the defect)" \
      "$unprimed_seen" "false"

echo
echo "case 2: PRIMED (bench/lock_view.sh's actual fix)"
primed_seen=$(run_case true)
check "primed: other's lock is captured (the fix closes the gap)" "$primed_seen" "true"

q "drop table if exists $OTHER" >/dev/null
q "drop table if exists $TARGET" >/dev/null

if [ "$fail" -ne 0 ]; then echo "lock_view_prefix_demo: FAIL"; exit 1; fi
echo "lock_view_prefix_demo: PASS"

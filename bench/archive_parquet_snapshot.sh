#!/usr/bin/env bash
# Run tests/archive/db/15_parquet_single_snapshot_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant, and then read the racy
# files that test leaves behind with an independent Parquet reader.
#
# WHY A WRAPPER EXISTS AT ALL. Test 15 is a plain pgTAP file and the archive track already runs it, so
# on correct code the first half of this script adds nothing. What it adds is the standing proof that
# the file DISCRIMINATES: its assertions are identities ("the racy file is byte-identical to a
# single-snapshot encode") paired with liveness witnesses, and a file that never raced anything would
# also find its racy encode equal to the quiescent one. That proof was first obtained by hand, once,
# against the pre-#462 code (8000 of 8000 rows misaligned); pointing the same file at a mutant every
# CI run is what keeps it from decaying into a commit message.
#
# The second half is what the file cannot do from inside the database: pyarrow, a reader that shares
# no code with the writer, reads each racy file back and asserts id = tag on EVERY row, which is the
# user-visible property #462 is about (a well-formed file whose tags belong to the neighbouring rows).
# The venv is the one run_archive builds for scripts/verify_parquet*.py; under `./test.sh
# discriminate` it may not exist yet, so it is created here the same way. No pyarrow is a FAIL, not a
# skip: a reader that did not run verified nothing.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   parquet_per_column_statements -- archive._pq_snapshot's temp TABLE becomes a temp VIEW over the
#                                    live relation and its row count a separate count(*), so every
#                                    per-column read goes back to the relation under a snapshot of
#                                    its own: the pre-#462 read exactly
#
# Usage: archive_parquet_snapshot.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove + dblink) AND MinIO on the same compose
# network: the test's strategy-path half PUTs through archive._encode_upload_parquet and fetches the
# object back. run_archive creates the bucket before any test runs; run_discriminate does not, so the
# bucket is created here too, idempotently and the same way (a SigV4 PUT from the curl image; 200 is
# created, 409 is already there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file
# through the read-only /repo mount (/repo/.claude/worktrees/<name>/tests/...), the same way $3
# points it at a mutant; CI and discriminate.sh never set it.
TEST_FILE="${PGPM_SNAPSHOT_TEST_FILE:-/repo/tests/archive/db/15_parquet_single_snapshot_test.sql}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results"       # gitignored
NET="${PGPM_TEST_NET:-pgpm_test_net}"
mkdir -p "$OUT"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

# --- MinIO: ready, and the bucket the fixtures point at exists ------------------------------------
ready=""
for _ in $(seq 1 60); do
  if docker run --rm --network "$NET" curlimages/curl -sf http://minio:9000/minio/health/cluster >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  printf 'FAIL  %-58s %s\n' "MinIO reported ready (/minio/health/cluster)" "not within 60 s"
  exit 1
fi
code=$(docker run --rm --network "$NET" curlimages/curl -s -o /dev/null -w '%{http_code}' \
         --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin \
         -X PUT http://minio:9000/archive-test-bucket) || code="curl exit $?"
if [ "$code" != 200 ] && [ "$code" != 409 ]; then
  printf 'FAIL  %-58s %s\n' "the MinIO bucket exists" "PUT returned $code"
  exit 1
fi

# --- the database: fixtures, core, and the archive module under test ------------------------------
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the archive fixtures installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ARCHIVE_INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the archive module under test installed" "$ARCHIVE_INSTALL"
  fail=1
fi

# --- half 1: the pgTAP file, which builds the races and asserts identity from inside --------------
if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`. The file's
  # own diag lines (which encode ran when, and which quiescent encode the racy file matched) are the
  # explanation a red run on a runner nobody can log into would otherwise lack.
  echo "$out" | grep -E '^(not )?ok [0-9]+ -|^# (range|plain|strategy):' | sed 's/^/    /' | head -40
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell us apart from a real failure is a run that never reached the database at all, and
  # here that matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the
  # defect", so a harness broken enough to fail against everything would be reported as proving the
  # mutation. Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the single-snapshot assertions hold" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the single-snapshot assertions hold" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

# --- half 2: an independent reader, on the racy files the pgTAP half left behind -----------------
PY="$ROOT/.venv-verify/bin/python"
if [ ! -x "$PY" ]; then
  python3 -m venv "$ROOT/.venv-verify" >/dev/null 2>&1 \
    && "$ROOT/.venv-verify/bin/pip" install -q -r "$ROOT/scripts/requirements-verify.txt" >/dev/null 2>&1
fi
if ! "$PY" -c 'import pyarrow.parquet' >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the independent reader (pyarrow) is available" "no"
  fail=1
else
  for label in range_racy plain_racy upload_racy; do
    hex="$OUT/pq_snapshot_$label.hex"
    q -d "$DB" -Atq -c "select encode(bytes, 'hex') from t15.enc where label = '$label'" > "$hex" 2>/dev/null
    if [ ! -s "$hex" ]; then
      printf 'FAIL  %-58s %s\n' "$label: the racy file was produced" "no bytes in t15.enc"
      fail=1; continue
    fi
    if ! "$PY" - "$hex" "$label" <<'PYEOF'
import io
import sys

import pyarrow.parquet as pq

raw = bytes.fromhex(open(sys.argv[1]).read().strip())
label = sys.argv[2]
pf = pq.ParquetFile(io.BytesIO(raw))
t = pf.read()
ids = t.column("id").to_pylist()
tags = t.column("tag").to_pylist()
bad = [(i, g) for i, g in zip(ids, tags) if i != g]
ok = True


def check(name, detail, cond):
    global ok
    print(("PASS  " if cond else "FAIL  ") + f"{label + ': ' + name:<58} {detail}")
    ok = ok and cond


# Liveness first: an empty file would satisfy both negatives below.
check("pyarrow read rows at all", f"{t.num_rows} rows", t.num_rows > 0)
check("footer num_rows is the row count read", f"{pf.metadata.num_rows} vs {t.num_rows}",
      pf.metadata.num_rows == t.num_rows)
check("id = tag on every row",
      f"{len(bad)} of {t.num_rows} misaligned" + (f", first {bad[:3]}" if bad else ""), not bad)
sys.exit(0 if ok else 1)
PYEOF
    then fail=1; fi
  done
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"

#!/usr/bin/env bash
# Run tests/archive/db/16_archive_object_key_identity_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 16 is a plain pgTAP file and the archive track already runs it, so
# on correct code this script adds nothing. What it adds is the standing proof that the file
# DISCRIMINATES. Its central assertions are negatives ("the two ledger rows do not name one object")
# and identities ("the object at the [-10000, 0) key holds exactly ids -10000..-1"), each paired with a
# liveness witness that both partitions existed, held exactly the rows named, and were archived by the
# tick; but nothing re-checks that those assertions would go red if the stem went back to digits only.
# That was first seen by hand, once, against the pre-#502 code (the [-10000, 0) key holding the ten
# [10000, 20000) rows). Pointing the same file at a mutant every CI run keeps it from decaying into a
# commit message.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_object_key_digits_only -- archive._object_stem projects every native lo onto its digits
#                                     again, the id kind included, so chunk lo -10000 and chunk lo
#                                     10000 share one key and the second PUT of a tick overwrites the
#                                     first: the pre-#502 key exactly
#
# Usage: archive_object_key.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same compose network: the
# file PUTs through both transports and fetches the objects back. run_archive creates the bucket before
# any test runs; run_discriminate does not, so the bucket is created here too, idempotently and the same
# way (a SigV4 PUT from the curl image; 200 is created, 409 is already there), after waiting for MinIO
# to report ready. PGPM_OBJECT_KEY_TEST_FILE overrides the test file's path inside the container, for
# running from a worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
TEST_FILE="${PGPM_OBJECT_KEY_TEST_FILE:-/repo/tests/archive/db/16_archive_object_key_identity_test.sql}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
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

# --- the pgTAP file, which drives both transports and asserts key identity from inside --------------
if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this runs on the HOST, and BSD sed has no `\|`. The file's own
  # diag lines (what the object at each key held) are the explanation a red run on a runner nobody
  # can log into would otherwise lack.
  echo "$out" | grep -E '^not ok [0-9]+ -|^# (ndjson|parquet):' | sed 's/^/    /' | head -40
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell us apart from a real failure is a run that never reached the database at all, and
  # here that matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the
  # defect", so a harness broken enough to fail against everything would be reported as proving the
  # mutation. Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "every chunk of a table uploads to its own object key" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "every chunk of a table uploads to its own object key" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"

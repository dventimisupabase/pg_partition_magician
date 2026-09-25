#!/usr/bin/env bash
# Run tests/archive/db/16_encode_partition_tz_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 16 is a plain pgTAP file and the archive track already runs it, so
# on correct code this script adds nothing. What it adds is the standing proof that the file
# DISCRIMINATES. Its claim is an identity ("the object holds ids 1, 2 and 3") paired with witnesses
# that the grid's zone and the session's differ and that the two renderings of the chunk select
# different rows on the column; a fixture whose zones happened to agree, or a bucket still holding a
# good object from an earlier run, would satisfy the identity on broken code too. Pointing the same
# file at a mutant every CI run is what keeps that proof from decaying into a commit message.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_encode_no_partition_tz -- config.partition_tz dropped from all four pgpm._encode calls in
#                                     archive._encode_upload_ndjson_single and _encode_upload_parquet,
#                                     so the chunk's literals fall back to UTC wall time: pre-#501 exactly
#
# Usage: archive_encode_partition_tz.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same compose network: both
# strategies PUT their object and the test fetches it back. run_archive creates the bucket before any
# test runs; run_discriminate does not, so the bucket is created here too, idempotently and the same
# way (a SigV4 PUT from the curl image; 200 is created, 409 is already there), after waiting for MinIO.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file
# through the read-only /repo mount, the same way $3 points it at a mutant; CI never sets it.
TEST_FILE="${PGPM_ENCODE_TZ_TEST_FILE:-/repo/tests/archive/db/16_encode_partition_tz_test.sql}"
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

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^(not )?ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell us apart from a real failure is a run that never reached the database at all, and
  # here that matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the
  # defect", so a harness broken enough to fail against everything would be reported as proving the
  # mutation. Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the chunk is read in partition_tz from any session" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the chunk is read in partition_tz from any session" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"

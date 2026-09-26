#!/usr/bin/env bash
# Run tests/archive/db/16_to_s3_compress_test.sql against an ARBITRARY copy of pgpm_archive/install.sql,
# so bench/discriminate.sh can point it at a mutant, and then inflate the objects that test leaves
# behind with a gzip decoder this module does not have.
#
# WHY A WRAPPER EXISTS AT ALL. Test 16 is a plain pgTAP file and the archive track already runs it, so
# on correct code the first half of this script adds nothing. What it adds is the standing proof that
# the file DISCRIMINATES: several of its assertions are negatives ("nothing at the plain key"), and a
# negative is also satisfied by an export that never happened. The file pins its setup with witnesses,
# but nothing re-checks that those witnesses would fail if the flag stopped being read. Pointing the
# same file at a mutant every CI run is what checks that.
#
# The second half is what the file cannot do from inside the database. The single-PUT object is one
# gzip member and the file checks its trailer (CRC-32 and length of the NDJSON) from SQL, but the
# multipart object is a CONCATENATION of members, one per text chunk, and only a decoder can say that
# the concatenation inflates to exactly the partition's rows. Python's zlib walks the stream one
# member at a time (so the member count is known), Python's gzip inflates it again as a second reader,
# and the rows are then compared by identity (every id, in order) and by digest against what the file
# recorded as expected. No python3 is a FAIL, not a skip: a reader that did not run verified nothing.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   to_s3_compress_unread -- archive.to_s3 reads archive.config.compress as false again, the pre-#520
#                            shape exactly: plain NDJSON at <prefix><child>.ndjson whatever the flag
#                            says, and nothing at the documented <prefix><child>.ndjson.gz
#
# Usage: archive_to_s3_compress.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same compose network: every
# export in the file is a real PUT. run_archive creates the bucket before any test runs;
# run_discriminate does not, so it is created here too, idempotently and the same way (a SigV4 PUT from
# the curl image; 200 is created, 409 is already there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
TEST_FILE="${PGPM_TO_S3_COMPRESS_TEST_FILE:-/repo/tests/archive/db/16_to_s3_compress_test.sql}"
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

# --- half 1: the pgTAP file, which exports and asserts what it can from inside -------------------
if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -40
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell us apart from a real failure is a run that never reached the database at all, and
  # here that matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the
  # defect", so a harness broken enough to fail against everything would be reported as proving the
  # mutation. Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "archive.to_s3 honours archive.config.compress" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "archive.to_s3 honours archive.config.compress" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

# --- half 2: an independent decoder, on the objects the pgTAP half left behind -------------------
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the independent decoder (python3) is available" "no"
  fail=1
elif [ "$fail" = 0 ] || q -d "$DB" -Atq -c "select 1 from t16.obj limit 1" 2>/dev/null | grep -q 1; then
  for label in single multipart; do
    hex="$OUT/to_s3_compress_$label.hex"
    ids="$OUT/to_s3_compress_$label.ids"
    q -d "$DB" -Atq -c "select encode(bytes, 'hex') from t16.obj where label = '$label'" > "$hex" 2>/dev/null
    q -d "$DB" -Atq -c "select array_to_string(expected_ids, ',') from t16.obj where label = '$label'" > "$ids" 2>/dev/null
    want_md5=$(q -d "$DB" -Atq -c "select expected_md5 from t16.obj where label = '$label'" 2>/dev/null)
    if [ ! -s "$hex" ]; then
      printf 'FAIL  %-58s %s\n' "$label: the object was recorded" "no bytes in t16.obj"
      fail=1; continue
    fi
    if ! python3 - "$hex" "$ids" "$want_md5" "$label" <<'PYEOF'
import gzip
import hashlib
import json
import sys
import zlib

raw = bytes.fromhex(open(sys.argv[1]).read().strip())
want_ids = [int(x) for x in open(sys.argv[2]).read().strip().split(",") if x]
want_md5 = sys.argv[3]
label = sys.argv[4]
ok = True


def check(name, detail, cond):
    global ok
    print(("PASS  " if cond else "FAIL  ") + f"{label + ': ' + name:<58} {detail}")
    ok = ok and cond


# Walk the stream one member at a time, so the member count is known: the gzip module would read the
# concatenation silently. A stream that is not gzip at all (a 404 body, plain NDJSON) fails here.
members = 0
out = bytearray()
rest = raw
err = ""
try:
    while rest:
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        out += d.decompress(rest)
        if not d.eof:
            break
        members += 1
        rest = d.unused_data
except zlib.error as e:
    err = f": {e}"
check("every member inflates to its end", f"{members} member(s), {len(rest)} byte(s) left{err}",
      not err and members >= 1 and not rest)
if not err:
    # a second reader that shares nothing with the walk above
    check("the gzip module reads the whole stream to the same bytes", f"{len(out)} bytes",
          gzip.decompress(raw) == bytes(out))
check("the member count fits the path", f"{members} member(s)",
      members >= 2 if label == "multipart" else members == 1)
got_md5 = hashlib.md5(bytes(out)).hexdigest()
check("the inflated bytes are exactly the partition's NDJSON", f"md5 {got_md5} vs {want_md5}", got_md5 == want_md5)
lines = [line for line in bytes(out).decode("utf-8", errors="replace").split("\n") if line]
ids = []
for line in lines:
    try:
        ids.append(json.loads(line)["id"])
    except (ValueError, KeyError, TypeError):
        break
# Liveness first: an empty stream would satisfy an identity check against an empty expectation.
check("LIVENESS: rows were read at all", f"{len(ids)} row(s), {len(want_ids)} expected", len(ids) > 0 and len(want_ids) > 0)
first_diff = next((i for i, (a, b) in enumerate(zip(ids, want_ids)) if a != b), min(len(ids), len(want_ids)))
check("the ids are the partition's, each once, in control order",
      f"{len(ids)} vs {len(want_ids)}" + ("" if ids == want_ids else f", first difference at line {first_diff}"),
      ids == want_ids)
sys.exit(0 if ok else 1)
PYEOF
    then fail=1; fi
  done
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"

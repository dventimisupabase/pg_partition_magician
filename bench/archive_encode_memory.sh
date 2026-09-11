#!/usr/bin/env bash
# Guard archive._pq_encode_column_data's memory cost against holding two full-size copies of a
# column at once (issue #368).
#
# THE BAR: encoding one column must cost roughly the size of its own output, not several times the
# raw column size. The old implementation fetched the whole column into an array_agg, then
# re-aggregated it a SECOND time (string_agg or array_agg again, over unnest(...) with ordinality)
# to derive the definition-levels presence bitmap and the PLAIN-encoded payload -- both copies
# alive at overlapping times, plus each aggregate's own internal doubling-growth overhead. Measured
# at ~6x the raw column size in peak RSS on a large text column (issue #368's own methodology);
# the fix queries the source relation directly, once, with two aggregates sharing the same ORDER BY
# instead of a shared intermediate array, so nothing needs the whole column resident as one array
# value. This calls archive._pq_encode_column_data directly (not the full to_parquet pipeline), so
# it isolates the encode step #368 is about, independent of #366's already-fixed compression cost
# (bench/archive_lz77_memory.sh covers that one).
#
# The unit of observation is SERVER-SIDE (docker exec cat /proc/<backend pid>/status), not a psql
# round-trip per sample -- see bench/archive_lz77_memory.sh's own note on ~100ms docker exec cost
# vs a narrow window. The default fixture (200,000 rows x 5,120 bytes, ~1GB raw) is sized so the
# encode call itself runs a few seconds, comfortably wider than a docker exec sample.
#
# Usage: archive_encode_memory.sh <container> <db> [archive install.sql]
# The archive install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy
# instead (with the old array_agg -> unnest -> string_agg pattern put back for the text branch),
# to prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
ROWS=${ROWS:-200000}
PAYLOAD_BYTES=${PAYLOAD_BYTES:-5120}   # matches issue #366/#368's own production-shaped fixture
RAW_KB=$((ROWS * PAYLOAD_BYTES / 1024))
# 3.4x raw: calibrated against repeated runs of both implementations at this fixture size -- the
# fix's peak stayed in the 1.2x-2.8x range, the pre-#368 array_agg -> unnest -> string_agg pattern
# in the 4.1x-6.1x range. This sits in the gap between them, not at either edge.
MAX_PEAK_KB=${MAX_PEAK_KB:-$((RAW_KB * 34 / 10))}
fail=0

check() { # <label> <actual> <predicate-description-already-evaluated: 0|1>
  if [ "$3" = "1" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s %s\n' "$1" "$2"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -c "create extension if not exists http; create extension if not exists pgcrypto;" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ARCHIVE_INSTALL" >/dev/null

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
q "create table public.encode_bench (id bigint primary key, payload text)" >/dev/null
q "insert into public.encode_bench
     select g, rpad('row ' || g || ': ', $PAYLOAD_BYTES, 'The quick brown fox jumps over the lazy dog. ')
     from generate_series(1, $ROWS) g" >/dev/null
q "vacuum analyze public.encode_bench" >/dev/null

LOG=$(mktemp)
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "set client_min_messages = warning" \
  -c "select pg_backend_pid()" \
  -c "select pg_sleep(0.3)" \
  -c "select length(archive._pq_encode_column_data('public.encode_bench','payload','text',false))" \
  -c "select 'marker_encode_done'" \
  > "$LOG" 2>&1 &
BG=$!

PID=""
for _ in $(seq 1 200); do
  PID=$(grep -Eo '^[0-9]+$' "$LOG" 2>/dev/null | head -n1)
  [ -n "$PID" ] && break
  sleep 0.1
done

peak=0
n=0
if [ -n "$PID" ]; then
  while kill -0 "$BG" 2>/dev/null; do
    rss=$(docker exec "$C" sh -c "grep VmRSS /proc/$PID/status 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
    if [ -n "${rss:-}" ]; then
      n=$((n+1))
      [ "$rss" -gt "$peak" ] && peak=$rss
    fi
    sleep 0.15
  done
fi
wait "$BG"

echo "--- backend $PID: peak RSS during encode (KB) ---"
printf 'raw_input=%sKB peak=%s (n=%s)\n' "$RAW_KB" "$peak" "$n"
cat "$LOG"

# Liveness witnesses first: a probe that sampled nothing, or a call that silently failed, would
# otherwise let the bound below pass vacuously.
check "the probe found the backend pid"      "$PID"  "$([ -n "$PID" ] && echo 1 || echo 0)"
check "the encode call was actually sampled" "n=$n"  "$([ "$n" -gt 0 ] && echo 1 || echo 0)"
check "the encode call completed"            "$(grep -c 'marker_encode_done' "$LOG")" \
      "$([ "$(grep -c 'marker_encode_done' "$LOG")" = "1" ] && echo 1 || echo 0)"

# The bar itself: encoding costs roughly the output size, not several full copies of the input.
check "peak RSS stays bounded (<= ${MAX_PEAK_KB}KB, raw=${RAW_KB}KB)" "${peak}KB" \
      "$([ "$peak" -le "$MAX_PEAK_KB" ] && echo 1 || echo 0)"

exit "$fail"

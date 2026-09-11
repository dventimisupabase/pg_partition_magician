#!/usr/bin/env bash
# Guard the DEFLATE encoders' memory cost on POORLY-COMPRESSIBLE input against #370: production
# hit `invalid memory alloc request size 1468780843` archiving a prompts."PromptRunLog" chunk at
# archive_byte_budget=256MB.
#
# THE BAR: encoding near-random input (few or no LZ77 matches, close to one token per output byte
# -- the worst case for token-count-scaled memory, and the shape Boardy's JSONB prompt/model-output
# blobs actually have) must cost roughly the size of the output, not scale with token count times a
# large constant. The old archive._pq_deflate_encode_dynamic kept six parallel int4[] arrays (one
# element per LZ77 token, retained for the whole call) plus a v_bytes int4[] appended one element
# per OUTPUT byte, hex-round-tripped at the end -- archive._pq_deflate_encode (the fixed-Huffman
# path, no current call site) carries the same v_bytes/hex-round-trip pattern. On a near-random
# payload, token count approaches payload size, so those arrays could reach Postgres's ~1GB
# single-allocation ceiling well before the raw payload did. Measured directly (this guard's own
# fixture, 15,000,000 bytes of near-random input): archive._pq_deflate_encode_dynamic peaked at
# 1,263,348-1,294,264 KB RSS pre-#370 vs 363,568 KB post-#370; archive._pq_deflate_encode
# (fixed-Huffman, no current call site, but carries the identical v_bytes/hex-round-trip pattern,
# just not the six token arrays) peaked at 533,604 KB pre-#370 vs 344,260 KB post-#370. Both
# functions are called directly (not the full to_parquet pipeline), isolating the encode step from
# #366's already-fixed LZ77 match-finding cost (bench/archive_lz77_memory.sh covers that one) and
# from #368's column-encode cost (bench/archive_encode_memory.sh). Directly re-running the exact
# incident scale (268,435,456 bytes, matching Boardy's archive_byte_budget=256MB) reproduces the
# original error verbatim on pre-#370 code ("invalid memory alloc request size 1085997440" at the
# same v_dist_sym[v_k] := ... assignment production hit) and succeeds post-#370 -- see issue #370
# for that evidence; this guard uses a much smaller fixture so CI stays fast.
#
# The payload is built via `string_agg(gen_random_bytes(1024), ''::bytea)` over generate_series --
# gen_random_bytes caps at 1024 bytes per call, so many small calls are aggregated into one bytea
# via a real aggregate (not a growing array), matching this repo's own array-growth doctrine.
#
# The unit of observation is SERVER-SIDE (docker exec cat /proc/<backend pid>/status) -- see
# bench/archive_lz77_memory.sh's note on ~100ms docker exec cost vs a narrow window; at this
# fixture size the encode call runs for several seconds, comfortably wider than a docker exec
# sample.
#
# Usage: archive_deflate_memory.sh <container> <db> [archive install.sql]
# The archive install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy
# instead (with the old six-array + v_bytes int4[]/hex-round-trip pattern put back), to prove this
# guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
NBYTES=${NBYTES:-15000000}   # near-random payload size; see header for the measured old-vs-new split
NCHUNKS=$(( (NBYTES + 1023) / 1024 ))
# ~450 MiB: comfortably above the fix's measured peaks (~344-364 MB at this fixture size, both
# functions) and comfortably below either pre-#370 pattern's measured peak (~534 MB fixed, ~1.26-
# 1.29 GB dynamic) -- calibrated against real runs of both implementations at this exact fixture
# size, not a formula (see header), and picked so BOTH functions' checks independently discriminate
# a regression back to either old pattern, not just the larger (dynamic) one.
MAX_PEAK_KB=${MAX_PEAK_KB:-460000}
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

run_one() { # <label> <function name>
  local label="$1" fn="$2"
  local log pid peak n
  log=$(mktemp)
  docker exec "$C" psql -U postgres -d "$DB" -qtA \
    -c "set client_min_messages = warning" \
    -c "select pg_backend_pid()" \
    -c "select pg_sleep(0.3)" \
    -c "do \$\$
declare v_payload bytea; v_len bigint;
begin
  v_payload := (select string_agg(gen_random_bytes(1024), ''::bytea) from generate_series(1, $NCHUNKS));
  v_len := length($fn(v_payload));
end;
\$\$;" \
    -c "select 'marker_${label}_done'" \
    > "$log" 2>&1 &
  local bg=$!

  pid=""
  for _ in $(seq 1 200); do
    pid=$(grep -Eo '^[0-9]+$' "$log" 2>/dev/null | head -n1)
    [ -n "$pid" ] && break
    sleep 0.1
  done

  peak=0; n=0
  if [ -n "$pid" ]; then
    while kill -0 "$bg" 2>/dev/null; do
      local rss
      rss=$(docker exec "$C" sh -c "grep VmRSS /proc/$pid/status 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
      if [ -n "${rss:-}" ]; then
        n=$((n+1))
        [ "$rss" -gt "$peak" ] && peak=$rss
      fi
      sleep 0.15
    done
  fi
  wait "$bg"

  echo "--- $label: backend $pid, peak RSS (KB) ---"
  printf 'peak=%s (n=%s)\n' "$peak" "$n"
  cat "$log"

  check "$label: the probe found the backend pid" "$pid" "$([ -n "$pid" ] && echo 1 || echo 0)"
  check "$label: the call was actually sampled"    "n=$n"  "$([ "$n" -gt 0 ] && echo 1 || echo 0)"
  check "$label: the call completed"               "$(grep -c "marker_${label}_done" "$log")" \
        "$([ "$(grep -c "marker_${label}_done" "$log")" = "1" ] && echo 1 || echo 0)"
  check "$label: no invalid-memory-alloc error"     "$(grep -c 'invalid memory alloc' "$log")" \
        "$([ "$(grep -c 'invalid memory alloc' "$log")" = "0" ] && echo 1 || echo 0)"
  check "$label: peak RSS stays bounded (<= ${MAX_PEAK_KB}KB)" "${peak}KB" \
        "$([ "$peak" -le "$MAX_PEAK_KB" ] && echo 1 || echo 0)"
}

run_one "dynamic" "archive._pq_deflate_encode_dynamic"
run_one "fixed"   "archive._pq_deflate_encode"

exit "$fail"

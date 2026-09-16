#!/usr/bin/env bash
# Prove every perf guard actually catches the defect it exists for. Run by CI (`./test.sh discriminate`).
#
# WHY THIS EXISTS. A green guard is not evidence. It is green when the defect is absent, and equally
# green when the guard never observed anything at all -- and this repo has shipped the second kind six
# times: scan counters that read 0 because they were sampled inside the transaction that produced them;
# a lock probe that sampled after the window closed and saw no locks, so "no ACCESS EXCLUSIVE held"
# passed on broken code; a probe that held a lock of its own and starved the tick it was measuring, so
# nothing took a strong lock and the reader assertion passed against a tick that did nothing; a log
# match on `drain%` that also matched `drain_skip`, which is exactly what a starved tick writes.
#
# Each of those was caught by hand, once, by running the guard against pre-fix code. That evidence lived
# in a commit message and decayed immediately. This makes it a standing check: for every mutation in
# bench/mutations/, build a copy of install.sql with the defect back in, run the guard against it, and
# require the guard to FAIL. A guard that stays green on its own mutant is not testing anything.
#
# Usage: discriminate.sh [--track=NAME] <container> [<archive container>]
# The second container is only needed for mutations scoped to pgpm_archive/install.sql (which
# requires the archive track's own image -- pgsql-http isn't in the plain core image); a mutation
# whose src needs it, with no such container supplied, is a FAILURE of this check, not a skip --
# same principle as a stale pattern: a guard this script never actually ran is unverified.
#
# --track selects which mutations to run, defaulting to `perf` -- the ones every machine can run.
# `--track=locktrace` runs the eBPF trace guard's mutation instead, against the privileged container
# passed as <container> (see bench/mutations/mutate.py's MUTATION_TRACK for why that track is
# separate rather than simply skipped when eBPF is unavailable). The tracks are disjoint, so every
# mutation is run by exactly one of them and none is silently left out.
set -uo pipefail
TRACK="perf"
case "${1:-}" in --track=*) TRACK="${1#--track=}"; shift ;; esac
C="${1:?container}"
CA="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results/mutants"       # gitignored
mkdir -p "$OUT"
fail=0
i=0

# Materialise the listing BEFORE the loop rather than piping it straight in. `done < <(cmd)` discards
# cmd's exit status, so a mutate.py that refused to list anything -- an unknown track, a track whose
# last mutation was removed -- would be indistinguishable from a track that simply had no work, and
# the loop would fall straight through to "PASS (0 guard(s) verified)". A green check that ran
# nothing is the one output this script must never produce.
LIST="$OUT/mutations-$TRACK.tsv"
if ! python3 "$ROOT/bench/mutations/mutate.py" --list "--track=$TRACK" > "$LIST"; then
  printf 'FAIL  could not list mutations for track %s (see above); nothing was verified\n' "$TRACK"
  exit 1
fi

while IFS=$'\t' read -r name guard why src; do
  i=$((i + 1))
  db="pgpm_mut$i"
  printf '\n--- %s\n    breaks: %s\n    src: %s\n    defect: %s\n' "$name" "$guard" "$src" "$why"

  case "$src" in
    pgpm_archive/install.sql) target_c="$CA" ;;
    *) target_c="$C" ;;
  esac
  if [ -z "$target_c" ]; then
    printf 'FAIL  no container supplied for src %s; guard %s is unverified\n' "$src" "$guard"
    fail=1; continue
  fi

  # A stale pattern must not quietly yield an unmutated copy: mutate.py exits non-zero instead, and a
  # mutant we could not build is a failure of this check, not a skip.
  if ! python3 "$ROOT/bench/mutations/mutate.py" "$name" "$ROOT/$src" "$OUT/$name.sql"; then
    printf 'FAIL  could not build the mutant (see above); guard %s is unverified\n' "$guard"
    fail=1; continue
  fi

  # The repo is bind-mounted at /repo, so the mutant is reachable by the same relative path inside.
  if bash "$ROOT/$guard" "$target_c" "$db" "/repo/bench/results/mutants/$name.sql" >"$OUT/$name.log" 2>&1; then
    printf 'FAIL  %s PASSED against its own defect: it does not discriminate\n' "$guard"
    sed 's/^/      /' "$OUT/$name.log"
    fail=1
  else
    printf 'PASS  %s fails when the defect is present\n' "$guard"
    grep '^FAIL' "$OUT/$name.log" | sed 's/^/      /'
  fi
  docker exec "$target_c" psql -U postgres -q -c "drop database if exists $db" >/dev/null 2>&1
done < "$LIST"

echo
# Belt and braces with the listing check above: whatever the reason, finishing having run nothing is
# a failure, not a pass. This script's whole claim is "these guards were run against their defects
# and failed"; with i=0 it has no such evidence for anything.
if [ "$i" = 0 ]; then
  printf 'FAIL  track %s ran no mutations at all; every guard it covers is unverified\n' "$TRACK"
  fail=1
fi
if [ "$fail" = 0 ]; then echo "discriminate: PASS ($i guard(s) verified against their defects)"
else echo "discriminate: FAIL"; fi
exit "$fail"

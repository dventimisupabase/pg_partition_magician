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
# Usage: discriminate.sh <container>
set -uo pipefail
C="${1:?container}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results/mutants"       # gitignored
mkdir -p "$OUT"
fail=0
i=0

while IFS=$'\t' read -r name guard why; do
  i=$((i + 1))
  db="pgpm_mut$i"
  printf '\n--- %s\n    breaks: %s\n    defect: %s\n' "$name" "$guard" "$why"

  # A stale pattern must not quietly yield an unmutated copy: mutate.py exits non-zero instead, and a
  # mutant we could not build is a failure of this check, not a skip.
  if ! python3 "$ROOT/bench/mutations/mutate.py" "$name" "$ROOT/pgpm_core/install.sql" "$OUT/$name.sql"; then
    printf 'FAIL  could not build the mutant (see above); guard %s is unverified\n' "$guard"
    fail=1; continue
  fi

  # The repo is bind-mounted at /repo, so the mutant is reachable by the same relative path inside.
  if bash "$ROOT/$guard" "$C" "$db" "/repo/bench/results/mutants/$name.sql" >"$OUT/$name.log" 2>&1; then
    printf 'FAIL  %s PASSED against its own defect: it does not discriminate\n' "$guard"
    sed 's/^/      /' "$OUT/$name.log"
    fail=1
  else
    printf 'PASS  %s fails when the defect is present\n' "$guard"
    grep '^FAIL' "$OUT/$name.log" | sed 's/^/      /'
  fi
  docker exec "$C" psql -U postgres -q -c "drop database if exists $db" >/dev/null 2>&1
done < <(python3 "$ROOT/bench/mutations/mutate.py" --list)

echo
if [ "$fail" = 0 ]; then echo "discriminate: PASS ($i guard(s) verified against their defects)"
else echo "discriminate: FAIL"; fi
exit "$fail"

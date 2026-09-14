#!/usr/bin/env bash
# Guard that phase 3's cutover builds and configures the new parent BEFORE either rename (issue #344),
# so that work never adds to the outage. #275's split already keeps the one O(rows) scan out from under
# ACCESS EXCLUSIVE; this is the sibling guard for phase 3 itself, which is one transaction end to end --
# anything it does after the first rename is held under that lock until the whole procedure commits.
#
# NOT a concurrency probe. The whole point of this change is to make the critical section SHORTER, which
# makes it harder, not easier, to catch anything "in progress" -- the opposite problem transmute_lock.sh
# solves. There is nothing to observe live; the property is about STATEMENT ORDER inside one transaction,
# which is simple, deterministic SQL against the installed function's own source text, with zero flake
# risk: no timing, no concurrent session, no polling loop to starve what it measures.
#
# Usage: transmute_cutover_order.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected> (numeric position comparison: actual < expected)
  if [ "$2" -gt 0 ] && [ "$2" -lt "$3" ]; then printf 'PASS  %-62s %s < %s\n' "$1" "$2" "$3"
  else printf 'FAIL  %-62s got %s, want < %s (and > 0)\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

# position()/strpos() are 1-based and 0 means "not found" -- either failure mode is caught by check()'s
# "> 0" requirement, so a marker that goes missing entirely fails loudly instead of comparing 0 < 0.
SRC_QUERY="select prosrc from pg_proc where proname = '_transmute' and pronamespace = 'pgpm'::regnamespace"

RENAME_POS=$(q       "select strpos(lower(($SRC_QUERY)), 'rename to')")
PARTITION_POS=$(q    "select strpos(lower(($SRC_QUERY)), 'partition by range')")
RLS_POS=$(q          "select strpos(lower(($SRC_QUERY)), 'enable row level security')")

check "the new parent's CREATE TABLE runs before the first rename" "$PARTITION_POS" "$RENAME_POS"
check "the RLS/grants/policies/comments replay runs before the first rename" "$RLS_POS" "$RENAME_POS"

exit "$fail"

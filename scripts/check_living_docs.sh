#!/usr/bin/env bash
# Guard the LIVING documentation against the two ways it rots. Run by CI (the `Living docs` lint job).
#
# WHY THIS EXISTS. The repo carries two kinds of markdown and used to mark neither: documents that must be
# TRUE against the code, and point-in-time artifacts kept for history. With no boundary between them, a
# frozen design note read as authoritative, and a deletion in install.sql left four documents describing
# machinery that no longer existed. That went unnoticed through an entire docs sweep, and the sweep after it
# found the same rot in three more files. Two greps would have caught both rounds.
#
# CHECK 1: no living document may name an identifier that install.sql no longer defines. A reader copying a
# call out of the reference should not get "function does not exist".
#
# CHECK 2: no living document may link to a frozen artifact. A link from a living doc is precisely what
# makes a frozen one look current -- which is how a superseded design note became "the operating model" in
# three separate documents. Frozen -> living links are fine and encouraged; only this direction is barred.
#
# CHANGELOG.md is excluded from BOTH: its entries are historical by design and must keep naming the
# machinery they removed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

LIVING=(README.md ONBOARDING.md docs/guide.md docs/reference.md docs/runbook.md
        pgpm_archive/README.md bench/README.md bench/SIZE_LADDER.md)

FROZEN=(REDESIGN.md NIGHT-LOG.md from_hypertable_design.md from_hypertable_test_plan.md
        postgresql_online_partition_migration_summary.md docs/blog-partition-a-live-table.md
        bench/STORAGE-IO-ON-GREEN.md)

# Identifiers that install.sql once defined and no longer does. Deliberately a literal list rather than a
# derived one: deriving "every pgpm identifier" from SQL text produces false positives on prose, and a
# missed entry here costs nothing, while a false positive would block unrelated work. Add to it whenever
# something public is removed -- that is the moment the docs need sweeping anyway.
GONE=(drain_all drain_step 'snapshot()' check_default pgpm.hook drain_budget
      _ambient_lock_waiters _ambient_congested _aimd_next _feather_congested retain_reclaim
      obtain_reap default_dirty)

echo "== check 1: living docs must not name removed identifiers =="
# The list is CURATED, not derived from install.sql, and an earlier version of this script shows why. It
# tried to auto-skip any identifier install.sql still mentioned, so the list could never go stale -- but
# `drain_all` appears there in `drop function if exists pgpm.drain_all(...)`, a line that exists precisely
# BECAUSE the function was removed. The guard read its own gravestone as proof of life and passed against
# the defect. Dead identifiers also legitimately survive in comments and in dead code, so "mentioned in
# install.sql" can never mean "still callable". Curate the list instead: it is one line per removal, added
# at the moment the docs need sweeping anyway.
for ident in "${GONE[@]}"; do
  for f in "${LIVING[@]}"; do
    [ -f "$f" ] || continue
    if grep -nF -- "$ident" "$f" >/dev/null 2>&1; then
      printf 'FAIL  %s names %s, which pgpm_core/install.sql no longer defines\n' "$f" "$ident"
      grep -nF -- "$ident" "$f" | sed 's/^/        /'
      fail=1
    fi
  done
done
[ "$fail" = 0 ] && echo "PASS  no living document names a removed identifier"

echo
echo "== check 2: living docs must not link to frozen artifacts =="
found=0
for f in "${LIVING[@]}"; do
  [ -f "$f" ] || continue
  for t in "${FROZEN[@]}"; do
    base="$(basename "$t")"
    if grep -nF -- "$base" "$f" >/dev/null 2>&1; then
      printf 'FAIL  %s references the frozen artifact %s\n' "$f" "$base"
      grep -nF -- "$base" "$f" | sed 's/^/        /'
      fail=1; found=1
    fi
  done
done
[ "$found" = 0 ] && echo "PASS  no living document references a frozen artifact"

echo
echo "== check 3: every frozen artifact says so =="
for t in "${FROZEN[@]}"; do
  [ -f "$t" ] || continue
  if ! grep -q "Frozen artifact" "$t"; then
    printf 'FAIL  %s carries no frozen-artifact banner, so it reads as current documentation\n' "$t"
    fail=1
  fi
done
[ "$fail" = 0 ] && echo "PASS  every frozen artifact is labelled"

exit "$fail"

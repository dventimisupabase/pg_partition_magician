#!/usr/bin/env bash
# Guard the LIVING documentation against the ways it rots. Run by CI (the `Living docs` lint job).
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
# CHECK 4: no OPERATOR document may cite an issue number. An issue number is provenance for a maintainer; to
# an operator it is a dead end that implies they must read a GitHub thread to understand their own database.
# Provenance belongs in CHANGELOG.md, commit messages and code comments, none of which this checks.
#
# CHECK 5: every version literal a living document tells the operator to type must be the version this tree
# installs. docs/guide.md's database.dev snippet pins `version 'X.Y.Z'` by hand (dbdev recommends pinning),
# and RELEASING.md's list of files to bump at release time did not include it, so the pin sat at 0.4.0
# through two releases and an operator following the guide installed a release the CHANGELOG lists fixes
# for. pgpm_core/extension.control's default_version is the value test.sh and the workflows already build
# from, so every literal is held to that one.
#
# `--selftest` re-breaks a scratch copy of the docs (the stale pin) and requires check 5 to FAIL against
# it, after first passing against the unbroken copy. A check that stays green on its own re-break guards
# nothing. CI runs the self-test before the check, as it does for check_quoted_splices.py.
#
# CHANGELOG.md is excluded from ALL of these: its entries are historical by design and must keep naming the
# machinery and versions they removed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

LIVING=(README.md ONBOARDING.md docs/guide.md docs/reference.md docs/runbook.md
        pgpm_archive/README.md bench/README.md bench/SIZE_LADDER.md
        index.html install.html)   # the explainer is user-facing documentation too, and rotted the same way

# The three documents an operator reads to run pgpm. Check 4 scopes to these on purpose (README.md is the
# front door and CHANGELOG.md is where provenance belongs).
OPERATOR=(docs/guide.md docs/reference.md docs/runbook.md)

FROZEN=(frozen/REDESIGN.md frozen/NIGHT-LOG.md frozen/from_hypertable_design.md
        frozen/from_hypertable_test_plan.md frozen/postgresql_online_partition_migration_summary.md
        frozen/blog-partition-a-live-table.md frozen/STORAGE-IO-ON-GREEN.md
        frozen/2026-09-16-lock-sequence-renderer-design.md frozen/2026-09-16-lock-sequence-renderer.md)

# Identifiers that install.sql once defined and no longer does. Deliberately a literal list rather than a
# derived one: deriving "every pgpm identifier" from SQL text produces false positives on prose, and a
# missed entry here costs nothing, while a false positive would block unrelated work. Add to it whenever
# something public is removed -- that is the moment the docs need sweeping anyway.
GONE=(drain_all drain_step 'snapshot()' check_default pgpm.hook drain_budget drain_move
      _ambient_lock_waiters _ambient_congested _aimd_next _feather_congested retain_reclaim
      obtain_reap default_dirty
      feathering_validation adaptive_ticks wal_backoffs lock_backoffs io_backoffs
      _wal_sustainable_bps _ambient_io_latency _ambient_io_surge _ambient_surge
      _forced_checkpoints rows_moved)

# The version this tree installs, read the way test.sh and .github/workflows/test.yml read it. Empty when
# the control file or its line has moved, which check 5 treats as a failure rather than a pass with nothing
# to compare against.
control_version() {  # <root>
  awk -F"'" '/^default_version/ {print $2}' "$1/pgpm_core/extension.control" 2>/dev/null
}

# CHECK 5. Takes the tree root so --selftest can point it at a re-broken copy.
check_version_pins() {  # <root>
  local root="$1" ver f hit n=0 bad=0
  echo "== check 5: version literals in living docs must be the version this tree installs =="
  ver=$(control_version "$root")
  if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf "FAIL  could not read a semver default_version from pgpm_core/extension.control (got '%s'); there is nothing to hold the docs to\n" "$ver"
    return 1
  fi
  for f in "${LIVING[@]}"; do
    [ -f "$root/$f" ] || continue
    # One `line:version 'X.Y.Z'` per literal. install.html's `version 'DBDEV_VERSION'` is a placeholder
    # the pages workflow fills from the tag, so it is not a semver triple and is rightly not matched.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      n=$((n + 1))
      if [ "${hit#*:}" != "version '$ver'" ]; then
        printf "FAIL  %s:%s tells the operator to type %s, but this tree installs %s (pgpm_core/extension.control); bump it with the release\n" \
          "$f" "${hit%%:*}" "${hit#*:}" "$ver"
        bad=1
      fi
    done < <(grep -noE "version '[0-9]+\.[0-9]+\.[0-9]+'" "$root/$f")
  done
  [ "$bad" = 0 ] || return 1
  if [ "$n" = 0 ]; then
    echo "PASS  no living document pins a version literal (nothing to hold to $ver)"
  else
    echo "PASS  $n version literal(s) in living docs all name $ver, the version this tree installs"
  fi
}

# --selftest helpers. A re-break is applied to a scratch copy, never to the tree, and refuses to apply when
# its pattern no longer matches exactly the expected number of lines: a drifted pattern would otherwise
# yield an unbroken copy, the check would pass against it, and this would report a check that "does not
# discriminate" for one that is fine. Same discipline as bench/mutations/mutate.py.
rebreak() {  # <file> <find> <replace> <expected line count>
  local file="$1" find="$2" repl="$3" want="$4" got
  got=$(grep -cF -- "$find" "$file" || true)
  if [ "$got" != "$want" ]; then
    printf 'selftest: FAIL  re-break pattern matched %s line(s) in %s, expected %s: the docs moved and this re-break is stale. Fix the pattern; do not let it produce an unbroken copy.\n' \
      "$got" "$file" "$want"
    printf '        pattern: %s\n' "$find"
    return 1
  fi
  FIND="$find" REPL="$repl" python3 - "$file" <<'PY'
import os, sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()
with open(path, "w") as fh:
    fh.write(text.replace(os.environ["FIND"], os.environ["REPL"]))
PY
}

expect_pass() {  # <label> <check fn> <root>
  local label="$1" fn="$2" root="$3" out
  if out=$("$fn" "$root" 2>&1); then
    printf 'selftest: ok    %s passes\n' "$label"
  else
    printf 'selftest: FAIL  %s should pass and did not:\n' "$label"
    printf '%s\n' "$out" | sed 's/^/        /'
    return 1
  fi
}

expect_fail() {  # <label> <needle the failure must name> <check fn> <root>
  local label="$1" needle="$2" fn="$3" root="$4" out
  if out=$("$fn" "$root" 2>&1); then
    printf 'selftest: FAIL  %s PASSED against its own re-break: it does not discriminate\n' "$label"
    printf '%s\n' "$out" | sed 's/^/        /'
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    printf 'selftest: FAIL  %s failed, but not for the re-broken site (expected the output to name %s):\n' "$label" "$needle"
    printf '%s\n' "$out" | sed 's/^/        /'
    return 1
  fi
  printf 'selftest: ok    %s fails, naming %s\n' "$label" "$needle"
}

selftest() {
  local tmp ver stale rc=0
  tmp=$(mktemp -d)
  mkdir -p "$tmp/docs" "$tmp/pgpm_core"
  cp docs/guide.md "$tmp/docs/"
  cp pgpm_core/extension.control "$tmp/pgpm_core/"
  ver=$(control_version .)

  # Positive control first: a re-break only means something if the unbroken copy passes.
  expect_pass "check 5 on the unbroken tree" check_version_pins "$tmp" || rc=1

  # Re-break 1, the defect as shipped: the guide's database.dev pin two releases stale.
  stale="0.4.0"; [ "$stale" = "$ver" ] && stale="0.3.0"
  if rebreak "$tmp/docs/guide.md" "version '$ver'" "version '$stale'" 1; then
    expect_fail "check 5 against the stale pin" "$stale" check_version_pins "$tmp" || rc=1
  else rc=1; fi
  rm -rf "$tmp"
  if [ "$rc" = 0 ]; then echo "selftest: PASS (check 5 fails against its re-break)"
  else echo "selftest: FAIL"; fi
  return "$rc"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi

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

echo
echo "== check 4: operator docs must not cite issue numbers =="
# `#` immediately followed by digits. A markdown anchor is `](#name)` and no heading id here starts with a
# digit, so `(#325)`, `issue #347`, `pre-#429` and `post-#94` all trip it and `[link](#set_obtain)` does
# not. Scoped to the three operator documents on purpose: README.md is the front door and CHANGELOG.md is
# where provenance belongs. Verified to FAIL against the docs as they stood before issue #434 (13 hits).
found=0
for f in "${OPERATOR[@]}"; do
  [ -f "$f" ] || continue
  if grep -nE '#[0-9]+' "$f" >/dev/null 2>&1; then
    printf 'FAIL  %s cites an issue number; state the behaviour and leave the provenance to CHANGELOG.md\n' "$f"
    grep -nE '#[0-9]+' "$f" | sed 's/^/        /'
    fail=1; found=1
  fi
done
[ "$found" = 0 ] && echo "PASS  no operator document cites an issue number"

echo
check_version_pins . || fail=1

exit "$fail"

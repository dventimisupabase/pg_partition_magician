#!/usr/bin/env python3
"""Reintroduce a known defect into pgpm_core/install.sql, so a guard can be shown to catch it.

A guard that passes proves nothing on its own: it might pass because the defect is gone, or because it
never observed anything. This repo has produced the second kind six times, so every guard under
bench/ has a mutation here that puts its defect back, and bench/discriminate.sh asserts the guard FAILS
against it. A guard that stays green on its own mutant is not a guard.

Each mutation states the exact number of sites it expects to change and REFUSES to write a mutant if
the count is off. That matters more than it looks: a mutation whose pattern has drifted out of date
would silently produce a clean copy of install.sql, the guard would pass against it, and
discriminate.sh would report "does not discriminate" for a guard that is in fact fine. Failing loudly
on a stale pattern is the same liveness-witness discipline the guards themselves follow.

Usage: mutate.py <name> <src install.sql> <dst path>
       mutate.py --list
"""
import re
import sys

# Each boundary is a BOUNDARY comment block, a `commit;`, and (usually) the set_config that re-applies
# lock_timeout, since `set local` does not survive a COMMIT. Matching the whole block keeps the mutant
# readable rather than leaving orphaned comments explaining a commit that is no longer there.
BOUNDARY_RE = re.compile(
    r"^  -- BOUNDARY \(#279\).*?\n  commit;\n(?:  perform set_config\('lock_timeout'.*?\n)?",
    re.MULTILINE | re.DOTALL,
)

# name -> (guard it must break, why this is the right defect, [(find, replace, expected_count)])
MUTATIONS = {
    "transmute_no_commits": (
        "bench/transmute_lock.sh",
        "Pre-#275 transmute: one transaction, so the ADD's ACCESS EXCLUSIVE is still held during the "
        "O(rows) validation scan.",
        [("  commit;   -- releases the ADD's ACCESS EXCLUSIVE before the scan; "
          "the advisory lock survives\n", "", 1)],
    ),
    "maintain_no_commits": (
        "bench/maintain_lock.sh",
        "Pre-#279 maintain: one transaction per tick, so obtain's ACCESS EXCLUSIVE on the parent is "
        "held across the drain.",
        # EVERY boundary inside maintain(), not just the one before the drain. Removing only the first
        # leaves obtain's lock released at the SECOND boundary a few statements later, which is a short
        # window the guard rightly does not object to -- the guard then passed against this mutant and
        # discriminate.sh reported it as non-discriminating. The defect being modelled is "the tick is
        # one transaction", so the mutant has to actually make it one.
        [(BOUNDARY_RE, "", 6)],
    ),
    "regrain_no_delta_analyze": (
        "bench/regrain_perf.sh",
        "Pre-#272 regrain: the trigger-populated delta carries no row estimate, so the planner "
        "misplans a reconcile tick into a seq scan of the whole delta.",
        [("""  if (select coalesce(reltuples, -1) from pg_class where oid = format('%I.%I', v_nsp, v_delta)::regclass) <= 0 then
    perform pgpm._analyze(format('%I.%I', v_nsp, v_delta)::regclass);
  end if;
""", "", 1)],
    ),
}


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--list":
        for name, (guard, why, _) in MUTATIONS.items():
            print(f"{name}\t{guard}\t{why}")
        return 0
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2

    name, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    if name not in MUTATIONS:
        print(f"mutate.py: unknown mutation {name!r}; try --list", file=sys.stderr)
        return 2

    _, _, edits = MUTATIONS[name]
    with open(src) as fh:
        text = fh.read()

    for find, replace, expected in edits:
        is_re = hasattr(find, "sub")
        got = len(find.findall(text)) if is_re else text.count(find)
        if got != expected:
            print(
                f"mutate.py: {name}: pattern matched {got} time(s), expected {expected}.\n"
                f"  The code has moved and this mutation is stale. Fix the pattern -- do NOT let it\n"
                f"  write an unmutated copy, which would make its guard look broken when it is fine.\n"
                f"  Pattern begins: "
                f"{(find.pattern if is_re else find).strip().splitlines()[0][:90]!r}",
                file=sys.stderr,
            )
            return 1
        text = find.sub(replace, text) if is_re else text.replace(find, replace)

    with open(dst, "w") as fh:
        fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

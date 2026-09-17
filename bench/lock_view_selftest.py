#!/usr/bin/env python3
"""Prove the capture contract's refusals discriminate (issue #392).

A refusal is a NEGATIVE assertion, and this repo's recurring defect is a negative satisfied by an
execution where nothing happened. So every refusal here is exercised TWICE: once with the check in
place, which must refuse, and once with that check alone bypassed, which must render. The second run
is the discrimination proof. Without it a refusal test passes when the loader dies of a parse error,
a missing file, or an empty array, and the named check is never what rejected anything.

The bypassed run uses checks=() rather than "every check except this one": damaging a capture to
trip one check often trips a second (bypassing "empty" still trips "strong" on this fixture, and
bypassing "drain" leaves dropped at -1, which trips "dropped"). The discrimination claim is already
carried by the first run, which asserts that Refused.check equals the check's own name; the bypassed
run only has to prove the damaged capture does not crash the loader for an unrelated reason such as a
parse error or an empty array.

The positive fixture is the liveness witness for the refusals themselves: without it, a loader that
refused everything would pass the other four cases.
"""
import json
import pathlib
import shutil
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from plot_lock_view import CHECKS, Refused, load_capture  # noqa: E402

GOLDEN = pathlib.Path(__file__).parent / "fixtures" / "lockview" / "golden"
fail = 0


def check(label, actual, expected):
    global fail
    if actual == expected:
        print(f"PASS  {label:<62} {actual}")
    else:
        print(f"FAIL  {label:<62} got {actual}, want {expected}")
        fail = 1


def mutate(tmp, fn):
    """Copy the golden capture and let fn damage it."""
    d = pathlib.Path(tmp) / "run"
    shutil.copytree(GOLDEN, d)
    recs = [json.loads(l) for l in (d / "events.jsonl").open() if l.strip()]
    recs = fn(recs)
    with (d / "events.jsonl").open("w") as fh:
        for r in recs:
            fh.write(json.dumps(r) + "\n")
    return d


def refuses(run_dir, checks):
    try:
        load_capture(run_dir, checks=checks)
        return ""
    except Refused as exc:
        return exc.check


# Asymmetric on purpose: the golden fixture carries 261 relations and 13 commits, nowhere near a
# symmetric one-and-one shape, so a transposition bug in the damage functions below cannot cancel
# the way it could against a fixture with matched counts.
DAMAGE = {
    "dropped": lambda rs: [{"dropped": 5, "unmatched": 0} if "dropped" in r else r for r in rs],
    "drain":   lambda rs: [r for r in rs if "dropped" not in r],
    "empty":   lambda rs: [r for r in rs if "dropped" in r],
    "strong":  lambda rs: [r for r in rs if not (r.get("kind") == "lock" and r.get("mode") == 8)],
}

for name, damage in DAMAGE.items():
    with tempfile.TemporaryDirectory() as tmp:
        d = mutate(tmp, damage)
        check(f"{name}: refuses with the check in place", refuses(d, CHECKS), name)
        check(f"{name}: renders with checks bypassed entirely", refuses(d, ()), "")

check("a good capture loads", refuses(GOLDEN, CHECKS), "")

# The refusal checks above only prove the loader does not raise; refuses() discards the Capture it
# gets back, so none of them says anything about what got resolved. Load once more and inspect the
# result directly, so a names resolution that silently returns nothing (or drops Ruling 2's
# 2-column defaulting) is caught here instead of passing as an untested side effect of a load that
# merely did not throw.
cap = load_capture(GOLDEN, checks=CHECKS)
enlisted = cap.names.get(16567)
check("a known oid resolves to its recorded name",
      enlisted.name if enlisted else None, "public.mg_ret")
check("a relation from the 2-column CSV defaults parent to \"\"",
      enlisted.parent if enlisted else None, "")
check("a relation from the 2-column CSV defaults kind to \"other\"",
      enlisted.kind if enlisted else None, "other")

from plot_lock_view import fold_rows  # noqa: E402

# --- The fold (Task 2) ---
#
# The brief's own test asserts len(rows) == 10 against the golden fixture, but the golden
# fixture's names.*.csv are deliberately 2-column (oid,name only, see the two checks above
# this comment): every Relation.parent is "", so the fold has nothing to fold on and produces
# one row per relation, not ten. Synthesizing parents into the fixture by pattern-matching
# names was rejected: it would make this test verify a regex in the fixture builder instead
# of the real SQL fold that a later task supplies. So the fold is proved two ways instead:
# a small synthetic capture WITH explicit parents (proves folding happens when parent is
# populated), and the golden fixture WITHOUT parents (proves the rel.parent or rel.name
# fallback this ruling makes load-bearing).


def _write_synthetic_capture(tmp):
    """Build a capture directory with three relations sharing one parent.

    Kept deliberately asymmetric per this repo's CLAUDE.md: three relation-lock events and
    two commit events, never a matched 1-and-1 shape, so a transposition bug (e.g. counting
    commits as rows, or off-by-one folding) cannot cancel out and pass by accident. The three
    lock events are written with ts values out of order (3, 1, 2) so the "ordered by ts"
    assertion cannot pass merely because the input already happened to be sorted.
    """
    d = pathlib.Path(tmp) / "run"
    d.mkdir()
    events = [
        {"kind": "lock", "oid": 1, "ts": 3, "mode": 8},
        {"kind": "lock", "oid": 2, "ts": 1, "mode": 8},
        {"kind": "lock", "oid": 3, "ts": 2, "mode": 8},
        {"kind": "commit", "ts": 4},
        {"kind": "commit", "ts": 5},
        {"dropped": 0, "unmatched": 0},
    ]
    with (d / "events.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    # 4-column CSV: oid,name,parent,kind. All three relations share one parent, so the fold
    # must collapse them onto a single row labelled by that parent, not by their own names.
    with (d / "names.after.csv").open("w") as fh:
        fh.write("1,public.child_a,public.parent_x,other\n")
        fh.write("2,public.child_b,public.parent_x,other\n")
        fh.write("3,public.child_c,public.parent_x,other\n")
    return d


with tempfile.TemporaryDirectory() as tmp:
    syn_dir = _write_synthetic_capture(tmp)
    syn_cap = load_capture(syn_dir, checks=())
    syn_rows = fold_rows(syn_cap)

    check("three relations sharing one parent fold to exactly one row", len(syn_rows), 1)
    check("the one row is labelled by the shared parent, not a member's own name",
          list(syn_rows.keys()), ["public.parent_x"])
    check("the folded row carries all three relations' lock events",
          sorted(e["oid"] for e in syn_rows.get("public.parent_x", [])), [1, 2, 3])
    check("the folded row's events are ordered by ts despite arriving out of order",
          [e["oid"] for e in syn_rows.get("public.parent_x", [])], [2, 3, 1])
    check("no commit leaked into the synthetic row",
          any(e["kind"] == "commit" for evs in syn_rows.values() for e in evs), False)

cap = load_capture(GOLDEN, checks=CHECKS)
rows = fold_rows(cap)
locked = {e["oid"] for e in cap.events if e["kind"] == "lock"}

# Measured on the source capture 2026-09-16: 261 distinct locks. The golden names CSVs carry
# no parent column (asserted above), so every Relation.parent is "" and the fallback in
# fold_rows (rel.parent or rel.name) makes this degenerate to one row per relation: 261, not
# the brief's invented 10. This is not a throwaway count: it is the only thing in this file
# that exercises the "or rel.name" branch at all.
check("the golden capture locks 261 distinct relations", len(locked), 261)
check("without a parent column the fold degenerates to one row per relation",
      len(rows), 261)
check("no commit leaked into any row of the golden capture",
      any(e["kind"] == "commit" for evs in rows.values() for e in evs), False)

# Not asserting ts-ordering here on purpose: without a parent column every one of these 261
# rows holds exactly one event (see the degenerate-fold check above), and a singleton list
# is trivially "sorted" whatever fold_rows does with it, including if the evs.sort() call
# were deleted entirely. Shuffling the input first does not fix this either: the fold still
# produces one event per row, because folding only ever appends a subsequence of the input.
# The synthetic capture above is what actually proves the sort, because its three events
# land in a single row with deliberately scrambled ts values. Do not re-add an ordering
# check here; it would be a passing test that also passes against code missing the sort.

sys.exit(fail)

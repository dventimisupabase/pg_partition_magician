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
# Re-pointed 2026-09-16 (Task 5) to a real bench/lock_view.sh capture of the lock_trace.sh
# retain-drop fixture (mg_ret/ml under call pgpm.maintain_all()); oid 21278 is that capture's
# public.mg_ret, not the spike fixture's 16567.
enlisted = cap.names.get(21278)
check("a known oid resolves to its recorded name",
      enlisted.name if enlisted else None, "public.mg_ret")


def _write_two_column_capture(tmp):
    """Build a capture directory whose names CSV is deliberately 2-column (oid,name only).

    The golden fixture used to BE this shape by accident: it predated the uretprobe and the
    parent column, so every one of its relations defaulted through the fallback below whether
    the test meant to exercise it or not. Task 5 re-points the golden fixture to a real
    bench/lock_view.sh capture, whose names CSVs are always 4-column (see the fold block
    below), so nothing else in this file exercises _read_names' 2-column contract any more.
    This fixture exists solely to keep proving it: a bare "oid,name" row must still default
    parent to "" and kind to "other" rather than raising or leaving them unset, exactly per
    the docstring in plot_lock_view.py's _read_names.
    """
    d = pathlib.Path(tmp) / "run"
    d.mkdir()
    events = [
        {"kind": "lock", "oid": 1, "ts": 1, "mode": 1},
        {"dropped": 0, "unmatched": 0},
    ]
    with (d / "events.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    with (d / "names.after.csv").open("w") as fh:
        fh.write("1,public.two_col_table\n")
    return d


with tempfile.TemporaryDirectory() as tmp:
    two_col_dir = _write_two_column_capture(tmp)
    two_col_cap = load_capture(two_col_dir, checks=())
    two_col_rel = two_col_cap.names.get(1)
    check("a relation from a 2-column CSV defaults parent to \"\"",
          two_col_rel.parent if two_col_rel else None, "")
    check("a relation from a 2-column CSV defaults kind to \"other\"",
          two_col_rel.kind if two_col_rel else None, "other")

from plot_lock_view import fold_rows  # noqa: E402

# --- The fold (Task 2) ---
#
# The brief's own test asserts len(rows) == 10 against the golden fixture, but the ORIGINAL
# golden fixture's names.*.csv were 2-column (oid,name only): every Relation.parent was "", so
# the fold had nothing to fold on and produced one row per relation, not ten. Synthesizing
# parents into the fixture by pattern-matching names was rejected: it would make this test
# verify a regex in the fixture builder instead of the real SQL fold. So the fold was proved
# two ways: a small synthetic capture WITH explicit parents (below, unchanged), and the golden
# fixture WITHOUT parents (the degenerate case).
#
# Task 5 re-points the golden fixture to a real bench/lock_view.sh capture (Ruling 2), whose
# names CSVs carry a real `parent` column from the harness's SQL fold, so the degenerate case
# no longer applies to it: this is the first time the golden fixture exercises the REAL fold
# rather than its fallback. See the block below the synthetic capture for the re-measured
# assertions.


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

# Re-measured 2026-09-16 against the re-pointed golden fixture (Task 5): a real
# bench/lock_view.sh capture of the lock_trace.sh retain-drop fixture (mg_ret/ml, under call
# pgpm.maintain_all()). 261 distinct locked relations is the SAME number the old spike
# fixture had -- confirmed here by a fresh count against the new file, not assumed to still
# hold -- but the fold itself is no longer degenerate: this fixture's names CSVs carry a real
# `parent` column from the harness's own SQL fold (index to its table, toast to its table,
# partition to its managed parent, walked through up to two hops so an index on a partition's
# own toast table still lands on the partition's parent), so the 261 relations now collapse
# onto 9 rows, matching the design spec's "roughly ten" prediction rather than the old
# fallback's 261.
check("the golden capture locks 261 distinct relations", len(locked), 261)
check("the real parent column folds 261 relations down to 9 rows", len(rows), 9)
# Identity, not cardinality (CLAUDE.md): the row count alone would also pass if the fold
# merged the wrong relations together, so the exact label set is pinned too.
check("the 9 rows are exactly the tables the tick actually touched",
      sorted(rows), [
          "pgpm.archive_result", "pgpm.config", "pgpm.dropped_fk", "pgpm.log",
          "pgpm.log_id_seq", "pgpm.part", "public.mg_ret", "public.ml",
          "public.ml_pgpm_regrain_delta",
      ])
check("no commit leaked into any row of the golden capture",
      any(e["kind"] == "commit" for evs in rows.values() for e in evs), False)

# Ruling 2: rows here now hold hundreds of events apiece (public.mg_ret's alone carries
# 2,251), not the one-event-per-row degenerate case the old fixture produced, so a
# ts-ordering check on the golden fixture is worth attempting. Attempted, and DROPPED after
# checking it does not discriminate: bench/lock_view.py's probe drains one ring buffer in one
# polling loop and appends events as they are produced, so events.jsonl is already globally
# non-decreasing in ts before fold_rows ever runs, and folding only ever filters a subsequence
# of an already-sorted sequence, which stays sorted whether or not fold_rows sorts it again.
# Verified directly rather than assumed: a scratch copy of plot_lock_view.py with the
# `evs.sort(key=lambda e: e["ts"])` line deleted was run against this exact golden capture,
# and all 9 folded rows were still in ts order. A check that cannot fail against the defect it
# exists to catch is not evidence (this repo's CLAUDE.md), so it is not added here. The
# synthetic capture above remains the only place that check can fail, because it deliberately
# writes its three events out of ts order (3, 1, 2) before folding.

from plot_lock_view import render, tier  # noqa: E402

# --- The mode -> tier classification (fix round 1, Finding 1/2) ---
#
# An earlier cut of render() used two independently-maintained constant sets, LIGHT for the
# --modes strong filter and STRONG for the styling, and they disagreed: RowShare (2),
# RowExclusive (3), ShareUpdateExclusive (4) and Share (5) are not in STRONG (so they painted
# as pale background) and are not LIGHT either (so --modes strong never dropped them). On a
# real capture that was 279 marks surviving the "strong" filter while being drawn as noise.
# Every one of PostgreSQL's eight lock modes is pinned here, rather than a couple of
# representative samples, specifically because that defect lived in the gap between two
# samples (mode 3 was never asserted anywhere in the original 27-check suite).
check("tier classifies AccessShare (1) as light", tier(1), "light")
check("tier classifies RowShare (2) as saturated", tier(2), "saturated")
check("tier classifies RowExclusive (3) as saturated", tier(3), "saturated")
check("tier classifies ShareUpdateExclusive (4) as saturated", tier(4), "saturated")
check("tier classifies Share (5) as saturated", tier(5), "saturated")
check("tier classifies ShareRowExclusive (6) as strong", tier(6), "strong")
check("tier classifies Exclusive (7) as strong", tier(7), "strong")
check("tier classifies AccessExclusive (8) as strong", tier(8), "strong")

# Re-measured against the re-pointed golden fixture: bench/lock_view.sh ran the whole traced
# tick through a single psql invocation, so the capture is still single-backend (stamps one
# backend, below). `--modes strong` still has AccessShare marks to drop -- 2,527 of the
# capture's 3,347 events are AccessShare (light tier), leaving 820 drawn -- so this pair keeps
# discriminating rather than becoming vacuous on a capture that happened to have none.
with tempfile.TemporaryDirectory() as tmp:
    out = pathlib.Path(tmp)
    stamp = render(cap, out)
    check("renders a PNG", (out / "lock-view.png").exists(), True)
    check("renders an SVG", (out / "lock-view.svg").exists(), True)
    check("stamps the captured count", stamp["captured"], len(cap.events))
    check("captured equals drawn with no filter", stamp["drawn"], stamp["captured"])
    check("stamps one backend", stamp["backends"], 1)

    strong = render(cap, out, modes="strong")
    check("strong mode draws fewer marks", strong["drawn"] < strong["captured"], True)
    check("strong mode still stamps the full captured count", strong["captured"], stamp["captured"])

sys.exit(fail)

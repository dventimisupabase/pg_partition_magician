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
# "strong" strips every STRONG_MODES member (6, 7, 8), not only AccessExclusive (8): the check
# this damages was broadened (issue #392 review, fix 6) to tier()=="strong" rather than a
# hardcoded mode == 8 comparison, because retain's AccessExclusive locks land on PARTITION oids,
# not the enlisted table's own, so restricting the refusal to "no AccessExclusive anywhere" was
# already the right shape -- but a maintenance tick that only ever took ShareRowExclusive (6) or
# Exclusive (7) still did real, blocking work and must not be misread as a no-op either. The
# golden fixture carries 29 mode-6 (ShareRowExclusive) events alongside its 499 mode-8 ones, so
# stripping mode 8 alone would leave mode 6 behind and the refusal would no longer trip -- which
# is exactly what happened when this was first written against the old hardcoded check.
DAMAGE = {
    "dropped": lambda rs: [{"dropped": 5, "unmatched": 0} if "dropped" in r else r for r in rs],
    "drain":   lambda rs: [r for r in rs if "dropped" not in r],
    "empty":   lambda rs: [r for r in rs if "dropped" in r],
    "strong":  lambda rs: [r for r in rs
                            if not (r.get("kind") == "lock" and r.get("mode") in (6, 7, 8))],
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
        {"kind": "lock", "oid": 1, "ts": 1, "mode": 1, "pid": 1},
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
        {"kind": "lock", "oid": 1, "ts": 3, "mode": 8, "pid": 1},
        {"kind": "lock", "oid": 2, "ts": 1, "mode": 8, "pid": 1},
        {"kind": "lock", "oid": 3, "ts": 2, "mode": 8, "pid": 1},
        {"kind": "commit", "ts": 4, "pid": 1},
        {"kind": "commit", "ts": 5, "pid": 1},
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

    # The golden fixture's real wait_ns values (1,403-9,027 ns, per the module docstring) never
    # cross WAIT_DRAW_THRESHOLD_NS, so this is the liveness witness that the real data legitimately
    # draws none -- distinct from the synthetic straddle fixture below, which proves the drawing
    # path CAN execute.
    check("the golden capture's real sub-microsecond waits draw no wait span", stamp["wait_spans"], 0)

    # spec:209-210 (fix round 2, Finding 4b), against real data: pgpm.archive_result (1 mark) and
    # pgpm.dropped_fk (11 marks) are the golden capture's only all-light-tier rows (verified
    # directly above via fold_rows/tier), and both should be annotated with their exact count.
    check("annotates exactly the golden capture's two all-light-tier rows", stamp["annotated_rows"], 2)
    check("--modes strong skips the all-light annotation (that filter already empties those rows)",
          strong["annotated_rows"], 0)

    # spec:215-216 (fix round 2, Finding 4c), against real data: the design spec's own cross-check
    # (Verification section, "Drops against pgpm.log, by identity") measured 29 partitions dropped
    # by this exact tick, matched to pgpm.log by range bound. Every one of those 29 carries at
    # least one lock event in the golden capture (verified directly against the CSVs), so the ring
    # count below should be exactly 29, not a subset.
    check("rings exactly the 29 partitions dropped during the golden capture's window", stamp["rung"], 29)

# --- unmatched: coverage and discrimination (fix round 2, Finding 2) ---
#
# Forcing `unmatched = 0` in load_capture previously passed 36/36, because nothing asserted on
# Capture.unmatched, the stamp's "unmatched" key, or the footer color it feeds. These three
# checks close that gap. `footer_color` is deliberately pulled out and tested directly (like
# `tier()` and `should_draw_wait()`) rather than only indirectly through a rendered image, whose
# color a self-test cannot easily inspect after `plt.close(fig)`.
from plot_lock_view import GREY, RED, footer_color  # noqa: E402


def _write_unmatched_capture(tmp):
    """A single-backend capture whose tail record carries a distinctive, nonzero unmatched count.

    4, not 1: this repo's CLAUDE.md warns against fixtures where a miscount could still land on a
    value a bug might produce by accident (e.g. a bool coerced to 0/1). One lock event and one
    commit event, asymmetric on purpose.
    """
    d = pathlib.Path(tmp) / "run"
    d.mkdir()
    events = [
        {"kind": "lock", "oid": 1, "ts": 1, "mode": 8, "pid": 1},
        {"kind": "commit", "ts": 2, "pid": 1},
        {"dropped": 0, "unmatched": 4},
    ]
    with (d / "events.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    return d


with tempfile.TemporaryDirectory() as tmp:
    u_dir = _write_unmatched_capture(tmp)
    u_cap = load_capture(u_dir, checks=())
    check("a capture whose tail record reports unmatched=4 carries that on the Capture",
          u_cap.unmatched, 4)
    with tempfile.TemporaryDirectory() as tmp2:
        u_stamp = render(u_cap, pathlib.Path(tmp2))
        check("the rendered stamp reports the same unmatched count the capture carries",
              u_stamp["unmatched"], 4)

check("footer_color is grey when neither dropped nor unmatched is nonzero", footer_color(0, 0), GREY)
check("footer_color is red when unmatched alone is nonzero (a complete trace, still flagged)",
      footer_color(0, 4), RED)
check("footer_color is red when dropped alone is nonzero", footer_color(2, 0), RED)

# --- should_draw_wait: threshold coverage and a synthetic capture that crosses it (Finding 3) ---
from plot_lock_view import should_draw_wait  # noqa: E402

check("should_draw_wait is False for a wait just below the threshold (999,999 ns)",
      should_draw_wait(999_999), False)
check("should_draw_wait is False for a wait exactly at the threshold (1,000,000 ns)",
      should_draw_wait(1_000_000), False)
check("should_draw_wait is True for a wait just above the threshold (1,000,001 ns)",
      should_draw_wait(1_000_001), True)


def _write_wait_straddle_capture(tmp):
    """Two relations, three lock events, wait_ns straddling WAIT_DRAW_THRESHOLD_NS.

    oid 10's one event sits just below threshold (no span drawn); oid 20 carries two events
    above it (both drawn), so drawing more than once on the same row is exercised too. This is
    the fixture that actually walks the `ax.hlines` line: deleting that whole block, as the
    review's mutation proved, passes 36/36 against every OTHER fixture in this file, because none
    of their wait_ns values (0, absent, or the golden fixture's 1,403-9,027 ns) ever cross
    1,000,000.
    """
    d = pathlib.Path(tmp) / "run"
    d.mkdir()
    events = [
        {"kind": "lock", "oid": 10, "ts": 10_000_000, "mode": 8, "pid": 1, "wait_ns": 999_999},
        {"kind": "lock", "oid": 20, "ts": 20_000_000, "mode": 8, "pid": 1, "wait_ns": 1_500_000},
        {"kind": "lock", "oid": 20, "ts": 30_000_000, "mode": 8, "pid": 1, "wait_ns": 4_000_000},
        {"dropped": 0, "unmatched": 0},
    ]
    with (d / "events.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    return d


with tempfile.TemporaryDirectory() as tmp:
    w_dir = _write_wait_straddle_capture(tmp)
    w_cap = load_capture(w_dir, checks=())
    with tempfile.TemporaryDirectory() as tmp2:
        w_stamp = render(w_cap, pathlib.Path(tmp2))
        check("a synthetic capture straddling the wait threshold draws exactly its two "
              "above-threshold waits as spans", w_stamp["wait_spans"], 2)

# --- all_light: coverage of the predicate itself (Finding 4b) ---
from plot_lock_view import all_light  # noqa: E402

check("all_light is True for a row whose one mark is light-tier", all_light([{"mode": 1}]), True)
check("all_light is False for a row mixing light and strong marks",
      all_light([{"mode": 1}, {"mode": 8}]), False)
check("all_light is False for an empty row (nothing to annotate a count onto)", all_light([]), False)

all_light_labels = sorted(label for label, evs in rows.items() if all_light(evs))
check("the golden capture's all-light-tier rows are exactly archive_result and dropped_fk",
      all_light_labels, ["pgpm.archive_result", "pgpm.dropped_fk"])

# --- per-pid rows: two backends (Finding 4a, spec:218-219) ---
#
# Also gives "stamps one backend" (above) something real to discriminate against: before this
# fixture, no capture in this file ever had more than one pid, so a `backends` counter hardcoded
# to 1 would have passed every check in this file.


def _write_two_backend_capture(tmp):
    """Three lock events across two pids (2-and-1, not 1-and-1) plus one commit.

    pid 100 takes both marks on oid 2 and one of the two marks on oid 1; pid 200 takes the other
    mark on oid 1. Both relations share no parent (2-column-shape names), so without per-pid
    keying oid 1's two marks (one per pid) would land on the SAME row and interleave, which is
    exactly the defect spec:218-219 exists to prevent.
    """
    d = pathlib.Path(tmp) / "run"
    d.mkdir()
    events = [
        {"kind": "lock", "oid": 1, "ts": 1, "mode": 8, "pid": 100},
        {"kind": "lock", "oid": 1, "ts": 2, "mode": 1, "pid": 200},
        {"kind": "lock", "oid": 2, "ts": 3, "mode": 8, "pid": 100},
        {"kind": "commit", "ts": 4, "pid": 100},
        {"dropped": 0, "unmatched": 0},
    ]
    with (d / "events.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    with (d / "names.after.csv").open("w") as fh:
        fh.write("1,public.t1,,other\n")
        fh.write("2,public.t2,,other\n")
    return d


with tempfile.TemporaryDirectory() as tmp:
    two_d = _write_two_backend_capture(tmp)
    two_cap = load_capture(two_d, checks=())
    two_rows = fold_rows(two_cap)
    check("two backends fold rows keyed on (label, pid), not label alone",
          sorted(two_rows), ["public.t1 (pid 100)", "public.t1 (pid 200)", "public.t2 (pid 100)"])
    with tempfile.TemporaryDirectory() as tmp2:
        two_stamp = render(two_cap, pathlib.Path(tmp2))
        check("stamps two backends", two_stamp["backends"], 2)

# --- the drop ring: partitions present before, absent after (Finding 4c, spec:215-216) ---


def _write_drop_ring_capture(tmp):
    """One partition dropped during the window (oid 5), one that survives it (oid 6).

    oid 5 gets two lock events (its last mark is the one that should be rung); oid 6 gets one,
    asymmetric on purpose so a transposition between "rung" and "not rung" cannot cancel. Both
    fold onto the same parent row (public.mg_ret), so this also proves the ring is drawn at the
    RIGHT event within a row that mixes rung and non-rung oids, not merely "somewhere in the
    figure".
    """
    d = pathlib.Path(tmp) / "run"
    d.mkdir()
    events = [
        {"kind": "lock", "oid": 5, "ts": 1, "mode": 8, "pid": 1},
        {"kind": "lock", "oid": 5, "ts": 2, "mode": 8, "pid": 1},
        {"kind": "lock", "oid": 6, "ts": 3, "mode": 8, "pid": 1},
        {"dropped": 0, "unmatched": 0},
    ]
    with (d / "events.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    with (d / "names.before.csv").open("w") as fh:
        fh.write("5,public.mg_ret_p1,public.mg_ret,partition\n")
        fh.write("6,public.mg_ret_p2,public.mg_ret,partition\n")
    with (d / "names.after.csv").open("w") as fh:
        fh.write("6,public.mg_ret_p2,public.mg_ret,partition\n")
    return d


with tempfile.TemporaryDirectory() as tmp:
    ring_d = _write_drop_ring_capture(tmp)
    ring_cap = load_capture(ring_d, checks=())
    check("a partition present before and absent after is recorded as dropped",
          ring_cap.dropped_oids, frozenset({5}))
    check("a partition present in both before and after is not recorded as dropped",
          6 in ring_cap.dropped_oids, False)
    with tempfile.TemporaryDirectory() as tmp2:
        ring_stamp = render(ring_cap, pathlib.Path(tmp2))
        check("rings exactly the one dropped partition's last mark, not the surviving one",
              ring_stamp["rung"], 1)

# --- the strong refusal on a real, non-AccessExclusive tier (fix round 2, Finding 6) ---
#
# retain's AccessExclusive locks land on PARTITION oids, never the enlisted table's own, so the
# spec's stricter original reading ("no strong-mode mark on any ENLISTED relation") was wrong in
# general; the code's "any relation" was already right. Separately, the code hardcoded
# `mode == ACCESS_EXCLUSIVE` while `tier()` defines "strong" as modes 6, 7 and 8: reconciled here
# by checking `tier() == "strong"`, so a tick whose only strong-tier work was ShareRowExclusive or
# Exclusive (never AccessExclusive itself) is still recognised as having done real work.


def _write_share_row_exclusive_only_capture(tmp):
    d = pathlib.Path(tmp) / "run"
    d.mkdir()
    events = [
        {"kind": "lock", "oid": 1, "ts": 1, "mode": 7, "pid": 1},   # Exclusive: strong, never 8
        {"kind": "lock", "oid": 2, "ts": 2, "mode": 1, "pid": 1},
        {"dropped": 0, "unmatched": 0},
    ]
    with (d / "events.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    return d


with tempfile.TemporaryDirectory() as tmp:
    sre_d = _write_share_row_exclusive_only_capture(tmp)
    check("a capture whose only strong-tier lock is Exclusive (7), never AccessExclusive, "
          "still passes the strong refusal", refuses(sre_d, CHECKS), "")

# --- producer semantics: honest, not merely claimed (issue #392 review, finding 3) ---
#
# plot_lock_view.py's own docstring used to claim a guard capture "is never plotted as though its
# marks meant the same instant as a lock_view.py capture's", on the strength of meta.json's
# `producer` key. That claim was false: load_capture never read the key at all, so every capture,
# guard or not, was drawn with grant semantics regardless of what actually produced it. These checks
# cover both branches this fix introduces (is_grant_producer's one true case, and everything else,
# including no key at all) and are what a mutation restoring the old always-grant behaviour must
# fail against (see the report for the discrimination proof; it is not repeated as an in-file
# bypass here because there is no CHECKS-style "damage the fixture, then bypass the check" shape
# for a labelling decision that is not a refusal).
from plot_lock_view import (  # noqa: E402
    build_footer,
    is_grant_producer,
    producer_label,
    producer_note,
)

check("is_grant_producer is True for lock_view.py, the only probe with a uretprobe",
      is_grant_producer("lock_view.py"), True)
check("is_grant_producer is False for lock_probe.py (the CI guard's probe, no uretprobe)",
      is_grant_producer("lock_probe.py"), False)
check("is_grant_producer is False for an absent producer (\"\"), treated like lock_probe.py",
      is_grant_producer(""), False)
check("is_grant_producer is False for any other, unrecognised producer string",
      is_grant_producer("something_else.py"), False)

check("producer_label normalizes an absent producer to lock_probe.py",
      producer_label(""), "lock_probe.py")
check("producer_label passes an explicit producer through unchanged",
      producer_label("lock_view.py"), "lock_view.py")

check("producer_note says grant time for lock_view.py",
      "grant time" in producer_note("lock_view.py"), True)
check("producer_note says REQUEST time for lock_probe.py",
      "REQUEST time" in producer_note("lock_probe.py"), True)
check("producer_note says REQUEST time for an absent producer too",
      "REQUEST time" in producer_note(""), True)
check("producer_note names lock_probe.py by name even when the key was absent",
      "lock_probe.py" in producer_note(""), True)


def _write_producer_capture(tmp, producer):
    """A minimal capture whose meta.json carries the given `producer` (or omits the key if None)."""
    d = pathlib.Path(tmp) / "run"
    d.mkdir()
    events = [
        {"kind": "lock", "oid": 1, "ts": 1, "mode": 8, "pid": 1},
        {"kind": "commit", "ts": 2, "pid": 1},
        {"dropped": 0, "unmatched": 0},
    ]
    with (d / "events.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    meta = {} if producer is None else {"producer": producer}
    (d / "meta.json").write_text(json.dumps(meta))
    return d


with tempfile.TemporaryDirectory() as tmp:
    grant_dir = _write_producer_capture(tmp, "lock_view.py")
    grant_cap = load_capture(grant_dir, checks=())
    check("load_capture carries an explicit lock_view.py producer onto Capture.producer",
          grant_cap.producer, "lock_view.py")

with tempfile.TemporaryDirectory() as tmp:
    probe_dir = _write_producer_capture(tmp, "lock_probe.py")
    probe_cap = load_capture(probe_dir, checks=())
    check("load_capture carries an explicit lock_probe.py producer onto Capture.producer",
          probe_cap.producer, "lock_probe.py")

with tempfile.TemporaryDirectory() as tmp:
    # meta.json exists but omits the key entirely: the real shape of a lock_view.py capture taken
    # before this key existed. The golden fixture (checked below, no meta.json edit needed) is a
    # real instance of exactly this case.
    nokey_dir = _write_producer_capture(tmp, None)
    nokey_cap = load_capture(nokey_dir, checks=())
    check("load_capture carries \"\" when meta.json omits the producer key",
          nokey_cap.producer, "")

# The golden fixture predates the producer key (Task 5's real capture was taken before
# bench/lock_view.sh started writing it), so its own meta.json has no such key -- a real,
# committed instance of the "absent" branch, not a fixture built to order for it.
golden_cap = load_capture(GOLDEN, checks=CHECKS)
check("the golden fixture's meta.json carries no producer key",
      golden_cap.producer, "")
check("is_grant_producer is False for the golden fixture's own producer value",
      is_grant_producer(golden_cap.producer), False)

with tempfile.TemporaryDirectory() as tmp:
    out = pathlib.Path(tmp)
    grant_stamp = render(load_capture(_write_producer_capture(tmp, "lock_view.py"), checks=()), out)
    check("render's stamp names lock_view.py when the capture declares it",
          grant_stamp["producer"], "lock_view.py")
    check("render's stamp notes grant time for a lock_view.py capture",
          "grant time" in grant_stamp["producer_note"], True)
    check("build_footer includes the grant-time note for a lock_view.py capture",
          "grant time" in build_footer(grant_stamp, "all"), True)

with tempfile.TemporaryDirectory() as tmp:
    out = pathlib.Path(tmp)
    guard_stamp = render(golden_cap, out)
    check("render's stamp normalizes the golden fixture's absent producer to lock_probe.py",
          guard_stamp["producer"], "lock_probe.py")
    check("render's stamp notes REQUEST time for a producer-less (guard-shaped) capture",
          "REQUEST time" in guard_stamp["producer_note"], True)
    check("build_footer includes the REQUEST-time note for a producer-less capture",
          "REQUEST time" in build_footer(guard_stamp, "all"), True)

sys.exit(fail)

#!/usr/bin/env python3
"""Render a lock-sequence capture from bench/lock_view.sh (issue #392).

Refuses to draw a capture it cannot trust. A picture is more persuasive than a number, so it is held
to a higher bar than the guard's numeric output: a truncated trace rendered as a complete one is the
exact failure that made pg-lock-tracer unsound (#391).

The loading half below (`load_capture`) asserts nothing about PostgreSQL or the probe directly: it
reads whatever bench/lock_view.sh (a later task) or the existing CI probe wrote to a run directory and
decides whether the result is trustworthy enough to draw. That decision is the point. Every refusal
below corresponds to a way a capture can look fine and be wrong. The drawing half (`render`, Task 3)
asserts nothing at all; it draws whatever a trusted `Capture` hands it and stamps what it drew.

  - dropped:  the kernel ring buffer overflowed and the probe lost events. A ring-buffer drop is
              silent to everything downstream unless the probe itself counts it, so this is the one
              signal a renderer has no other way to reconstruct.
  - drain:    the probe process was killed before it wrote its final tally, so "dropped" is unknown.
              Treating "unknown" as "zero" is exactly the assumption that makes a truncated trace
              look complete, so an absent tail record refuses on its own, distinct from dropped != 0.
  - empty:    the capture has no lock events at all. An empty timeline and "the probe attached to
              nothing and recorded nothing" render identically, so this is caught before drawing
              rather than left to look like a suspiciously quiet result.
  - strong:   the capture never saw an AccessExclusive lock. A partition-maintenance tick that did
              real work always takes at least one; a capture without one recorded a no-op, and a
              calm, correct-looking figure of a no-op is worse than an error because it is
              persuasive.

Two formats feed this loader. The existing CI guard's probe (bench/lock_probe.py, untouched by this
task) never wrote a "wait_ns" or "unmatched" field, because it never needed to distinguish a lock wait
from an instant grant. A later task's probe always does. Both are read with dict.get(..., default),
never a bare key lookup, so one loader serves both producers without caring which wrote the capture.

Drawing (matplotlib) is imported below (Task 3's `render`). Because of that import, from here on
`bench/lock_view_selftest.py` only runs under an interpreter that has matplotlib installed, which the
system `python3` on this host does not: `pip install matplotlib` refuses under PEP 668. Use the venv
this repo keeps for exactly this (Ruling 8/8a): `python3 -m venv .venv-lockview && .venv-lockview/bin/pip
install matplotlib`, then run the self-test as `.venv-lockview/bin/python bench/lock_view_selftest.py`.
Do not reuse `.venv-verify`; that one belongs to the archive track (pyarrow, duckdb).
"""
import csv
import json
import pathlib
from dataclasses import dataclass, field
from typing import Sequence

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ACCESS_EXCLUSIVE = 8
CHECKS = ("dropped", "drain", "empty", "strong")


class Refused(Exception):
    """Raised when a capture fails one of the trust checks in CHECKS.

    `check` names which of CHECKS fired (never a description of it), so a caller such as the
    self-test can assert on identity rather than on message text. `detail` is the human-readable
    reason, for a person reading the tool's own refusal on the command line.
    """

    def __init__(self, check: str, detail: str):
        super().__init__(f"{check}: {detail}")
        self.check = check
        self.detail = detail


@dataclass
class Relation:
    oid: int
    name: str
    parent: str
    kind: str


@dataclass
class Capture:
    events: list = field(default_factory=list)
    dropped: int = 0
    unmatched: int = 0
    meta: dict = field(default_factory=dict)
    names: dict = field(default_factory=dict)


def _read_names(path: pathlib.Path) -> dict:
    """Read an oid,name[,parent,kind] CSV into oid -> Relation.

    The spike fixture's CSVs (names_before.csv, names_after.csv) have two columns only: oid and
    name. A later task derives parent/kind from a SQL-based fold over pg_inherits and pg_class, not
    from this loader, so this function must tolerate the 2-column shape rather than require columns
    that do not exist yet. Defaulting parent to "" and kind to "other" is not a placeholder pending
    a future rewrite of this function; it is the contract a 2-column CSV is entitled to.
    """
    out = {}
    if not path.exists():
        return out
    with path.open() as fh:
        for row in csv.reader(fh):
            if len(row) < 2 or not row[0].strip().isdigit():
                continue
            oid = int(row[0])
            parent = row[2] if len(row) > 2 else ""
            kind = row[3] if len(row) > 3 else "other"
            out[oid] = Relation(oid=oid, name=row[1], parent=parent, kind=kind)
    return out


def load_capture(run_dir: pathlib.Path, checks: Sequence[str] = CHECKS) -> Capture:
    run_dir = pathlib.Path(run_dir)
    records = [json.loads(l) for l in (run_dir / "events.jsonl").open() if l.strip()]
    events = [r for r in records if "kind" in r]
    tail = [r for r in records if "dropped" in r]

    # before UNION after: before carries what the tick DROPS (44% of the relations this capture
    # traced, 116 of 261, do not resolve in names.after.csv once the tick succeeds -- not 44% of
    # every relation in the database, which is a much larger and unrelated denominator), after
    # carries what the tick CREATES. A tick does both.
    names = _read_names(run_dir / "names.after.csv")
    names.update(_read_names(run_dir / "names.before.csv"))

    meta = {}
    if (run_dir / "meta.json").exists():
        meta = json.loads((run_dir / "meta.json").read_text())

    if "drain" in checks and not tail:
        raise Refused("drain", "no final drop record: the probe was killed before it drained, so "
                               "completeness is unknown, which is not the same as fine")

    dropped = tail[-1]["dropped"] if tail else -1
    unmatched = tail[-1].get("unmatched", 0) if tail else 0

    if "dropped" in checks and dropped != 0:
        raise Refused("dropped", f"{dropped} event(s) lost in the kernel; a truncated trace drawn "
                                 f"as a complete one is exactly what made the old tool unsound")

    if "empty" in checks and not events:
        raise Refused("empty", "no events: an empty chart reads as 'no locks were taken', which is "
                               "indistinguishable from 'the probe attached to nothing'")

    if "strong" in checks:
        strong = [e for e in events
                  if e["kind"] == "lock" and e.get("mode") == ACCESS_EXCLUSIVE]
        if not strong:
            raise Refused("strong", "no AccessExclusive mark on any relation: a tick that did "
                                    "nothing renders as a calm, correct-looking figure")

    return Capture(events=events, dropped=dropped, unmatched=unmatched, meta=meta, names=names)


def fold_rows(cap: Capture) -> dict:
    """Fold every relation onto the row a reader cares about.

    One tick locks hundreds of distinct relations (261 in the golden capture), and a figure
    with hundreds of rows is a wall, not a picture. The fold collapses an index onto the
    table it indexes, a toast relation onto its table and a partition onto its managed
    parent, so a reader sees the handful of tables the maintenance actually touched. Those
    mappings are resolved in SQL by a later task (index to pg_index.indrelid, toast to
    pg_class.reltoastrelid, partition to pgpm.part.parent_table) and arrive here already
    decided, in the `parent` column of the name CSVs load_capture reads. This function
    consumes that answer; it never recomputes it, because the joins it would need
    (pg_inherits, pg_index, pg_class) belong to a snapshot taken DURING the traced window.
    44% of the relations in a real capture (116 of 261 here) stop resolving in pg_class the
    moment the tick succeeds, because retain drops them, so reconstructing the fold from a
    post-hoc query would fail for exactly the rows most worth seeing.

    A commit is a backend event, not a relation event, so it is never grouped into a row
    here: it belongs on the drawing as a rule across all rows (Task 3), not inside one of
    them. An oid with no entry in cap.names is a relation the tick CREATED during the window
    (a new partition, its index, its toast table) rather than one that existed going in, so
    it gets its own literal label rather than silently vanishing from the figure.

    When names.*.csv carries no parent column (the 2-column shape load_capture's docstring
    calls out), every Relation.parent is "" and `rel.parent or rel.name` falls back to the
    relation's own name, so the fold degenerates to one row per relation rather than
    collapsing anything. That is not a bug in this function: it is the correct answer to a
    fold with nothing to fold on, and it is what the golden fixture (whose CSVs predate the
    parent column) exercises.
    """
    rows: dict = {}
    for e in cap.events:
        if e["kind"] != "lock":
            continue                      # a commit belongs to the backend, not to a row
        rel = cap.names.get(e["oid"])
        if rel is None:
            label = "created during the window"
        else:
            label = rel.parent or rel.name
        rows.setdefault(label, []).append(e)
    for evs in rows.values():
        evs.sort(key=lambda e: e["ts"])
    return rows


GREEN, INK, GREY, RED = "#3ecf8e", "#1c1c1c", "#9aa0a6", "#d2553b"

# Lock mode integers per storage/lockdefs.h, folded into three drawing/filtering tiers by one
# function (`tier`) rather than two independently-maintained constant sets. An earlier cut of
# this module used LIGHT (what --modes strong drops) for the filter and STRONG (what draws
# tall) for the styling, and the two disagreed: RowShare/RowExclusive/ShareUpdateExclusive/
# Share are not in STRONG, so they painted as pale background, yet they are not LIGHT either,
# so --modes strong never dropped them -- on a real capture that is 279 marks surviving the
# "strong" filter while being drawn as unimportant. `tier()` is the single place both the
# filter and the styling read from, so they cannot diverge again.
LIGHT_MODE = 1
STRONG_MODES = (6, 7, 8)


def tier(mode: int) -> str:
    """Classify a lock mode integer into "light", "saturated" or "strong" (design spec's terms).

    light      AccessShare (1) only: the mode common enough to swamp a real capture (198 of
               261 locks in the golden fixture, 2,527 of 3,347 in the spec's real one) and the
               only mode `--modes strong` drops. Drawn thin, low alpha, on the row baseline.
    saturated  RowShare (2), RowExclusive (3), ShareUpdateExclusive (4), Share (5): ordinary
               locking traffic. Drawn full alpha, above the baseline, but not the tallest.
    strong     ShareRowExclusive (6), Exclusive (7), AccessExclusive (8): the modes that
               actually block other backends. Drawn tallest; AccessExclusive additionally
               keeps its own colour (RED, via the ACCESS_EXCLUSIVE constant) rather than
               sharing "strong"'s INK.
    """
    if mode == LIGHT_MODE:
        return "light"
    if mode in STRONG_MODES:
        return "strong"
    return "saturated"


# (half_height, alpha, linewidth) per tier, applied in render()'s drawing loop below.
TIER_STYLE = {
    "light": (0.10, 0.35, 0.6),
    "saturated": (0.22, 1.0, 0.9),
    "strong": (0.34, 1.0, 1.2),
}


def render(cap: Capture, out_dir: pathlib.Path, modes: str = "all") -> dict:
    """Draw a loaded, trusted Capture to lock-view.png / lock-view.svg in out_dir.

    Asserts nothing about PostgreSQL or the probe: `load_capture` already decided this capture
    is trustworthy enough to draw (its four refusals), and `fold_rows` already decided which
    relations share a row. This function only decides what ink goes where, and returns the
    stamp dict Task 5's caller writes to the run directory alongside the two image files.

    Every mark is an instant, drawn as a vertical tick at its own timestamp, never a bar from
    lock to release: the release path is deliberately unprobed (see the module docstring and
    the design spec), so a bar from request to commit would be an inference rather than an
    observation. The one span drawn is the request-to-grant wait, which genuinely is observed
    (a paired uprobe/uretprobe), via the `wait_ns` field a later probe writes; the golden
    fixture's probe never wrote that field, so `.get("wait_ns", 0)` reads 0 and no wait span is
    drawn for it, which is correct rather than a gap in this function.

    `modes="strong"` drops `tier() == "light"` marks only, i.e. AccessShare; it is not a
    synonym for "only strong-tier modes". `captured` in the returned stamp always counts every
    event `load_capture` read from the file, regardless of `modes`, while `drawn` counts only
    what this specific call put ink on. Keeping those two independent is the point: a filtering
    bug that silently drops the wrong set (too many, too few, or the wrong mode) shows up as a
    `captured`/`drawn` mismatch on the artifact itself instead of passing unnoticed.
    """
    out_dir = pathlib.Path(out_dir)
    rows = fold_rows(cap)
    commits = [e for e in cap.events if e["kind"] == "commit"]
    order = sorted(rows, key=lambda label: min(e["ts"] for e in rows[label]))
    t0 = cap.meta.get("t_begin") or min(e["ts"] for e in cap.events)

    def ms(ts):
        return (ts - t0) / 1e6

    drawn = 0
    fig, ax = plt.subplots(figsize=(12, 1.1 + 0.42 * len(order)))
    for y, label in enumerate(order):
        for e in rows[label]:
            mode_tier = tier(e["mode"])
            if modes == "strong" and mode_tier == "light":
                continue
            drawn += 1
            half_height, alpha, linewidth = TIER_STYLE[mode_tier]
            if e["mode"] == ACCESS_EXCLUSIVE:
                color = RED
            elif mode_tier == "light":
                color = GREY
            else:
                color = INK
            ax.vlines(
                ms(e["ts"]),
                y - half_height,
                y + half_height,
                color=color,
                alpha=alpha,
                linewidth=linewidth,
            )
            # The only lock span drawn, and only because it is observed rather than inferred:
            # the distance between the request (uprobe, entry) and the grant (uretprobe,
            # return). Sub-millisecond waits are not drawn; at this scale they would be
            # invisible ink and not worth the mark.
            wait = e.get("wait_ns", 0)
            if wait > 1_000_000:
                ax.hlines(y, ms(e["ts"] - wait), ms(e["ts"]), color=RED, alpha=0.5, linewidth=3)

    for e in commits:
        drawn += 1
        ax.axvline(ms(e["ts"]), color=GREEN, linewidth=1.0, alpha=0.9, zorder=0)

    ax.set_yticks(range(len(order)))
    ax.set_yticklabels(order, fontsize=8)
    ax.set_ylim(-0.7, len(order) - 0.3)
    ax.set_xlabel("ms since the traced statement began")
    ax.invert_yaxis()
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)

    if cap.meta.get("t_begin") and cap.meta.get("t_end"):
        ax.axvspan(ms(cap.meta["t_begin"]), ms(cap.meta["t_end"]), color=GREY, alpha=0.12, zorder=0)

    span_ms = (max(e["ts"] for e in cap.events) - min(e["ts"] for e in cap.events)) / 1e6
    stamp = {
        "captured": len(cap.events),
        "drawn": drawn,
        "dropped": cap.dropped,
        "unmatched": cap.unmatched,
        "rows": len(order),
        "backends": len({e["pid"] for e in cap.events}),
        "span_ms": round(span_ms, 1),
    }

    filt = "" if modes == "all" else f", --modes {modes}"
    foot = (
        f"{stamp['captured']} captured, {stamp['drawn']} drawn{filt}   "
        f"{stamp['dropped']} dropped, {stamp['unmatched']} unmatched   "
        f"{stamp['span_ms']} ms traced, {stamp['backends']} backend(s)"
    )
    ax.set_title(cap.meta.get("sql", "lock view"), fontsize=10, color=INK, loc="left")
    # An absolute point offset below the axes, not a figure-fraction coordinate: the figure's
    # height ranges from ~1.5in (one folded row) to over 100in (the golden fixture's 261
    # unfolded rows, see the module docstring), and a fixed fraction such as fig.text(0.01,
    # 0.01, ...) sits at a wildly different physical distance from the x-axis tick labels
    # depending on that height, close enough on a short figure to overlap them. An offset in
    # points is independent of figure height and clears the tick labels and the x-axis title
    # on every size this function produces.
    ax.annotate(
        foot,
        xy=(0, 0),
        xycoords="axes fraction",
        xytext=(0, -38),
        textcoords="offset points",
        fontsize=7,
        ha="left",
        va="top",
        annotation_clip=False,
        color=RED if (cap.dropped or cap.unmatched) else GREY,
    )

    for ext in ("png", "svg"):
        fig.savefig(
            out_dir / f"lock-view.{ext}",
            dpi=140,
            bbox_inches="tight",
            facecolor="white" if ext == "png" else "none",
        )
    plt.close(fig)
    return stamp

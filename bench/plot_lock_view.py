#!/usr/bin/env python3
"""Render a lock-sequence capture from bench/lock_view.sh (issue #392).

Refuses to draw a capture it cannot trust. A picture is more persuasive than a number, so it is held
to a higher bar than the guard's numeric output: a truncated trace rendered as a complete one is the
exact failure that made pg-lock-tracer unsound (#391).

This module is the loading half only, and it asserts nothing about PostgreSQL or the probe directly:
it reads whatever bench/lock_view.sh (a later task) or the existing CI probe wrote to a run directory
and decides whether the result is trustworthy enough to draw. That decision is the point. Every
refusal below corresponds to a way a capture can look fine and be wrong:

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

Drawing (matplotlib) is deliberately not imported here. It arrives in Task 3. Importing it in this
module would make this self-test depend on a plotting stack for a check that has nothing to do with
plotting, and would fail on any host that has Python but not matplotlib, including the one this task
was written on.
"""
import csv
import json
import pathlib
from dataclasses import dataclass, field
from typing import Sequence

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

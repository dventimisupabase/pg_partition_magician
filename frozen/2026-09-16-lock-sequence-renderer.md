# Lock-sequence renderer implementation plan

> **Frozen artifact: not current documentation.** A point-in-time record, kept for history and not
> maintained against the code, so it describes the system as it stood when written. For how
> pg_partition_magician works today see the [user guide](../docs/guide.md) and the
> [reference](../docs/reference.md).

<!-- -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give an investigator a rendered timeline of a maintenance tick's lock sequence, captured with a purpose-built eBPF probe and drawn as a PNG and SVG, so lock-boundary changes can be read as a picture instead of re-derived from point-in-time `pg_locks` checks.

**Architecture:** Three programs split by where their dependencies live. `bench/lock_view.py` captures in the privileged locktrace container (bcc), filtering in the kernel to backends that touch the enlisted relations and to non-catalog oids. `bench/lock_view.sh` orchestrates from the host and owns the psql name snapshots that must be taken during the traced window. `bench/plot_lock_view.py` reads the resulting run directory on the host and draws it with matplotlib, refusing outright to draw a capture it cannot trust.

**Tech Stack:** Python 3 with bcc (`BPF_RINGBUF`, uprobe plus uretprobe) in the container; Python 3 with matplotlib on the host; bash and psql for the harness; Docker Compose profile `locktrace`.

**Spec:** `docs/superpowers/specs/2026-09-16-lock-sequence-renderer-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- Catalog exclusion boundary is `oid >= 16384` (`FirstNormalObjectId`), applied in the kernel.
- Lock mode integers come from `storage/lockdefs.h`; `AccessExclusiveLock` is `8`.
- Palette is `bench/plot_results.py`'s, unchanged: `#d2553b` AccessExclusive, `#3ecf8e` commits, `#9aa0a6` light modes, `#1c1c1c` ink. No new colours.
- Ring buffer stays 64 pages; poll interval 100 ms; a final 200 ms drain.
- `READY` is printed only after uprobes are attached AND the ring buffer is open. Nothing gates on anything printed earlier.
- Never join on `pg_backend_pid()`. eBPF reports the initial pid namespace, psql reports the container's (measured: 71,504 against 145).
- Output goes to `bench/results/lockview-<name>-<YYYYmmdd-HHMMSS>/`, which is `*`-ignored.
- No changes to `bench/lock_probe.py`, `bench/lock_trace.sh`, `bench/discriminate.sh`, `bench/mutations/`, or any workflow. No CI job.
- House style: no em dashes anywhere, in code comments or docs.
- Any `.md` touched is linted with `npx -y markdownlint-cli2@0.13.0 "**/*.md" "!postgresql_online_partition_migration_summary.md" "!bench/results/**" "!.venv-verify/**"` before commit.
- matplotlib is a host prerequisite (`pip install matplotlib`), documented the way `bench/figures/README.md` documents it for `plot_results.py`. It is NOT added to the container image.

## Fixture prerequisite, and its fallback

Tasks 1 to 3 use a real capture as the positive fixture, because a hand-written one drifts from what the probe actually emits. The source capture from the design spike currently lives at `~/.claude/jobs/b7685391/tmp/` (`wide.jsonl`, `names_before.csv`, `names_after.csv`).

**That directory is ephemeral.** If it is gone by execution time, the fallback is to complete Tasks 4 and 5 first and capture a fresh fixture with the finished `bench/lock_view.sh`, then return to Tasks 1 to 3. The plan is written in dependency order for the common case, not in the only possible order.

## File structure

| file | action | responsibility |
| --- | --- | --- |
| `bench/lock_view.py` | create | eBPF capture: enlist by relation, exclude catalogs, pair request with grant, count drops and unmatched |
| `bench/lock_view.sh` | create | host harness: name snapshots, READY gate, clock marks, run directory |
| `bench/plot_lock_view.py` | create | host: load, refuse, fold, draw, stamp |
| `bench/lock_view_selftest.py` | create | every refusal exercised twice, plus the positive fixture |
| `bench/fixtures/lockview/golden/` | create | trimmed real capture: `events.jsonl`, `names.before.csv`, `names.after.csv`, `meta.json` |
| `bench/README.md` | modify | document the tool alongside the other bench instruments |

---

### Task 1: Capture loading and the four refusals

The asserting half of the tool, and the only half with a discrimination requirement. Pure Python, no eBPF, no container, no database. Runs on any platform in under a second.

**Files:**

- Create: `bench/plot_lock_view.py`
- Create: `bench/lock_view_selftest.py`
- Create: `bench/fixtures/lockview/golden/events.jsonl`, `names.before.csv`, `names.after.csv`, `meta.json`

**Interfaces:**

- Consumes: nothing from earlier tasks.
- Produces:
  - `CHECKS: tuple[str, ...] = ("dropped", "drain", "empty", "strong")`
  - `class Refused(Exception)` with attributes `check: str` and `detail: str`
  - `@dataclass Relation: oid: int; name: str; parent: str; kind: str`
  - `@dataclass Capture: events: list[dict]; dropped: int; unmatched: int; meta: dict; names: dict[int, Relation]`
  - `load_capture(run_dir: pathlib.Path, checks: Sequence[str] = CHECKS) -> Capture`

- [ ] **Step 1: Build the golden fixture from the spike capture**

Trim to the events needed by Tasks 1 to 3 while keeping every distinct relation, so the fold test in Task 2 still sees all 261:

```bash
mkdir -p bench/fixtures/lockview/golden
SRC=~/.claude/jobs/b7685391/tmp
python3 - "$SRC" <<'PY'
import json, sys, pathlib
src = pathlib.Path(sys.argv[1]).expanduser()
out = pathlib.Path("bench/fixtures/lockview/golden")
recs = [json.loads(l) for l in (src / "wide.jsonl").open() if l.strip()]
events = [r for r in recs if "kind" in r]
dropped = next(r["dropped"] for r in recs if "dropped" in r)

# Keep every commit, the first event for each distinct oid (so the fold still sees all 261
# relations), and a contiguous run through the guard's interval so the timing stays real.
seen, keep = set(), []
for i, e in enumerate(events):
    if e["kind"] == "commit" or e["oid"] not in seen:
        seen.add(e.get("oid"))
        keep.append(e)
keep.sort(key=lambda e: e["ts"])

with (out / "events.jsonl").open("w") as fh:
    for e in keep:
        fh.write(json.dumps(e) + "\n")
    fh.write(json.dumps({"dropped": dropped, "unmatched": 0}) + "\n")

t0, t1 = keep[0]["ts"], keep[-1]["ts"]
(out / "meta.json").write_text(json.dumps({
    "run": "golden", "sql": "call pgpm.maintain_all()",
    "enlist": ["public.mg_ret", "public.ml"], "enlist_oids": [16567, 16791],
    "t_begin": t0, "t_end": t1, "git_sha": "spike", "trimmed_from": len(events),
}, indent=2) + "\n")
print(f"kept {len(keep)} of {len(events)} events, {len(seen)} distinct oids")
PY
cp "$SRC/names_before.csv" bench/fixtures/lockview/golden/names.before.csv
cp "$SRC/names_after.csv"  bench/fixtures/lockview/golden/names.after.csv
```

Expected: `kept ...` prints roughly 270 events and 262 distinct oids (261 relations plus oid 0 for commits).

- [ ] **Step 2: Write the failing self-test**

Create `bench/lock_view_selftest.py`. Note the shape: each refusal is asserted twice, and the second assertion is what proves the named check did the rejecting.

```python
#!/usr/bin/env python3
"""Prove the capture contract's refusals discriminate (issue #392).

A refusal is a NEGATIVE assertion, and this repo's recurring defect is a negative satisfied by an
execution where nothing happened. So every refusal here is exercised TWICE: once with the check in
place, which must refuse, and once with that check alone bypassed, which must render. The second run
is the discrimination proof. Without it a refusal test passes when the loader dies of a parse error,
a missing file, or an empty array, and the named check is never what rejected anything.

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


# Asymmetric on purpose: three relations and two commits, never one and one, so a transposition
# cannot cancel the way a symmetric fixture lets it.
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
        bypassed = tuple(c for c in CHECKS if c != name)
        check(f"{name}: renders with the check bypassed", refuses(d, bypassed), "")

check("a good capture loads", refuses(GOLDEN, CHECKS), "")

sys.exit(fail)
```

- [ ] **Step 3: Run it and verify it fails for the right reason**

Run: `python3 bench/lock_view_selftest.py`

Expected: FAIL with `ModuleNotFoundError: No module named 'plot_lock_view'`. Anything else means the fixture step did not produce what Step 1 claimed.

- [ ] **Step 4: Write the loader and the refusals**

Create `bench/plot_lock_view.py` with the loading half only. Drawing arrives in Task 3.

```python
#!/usr/bin/env python3
"""Render a lock-sequence capture from bench/lock_view.sh (issue #392).

Refuses to draw a capture it cannot trust. A picture is more persuasive than a number, so it is held
to a higher bar than the guard's numeric output: a truncated trace rendered as a complete one is the
exact failure that made pg-lock-tracer unsound (#391).
"""
import csv
import json
import pathlib
from dataclasses import dataclass, field
from typing import Sequence

ACCESS_EXCLUSIVE = 8
CHECKS = ("dropped", "drain", "empty", "strong")


class Refused(Exception):
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

    # before UNION after: before carries what the tick DROPS (44% of relations stop resolving once
    # it succeeds), after carries what the tick CREATES. A tick does both.
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
                  if e["kind"] == "lock" and e["mode"] == ACCESS_EXCLUSIVE]
        if not strong:
            raise Refused("strong", "no AccessExclusive mark on any relation: a tick that did "
                                    "nothing renders as a calm, correct-looking figure")

    return Capture(events=events, dropped=dropped, unmatched=unmatched, meta=meta, names=names)
```

- [ ] **Step 5: Run the self-test and verify it passes**

Run: `python3 bench/lock_view_selftest.py`

Expected: nine `PASS` lines and exit 0. Four refusals times two runs each, plus the positive fixture.

- [ ] **Step 6: Commit**

```bash
git add bench/plot_lock_view.py bench/lock_view_selftest.py bench/fixtures/lockview/golden
git commit -m "feat(bench): capture loading and the four lock-view refusals (#392)"
```

---

### Task 2: The relation fold

261 distinct relations in one tick is a wall. Ten rows is a figure. This task is the difference, and its test has a measured expected answer rather than an invented one.

**Files:**

- Modify: `bench/plot_lock_view.py`
- Modify: `bench/lock_view_selftest.py`

**Interfaces:**

- Consumes: `Capture`, `Relation` from Task 1.
- Produces: `fold_rows(cap: Capture) -> dict[str, list[dict]]`, mapping a row label to the lock events on that row, ordered by `ts`. Commit events are NOT in any row: a commit is a backend event, drawn as a rule across all rows.

- [ ] **Step 1: Write the failing fold test**

Append to `bench/lock_view_selftest.py`, above the final `sys.exit(fail)`:

```python
from plot_lock_view import fold_rows  # noqa: E402

cap = load_capture(GOLDEN, checks=CHECKS)
rows = fold_rows(cap)
locked = {e["oid"] for e in cap.events if e["kind"] == "lock"}

# Measured on the source capture 2026-09-16: 261 distinct user relations fold to 10 rows.
check("the golden capture locks 261 distinct relations", len(locked), 261)
check("they fold to 10 rows", len(rows), 10)
check("mg_ret's partitions fold onto mg_ret", "public.mg_ret" in rows, True)
check("no commit leaked into a row",
      any(e["kind"] == "commit" for evs in rows.values() for e in evs), False)
```

- [ ] **Step 2: Run it and verify it fails**

Run: `python3 bench/lock_view_selftest.py`

Expected: FAIL with `ImportError: cannot import name 'fold_rows'`.

- [ ] **Step 3: Implement the fold**

Add to `bench/plot_lock_view.py`:

```python
def fold_rows(cap: Capture) -> dict:
    """Fold every relation onto the row a reader cares about.

    Three rules, all resolved from snapshots taken DURING the traced window, because 44% of the
    relations in a real capture stop resolving in pg_class the moment the tick succeeds: retain
    drops them. Reconstructing this afterwards fails for exactly the rows most worth seeing.
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
```

The `parent` column is populated by the harness in Task 5, which resolves index to `pg_index.indrelid`, toast to `pg_class.reltoastrelid` and partition to `pgpm.part.parent_table` in SQL, where those joins belong. The renderer consumes the answer rather than recomputing it.

- [ ] **Step 4: Run and verify it passes**

Run: `python3 bench/lock_view_selftest.py`

Expected: thirteen `PASS` lines, exit 0.

If `they fold to 10 rows` fails against the golden fixture, the fixture's `names.*.csv` lack the `parent` column, which the spike wrote without it. Regenerate the fixture after Task 5 exists, or add the column by hand from `pgpm.part`; do NOT relax the assertion to match.

- [ ] **Step 5: Commit**

```bash
git add bench/plot_lock_view.py bench/lock_view_selftest.py
git commit -m "feat(bench): fold 261 relations onto 10 rows for the lock view (#392)"
```

---

### Task 3: The figure

**Files:**

- Modify: `bench/plot_lock_view.py`
- Modify: `bench/lock_view_selftest.py`

**Interfaces:**

- Consumes: `Capture`, `fold_rows` from Tasks 1 and 2.
- Produces: `render(cap: Capture, out_dir: pathlib.Path, modes: str = "all") -> dict` writing `lock-view.png` and `lock-view.svg`, returning the stamp dict with keys `captured`, `drawn`, `dropped`, `unmatched`, `rows`, `backends`, `span_ms`.

- [ ] **Step 1: Write the failing render test**

Append to `bench/lock_view_selftest.py`, above `sys.exit(fail)`:

```python
from plot_lock_view import render  # noqa: E402

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
```

The last two matter more than they look. `captured` must stay the count from the file while `drawn` falls, because the pair is what makes a silent filtering bug visible on the artifact itself.

- [ ] **Step 2: Run it and verify it fails**

Run: `python3 bench/lock_view_selftest.py`

Expected: FAIL with `ImportError: cannot import name 'render'`.

- [ ] **Step 3: Implement the renderer**

Add to `bench/plot_lock_view.py`:

```python
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt   # noqa: E402

GREEN, INK, GREY, RED = "#3ecf8e", "#1c1c1c", "#9aa0a6", "#d2553b"
MODES = {1: "AccessShare", 2: "RowShare", 3: "RowExclusive", 4: "ShareUpdateExclusive",
         5: "Share", 6: "ShareRowExclusive", 7: "Exclusive", 8: "AccessExclusive"}
STRONG = (6, 7, 8)
LIGHT = 1


def render(cap: Capture, out_dir: pathlib.Path, modes: str = "all") -> dict:
    out_dir = pathlib.Path(out_dir)
    rows = fold_rows(cap)
    commits = [e for e in cap.events if e["kind"] == "commit"]
    order = sorted(rows, key=lambda k: min(e["ts"] for e in rows[k]))
    t0 = cap.meta.get("t_begin") or min(e["ts"] for e in cap.events)

    def ms(ts):
        return (ts - t0) / 1e6

    drawn = 0
    fig, ax = plt.subplots(figsize=(12, 1.1 + 0.42 * len(order)))
    for y, label in enumerate(order):
        for e in rows[label]:
            if modes == "strong" and e["mode"] == LIGHT:
                continue
            drawn += 1
            strong = e["mode"] in STRONG
            ax.vlines(ms(e["ts"]), y - (0.34 if strong else 0.10), y + (0.34 if strong else 0.10),
                      color=RED if e["mode"] == 8 else (INK if strong else GREY),
                      alpha=1.0 if strong else 0.35,
                      linewidth=1.2 if strong else 0.6)
            # The ONLY lock span drawn, and only because it is observed rather than inferred: the
            # distance between the request (uprobe, entry) and the grant (uretprobe, return).
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
    stamp = {"captured": len(cap.events), "drawn": drawn, "dropped": cap.dropped,
             "unmatched": cap.unmatched, "rows": len(order),
             "backends": len({e["pid"] for e in cap.events}), "span_ms": round(span_ms, 1)}

    filt = "" if modes == "all" else f", --modes {modes}"
    foot = (f"{stamp['captured']} captured, {stamp['drawn']} drawn{filt}   "
            f"{stamp['dropped']} dropped, {stamp['unmatched']} unmatched   "
            f"{stamp['span_ms']} ms traced, {stamp['backends']} backend(s)")
    ax.set_title(cap.meta.get("sql", "lock view"), fontsize=10, color=INK, loc="left")
    fig.text(0.01, 0.01, foot, fontsize=7,
             color=RED if (cap.dropped or cap.unmatched) else GREY)

    for ext in ("png", "svg"):
        fig.savefig(out_dir / f"lock-view.{ext}", dpi=140, bbox_inches="tight",
                    facecolor="white" if ext == "png" else "none")
    plt.close(fig)
    return stamp
```

- [ ] **Step 4: Run and verify it passes**

Run: `pip install matplotlib && python3 bench/lock_view_selftest.py`

Expected: twenty `PASS` lines, exit 0.

- [ ] **Step 5: Look at the figure**

```bash
python3 -c "
import pathlib, sys; sys.path.insert(0, 'bench')
from plot_lock_view import load_capture, render
render(load_capture(pathlib.Path('bench/fixtures/lockview/golden')), pathlib.Path('/tmp'))
"
```

Open `/tmp/lock-view.png`. Confirm by eye: ten labelled rows, `mg_ret`'s row dense with red marks, commit rules in green crossing every row, the footer reading `0 dropped, 0 unmatched`. A figure that renders but reads wrong is still a failure.

- [ ] **Step 6: Commit**

```bash
git add bench/plot_lock_view.py bench/lock_view_selftest.py
git commit -m "feat(bench): draw the lock-view timeline with a provenance stamp (#392)"
```

---

### Task 4: The eBPF capture

**Files:**

- Create: `bench/lock_view.py`

**Interfaces:**

- Consumes: nothing from earlier tasks. Its output is the `events.jsonl` Task 1 reads.
- Produces: `lock_view.py <oid>[,<oid>...] <output.jsonl>`, printing `READY` on stdout once attached and delivering, running until SIGINT, then writing a final `{"dropped": N, "unmatched": M}`.

- [ ] **Step 1: Write the probe**

```python
#!/usr/bin/env python3
"""Capture a backend's lock sequence for rendering (issue #392).

SEPARATE from bench/lock_probe.py on purpose, and deliberately not shared with it: that probe is what
the CI guard runs, and the guard's instrument must not move when a human tool changes. The BPF C
below is close to identical; the differences are all here, and all deliberate.

  1. The target oids ENLIST a backend rather than select an event. lock_probe.py records only the two
     relations under test; this records everything an enlisted backend locks, which is what a picture
     needs and a pass/fail assertion does not.
  2. oid >= 16384 (FirstNormalObjectId) excludes catalog relations IN THE KERNEL. Measured on the
     design spike: catalogs are 79.9% of a tick's locks, and 1,535 of the 1,642 events inside the
     guard's own 11.1 ms interval. Excluding them is the difference between 16,591 events and 3,347.
  3. Targets live in a BPF_HASH populated from userspace rather than substituted into the source at
     compile time, so any number of relations can be enlisted.
  4. A uretprobe pairs each request with its grant. attach_uprobe fires at function ENTRY, so a bare
     uprobe observes a REQUEST; the distance to the return is the WAIT, which is the one span on the
     figure that is observed rather than inferred.

An unmatched request is COUNTED, never dropped silently: a wait we lost track of must not render as a
zero-length wait, which is the silent-overflow defect wearing a different hat.
"""
import ctypes
import json
import signal
import sys

from bcc import BPF

BIN = "/usr/lib/postgresql/17/bin/postgres"
FIRST_NORMAL_OBJECT_ID = 16384

BPF_TEXT = r"""
#include <uapi/linux/ptrace.h>

BPF_RINGBUF_OUTPUT(events, 64);
BPF_ARRAY(dropped, u64, 1);
BPF_ARRAY(unmatched, u64, 1);
BPF_HASH(watched, u32, u8);
BPF_HASH(targets, u32, u8);

struct req_t { u64 ts; u32 oid; u32 mode; };
BPF_HASH(pending, u32, struct req_t);

#define KIND_LOCK   0
#define KIND_COMMIT 1

struct ev_t {
    u64 ts;
    u64 wait_ns;
    u32 pid;
    u32 oid;
    u32 mode;
    u32 kind;
};

static inline void bump(void *map) {
    int k = 0;
    u64 *v = ((u64 *) 0);
    v = (u64 *) bpf_map_lookup_elem(map, &k);
    if (v) { (*v)++; }
}

int on_lock(struct pt_regs *ctx) {
    u32 oid  = (u32) PT_REGS_PARM1(ctx);
    u32 mode = (u32) PT_REGS_PARM2(ctx);
    u32 pid  = bpf_get_current_pid_tgid() >> 32;

    if (targets.lookup(&oid)) { u8 one = 1; watched.update(&pid, &one); }
    if (!watched.lookup(&pid)) { return 0; }
    if (oid < FIRST_NORMAL) { return 0; }

    /* A pending entry still here means the previous request never returned. Count it rather than
       overwrite it, so a lost wait is reported instead of vanishing. */
    if (pending.lookup(&pid)) {
        int k = 0;
        u64 *u = unmatched.lookup(&k);
        if (u) { (*u)++; }
    }
    struct req_t r = {};
    r.ts = bpf_ktime_get_ns();
    r.oid = oid;
    r.mode = mode;
    pending.update(&pid, &r);
    return 0;
}

int on_lock_ret(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    struct req_t *r = pending.lookup(&pid);
    if (!r) { return 0; }

    struct ev_t *e = events.ringbuf_reserve(sizeof(struct ev_t));
    if (!e) {
        int k = 0;
        u64 *d = dropped.lookup(&k);
        if (d) { (*d)++; }
        pending.delete(&pid);
        return 0;
    }
    e->ts = bpf_ktime_get_ns();
    e->wait_ns = e->ts - r->ts;
    e->pid = pid;
    e->oid = r->oid;
    e->mode = r->mode;
    e->kind = KIND_LOCK;
    events.ringbuf_submit(e, 0);
    pending.delete(&pid);
    return 0;
}

int on_commit(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (!watched.lookup(&pid)) { return 0; }

    struct ev_t *e = events.ringbuf_reserve(sizeof(struct ev_t));
    if (!e) {
        int k = 0;
        u64 *d = dropped.lookup(&k);
        if (d) { (*d)++; }
        return 0;
    }
    e->ts = bpf_ktime_get_ns();
    e->wait_ns = 0;
    e->pid = pid;
    e->oid = 0;
    e->mode = 0;
    e->kind = KIND_COMMIT;
    events.ringbuf_submit(e, 0);
    return 0;
}
"""


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    oids = [int(x) for x in sys.argv[1].split(",") if x]
    out_path = sys.argv[2]

    b = BPF(text=BPF_TEXT.replace("FIRST_NORMAL", str(FIRST_NORMAL_OBJECT_ID)))

    # Populated BEFORE the probes attach, so no event can arrive against an empty target set.
    targets = b["targets"]
    for oid in oids:
        targets[ctypes.c_uint(oid)] = ctypes.c_ubyte(1)

    attachments = (
        ("LockRelationOid", "on_lock", b.attach_uprobe),
        ("LockRelationOid", "on_lock_ret", b.attach_uretprobe),
        ("CommitTransaction", "on_commit", b.attach_uprobe),
    )
    for sym, fn, attach in attachments:
        try:
            attach(name=BIN, sym=sym, fn_name=fn)
        except Exception as exc:  # noqa: BLE001 -- fatal, and the reason matters
            print(f"lock_view: could not attach {fn} to {sym}: {exc}", file=sys.stderr)
            return 1

    out = open(out_path, "w")
    running = {"go": True}

    def on_event(ctx, data, size):
        e = b["events"].event(data)
        out.write(json.dumps({
            "ts": e.ts, "pid": e.pid, "oid": e.oid, "mode": e.mode,
            "kind": "lock" if e.kind == 0 else "commit", "wait_ns": e.wait_ns,
        }) + "\n")

    b["events"].open_ring_buffer(on_event)
    signal.signal(signal.SIGINT, lambda *_: running.__setitem__("go", False))
    signal.signal(signal.SIGTERM, lambda *_: running.__setitem__("go", False))

    print("READY", flush=True)

    while running["go"]:
        b.ring_buffer_poll(100)
    b.ring_buffer_poll(200)

    # Requests still pending at teardown never got a grant either. Counting them here, rather than
    # letting them evaporate, is what keeps "unmatched" honest.
    unmatched = b["unmatched"][ctypes.c_int(0)].value + len(list(b["pending"].items()))
    out.write(json.dumps({"dropped": b["dropped"][ctypes.c_int(0)].value,
                          "unmatched": unmatched}) + "\n")
    out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Verify it compiles and attaches**

```bash
docker compose --profile locktrace up -d
docker exec pgpm_test-locktrace sh -c \
  'timeout 10 python3 /repo/bench/lock_view.py 16567 /tmp/probe_smoke.jsonl; echo "exit=$?"'
```

Expected: `READY` on stdout, then `exit=124` from timeout. A non-zero exit before `READY`, or an attach error naming `on_lock_ret`, means the uretprobe did not take, which is the one genuinely new risk in this task.

- [ ] **Step 3: Verify it captures a real tick with nothing lost**

```bash
docker exec pgpm_test-locktrace psql -U postgres -q -c 'create database lv_smoke'
docker exec pgpm_test-locktrace psql -U postgres -d lv_smoke -q -f /repo/pgpm_core/install.sql
docker exec pgpm_test-locktrace psql -U postgres -d lv_smoke -qtA \
  -c "create table public.t (id bigint primary key, v text)" \
  -c "insert into public.t select g, 'x' from generate_series(1,1000) g" \
  -c "call pgpm.transmute('public.t','id',1000::bigint, p_paused => false)"
OID=$(docker exec pgpm_test-locktrace psql -U postgres -d lv_smoke -qtA \
  -c "select 'public.t'::regclass::oid")
docker exec -d pgpm_test-locktrace sh -c \
  "python3 /repo/bench/lock_view.py $OID /tmp/lv.jsonl > /tmp/lv.log 2>&1"
until docker exec pgpm_test-locktrace grep -q '^READY' /tmp/lv.log; do sleep 1; done
docker exec pgpm_test-locktrace psql -U postgres -d lv_smoke -qtA -c 'call pgpm.maintain_all()'
docker exec pgpm_test-locktrace pkill -INT -f lock_view.py
until ! docker exec pgpm_test-locktrace pgrep -f lock_view.py; do sleep 1; done
docker exec pgpm_test-locktrace tail -1 /tmp/lv.jsonl
docker exec pgpm_test-locktrace sh -c "grep -c . /tmp/lv.jsonl"
```

Expected: the last line is `{"dropped": 0, "unmatched": 0}`, and the event count is in the hundreds rather than the tens of thousands. A count in the tens of thousands means the catalog exclusion is not being applied, so check that `FIRST_NORMAL` was substituted.

- [ ] **Step 4: Commit**

```bash
git add bench/lock_view.py
git commit -m "feat(bench): eBPF capture pairing lock requests with grants (#392)"
```

---

### Task 5: The harness, end to end, and the docs

**Files:**

- Create: `bench/lock_view.sh`
- Modify: `bench/README.md`

**Interfaces:**

- Consumes: `bench/lock_view.py` from Task 4, `bench/plot_lock_view.py` from Tasks 1 to 3.
- Produces: `bench/lock_view.sh <container> <db> <relations> <sql> [run-name]`, writing a run directory and a figure.

- [ ] **Step 1: Write the harness**

```bash
#!/usr/bin/env bash
# Render a lock sequence for human review (issue #392). NOT a guard: it asserts nothing about pgpm's
# behaviour and blocks no merge. bench/lock_trace.sh is the guard; this is the picture.
#
# Usage: lock_view.sh <container> <db> <relations> <sql> [run-name]
#   lock_view.sh pgpm_test-locktrace mydb 'public.mg_ret,public.ml' "call pgpm.maintain_all()"
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; RELS="${3:?relations}"; SQL="${4:?sql}"
RUN="${5:-run}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results/lockview-$RUN-$(date +%Y%m%d-%H%M%S)"
EVENTS=/tmp/pgpm_lock_view.jsonl
PLOG=/tmp/pgpm_lock_view.log

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }

# Asserted up front so that losing it is legible, rather than a BCC compile error a hundred lines
# into a log.
if ! docker exec "$C" python3 -c 'import bcc' 2>/dev/null; then
  echo "error: $C has no bcc. Start the locktrace service:" >&2
  echo "  docker compose --profile locktrace up -d" >&2
  exit 1
fi

mkdir -p "$OUT"
OIDS=$(q "select string_agg(c.oid::text, ',') from unnest(string_to_array('$RELS', ','))
          r join pg_class c on c.oid = trim(r)::regclass")
[ -n "$OIDS" ] || { echo "error: none of '$RELS' resolved" >&2; exit 1; }

# The name map, snapshotted DURING the window. The three folds are SQL joins because that is where
# they belong: index to its table, toast to its table, partition to its managed parent. Resolving
# any of this afterwards fails for the relations most worth seeing, since retain drops them.
names_snapshot() {
  docker exec "$C" psql -U postgres -d "$DB" -qtA -F, -c "
    select c.oid,
           n.nspname||'.'||c.relname,
           coalesce(
             (select pn.nspname||'.'||pc.relname from pg_class pc
                join pg_namespace pn on pn.oid = pc.relnamespace
               where pc.oid = i.indrelid),
             (select pn.nspname||'.'||pc.relname from pg_class pc
                join pg_namespace pn on pn.oid = pc.relnamespace
               where pc.reltoastrelid = c.oid),
             (select p.parent_table::text from pgpm.part p
               where p.child_name = c.relname),
             ''),
           case when c.relkind = 'i' then 'index'
                when n.nspname = 'pg_toast' then 'toast'
                when exists (select 1 from pgpm.part p where p.child_name = c.relname)
                  then 'partition'
                else 'other' end
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      left join pg_index i on i.indexrelid = c.oid
     where c.oid >= 16384"
}

names_snapshot > "$OUT/names.before.csv"

docker exec "$C" sh -c "rm -f $EVENTS $PLOG"
docker exec -d "$C" sh -c "python3 /repo/bench/lock_view.py $OIDS $EVENTS > $PLOG 2>&1"

# Gate on READY, never on anything printed earlier: it is the only line that means the uprobes are
# attached AND the ring buffer is open.
ready=false
for _ in $(seq 1 90); do
  if docker exec "$C" grep -q '^READY' "$PLOG" 2>/dev/null; then ready=true; break; fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "error: probe never became READY" >&2
  docker exec "$C" cat "$PLOG" >&2
  docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
  exit 1
fi

# The probe's bpf_ktime_get_ns() and the host's CLOCK_MONOTONIC are the SAME clock domain (same
# kernel), verified on the design spike. Clocks cross the container boundary; pids do not.
T_BEGIN=$(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$SQL" >/dev/null 2>&1
T_END=$(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')

# SIGINT then WAIT: the drop count is written on the way out, and reading early truncates the very
# record that says whether anything was lost.
docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
for _ in $(seq 1 30); do
  docker exec "$C" pgrep -f lock_view.py >/dev/null 2>&1 || break
  sleep 1
done

names_snapshot > "$OUT/names.after.csv"
docker cp "$C:$EVENTS" "$OUT/events.jsonl" >/dev/null

python3 - "$OUT" "$RUN" "$SQL" "$RELS" "$OIDS" "$T_BEGIN" "$T_END" <<'PY'
import json, subprocess, sys
out, run, sql, rels, oids, t0, t1 = sys.argv[1:8]
sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                     capture_output=True, text=True).stdout.strip()
open(f"{out}/meta.json", "w").write(json.dumps({
    "run": run, "sql": sql, "enlist": rels.split(","),
    "enlist_oids": [int(o) for o in oids.split(",")],
    "t_begin": int(t0), "t_end": int(t1), "git_sha": sha,
}, indent=2) + "\n")
PY

python3 "$ROOT/bench/plot_lock_view.py" "$OUT" || exit 1
echo "wrote $OUT/lock-view.png and .svg"
```

- [ ] **Step 2: Add the renderer's CLI entry point**

Append to `bench/plot_lock_view.py`:

```python
def main(argv) -> int:
    import argparse
    p = argparse.ArgumentParser(description="Draw a lock-sequence capture.")
    p.add_argument("run_dir", type=pathlib.Path)
    p.add_argument("--modes", choices=("all", "strong"), default="all")
    args = p.parse_args(argv)
    try:
        cap = load_capture(args.run_dir)
    except Refused as exc:
        print(f"refusing to draw this capture -- {exc}", file=sys.stderr)
        return 1
    stamp = render(cap, args.run_dir, modes=args.modes)
    print("  " + "  ".join(f"{k}={v}" for k, v in stamp.items()))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 3: Run it end to end against the guard's own fixture**

```bash
chmod +x bench/lock_view.sh
docker compose --profile locktrace up -d
bench/lock_view.sh pgpm_test-locktrace lv_smoke 'public.t' "call pgpm.maintain_all()" smoke
```

Expected: a run directory under `bench/results/`, a printed stamp with `dropped=0 unmatched=0`, and a PNG whose rows are labelled with real relation names rather than `created during the window`. Widespread `created during the window` labels mean the name snapshot ran against the wrong database.

- [ ] **Step 4: Re-run the self-test against a freshly captured fixture**

The golden fixture from Task 1 predates the uretprobe, so it carries no `wait_ns` and no `parent` column. Replace it with the capture just taken, which exercises the real producer:

```bash
cp bench/results/lockview-smoke-*/events.jsonl      bench/fixtures/lockview/golden/events.jsonl
cp bench/results/lockview-smoke-*/names.before.csv  bench/fixtures/lockview/golden/names.before.csv
cp bench/results/lockview-smoke-*/names.after.csv   bench/fixtures/lockview/golden/names.after.csv
cp bench/results/lockview-smoke-*/meta.json         bench/fixtures/lockview/golden/meta.json
python3 bench/lock_view_selftest.py
```

The two counts in Task 2's fold test (`261` and `10`) are properties of the SPIKE's fixture, not of this smoke fixture. Update both assertions to the new fixture's measured values, and record the measurement in the comment above them. Do not delete the assertions: a fold test with no expected row count is not a test.

- [ ] **Step 5: Document it**

Add a section to `bench/README.md` covering: what the tool is for and that it is not a guard; the invocation; the prerequisite (`docker compose --profile locktrace up -d`, plus `pip install matplotlib`); where output lands and that `bench/results/` is ignored with a `git add -f` escape for sharing one; the four refusals and why a capture that trips one is not drawn; and a pointer to the spec.

- [ ] **Step 6: Lint the docs**

```bash
npx -y markdownlint-cli2@0.13.0 "**/*.md" \
  "!postgresql_online_partition_migration_summary.md" "!bench/results/**" "!.venv-verify/**"
```

Expected: `Summary: 0 error(s)`.

- [ ] **Step 7: Verify the guard is untouched**

```bash
git diff --name-only main... | grep -E 'lock_probe|lock_trace|discriminate|mutations|workflows' \
  && echo "STOP: this plan must not touch the guard" || echo "guard untouched, as intended"
./test.sh locktrace
```

Expected: `guard untouched, as intended`, then `locktrace track: PASS`. The second command is the one that matters: it proves this work did not disturb the instrument it sits next to.

- [ ] **Step 8: Commit**

```bash
git add bench/lock_view.sh bench/plot_lock_view.py bench/README.md bench/fixtures/lockview/golden
git commit -m "feat(bench): lock_view.sh, end to end, with docs (#392)"
```

---

## Self-review

**Spec coverage.** Architecture's three files map to Tasks 4, 5 and 1 to 3. The nine harness steps are Task 5 Step 1. Clock correlation is Task 5 Step 1. Formats and the before-union-after name map are Task 1 Step 4. The capture contract's four refusals are Task 1. The fold and its measured row count are Task 2. Mark shape, density, commits, palette and the drop ring are Task 3. Requests, grants and the unmatched rule are Task 4. The twice-exercised refusals are Task 1 Step 2. Non-goals are enforced by Task 5 Step 7.

**Two spec items are deliberately deferred, and both are stated rather than dropped:**

- The `pgpm.log` cross-check by range bound (spec, Verification item 2) is not implemented in any task. It needs a `lo`/`hi` join the harness does not yet emit, and the figure is useful without it. It belongs in a follow-up, not smuggled into Task 3.
- The drop ring for partitions absent from the after snapshot (spec, The figure) is described but not coded in Task 3 Step 3. Add it there when implementing, or file it with the cross-check above.

**Placeholder scan.** No TBDs. Every code step carries runnable code. Expected outputs are exact strings or exact numbers.

**Type consistency.** `Capture`, `Relation`, `Refused`, `CHECKS`, `load_capture`, `fold_rows` and `render` are defined in Task 1 or 2 and used with the same names and signatures in Tasks 3 and 5. `wait_ns` is optional in the reader (Task 1 and 3) and always written by the producer (Task 4), which is what lets a capture from the guard's probe load here too.

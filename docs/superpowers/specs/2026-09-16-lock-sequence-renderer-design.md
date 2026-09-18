# Lock-sequence renderer: design

Issue [#392](https://github.com/dventimisupabase/pg_partition_magician/issues/392), which is phase 5
of [#383](https://github.com/dventimisupabase/pg_partition_magician/issues/383). Supersedes the
`animate_lock_graph` capability that shipped with pg-lock-tracer and left with it in
[#391](https://github.com/dventimisupabase/pg_partition_magician/issues/391).

Date: 2026-09-16. Status: design approved, implementation plan not yet written.

## Why this exists

`bench/lock_trace.sh` answers the pass/fail question and answers it with numbers. It cannot show the
*shape* of a tick. The investigative case is real and documented: the `#265` archaeology that
prompted #383 took a full session of `CALL` plus `pg_sleep()` plus single `pg_locks` checks precisely
because there was no continuous picture to read.

This tool is for that case, and only that case. It is not a guard, it blocks nothing, and it runs
when a person asks it to.

## What was measured before anything was designed

Issue #392 required the event count for a backend-wide filter to be measured before a design was
committed, because volume is what made the previous instrument unsound. A throwaway probe (the
guard's, with its two oids changed from a record filter into an enlistment predicate) was run against
`bench/lock_trace.sh`'s fixture verbatim on 2026-09-16, kernel 7.0.0-31.

| measurement | value |
| --- | --- |
| wide capture | 16,591 events (16,578 locks, 13 commits) |
| narrow baseline, same trace | 105 events |
| ratio | 158x |
| dropped, counted in-kernel | 0 |
| traced span | 224 ms |
| mean rate | ~74,000 events/s |
| distinct backends | 1 |
| distinct relations | 346 (261 user, 85 catalog) |
| catalog share of locks | 79.9% |
| relations unresolvable after the tick | 116 of 261 user relations (44%) |

Four conclusions follow, and each one decides part of the design below.

1. **The instrument holds at this volume.** Zero drops at 158x the guard's load, on the same 64-page
   ring buffer. `BPF_RINGBUF` plus in-kernel filtering does not reproduce pg-lock-tracer's silent
   overflow. This is the fact the whole design rests on.
2. **A backend-only filter is the wrong filter.** Catalog traffic is 79.9% of it. The guard's own
   11.1 ms interval holds 1,642 events, of which 1,535 are catalog locks and 7 are the commits anyone
   is looking for.
3. **Post-hoc oid resolution is not viable, empirically.** 44% of user relations stop resolving once
   the tick succeeds, because `retain` drops them.
4. **Per-backend swimlanes are not the artifact.** One backend produces the entire tick.

A second re-analysis of the same capture measured the fold that makes the figure legible: 261
distinct relations collapse to **10 rows**.

## Decisions

| question | decision | why |
| --- | --- | --- |
| who owns the wide capture | a separate `bench/lock_view.py` | no edit to a human tool can reach the CI guard, and renderer edits do not re-trigger `locktrace.yml`'s path filter |
| output medium | matplotlib PNG and SVG | follows `bench/plot_results.py`, the repo's only renderer precedent |
| what it traces | arbitrary SQL the investigator supplies | matches the real use case; the guard's tick is the documented example, not the only subject |
| CI artifact | none | a figure nobody opens when the job is green |
| layout | parent-grouped relation rows | 261 relations fold to 10 rows; commits as rules across all of them |
| request vs grant | add a uretprobe | the gap between request and grant is a wait, and waits are what the investigative case is looking for |

## Architecture

Three files. The split is forced by where the dependencies live, not chosen.

| file | runs | why it cannot live elsewhere |
| --- | --- | --- |
| `bench/lock_view.py` | inside the privileged locktrace container | needs `bcc` |
| `bench/lock_view.sh` | on the host | orchestrates `docker exec`, owns the psql snapshots |
| `bench/plot_lock_view.py` | on the host | needs matplotlib, which the container does not have |

The intermediate between capture and render is **files**, not an in-process handoff: a JSONL capture
plus name snapshots. This is the shape `plot_results.py` already has, and it lets a capture be
re-rendered or shared without re-running the tick.

`bench/lock_view.py` is its own BPF program. It does not import, subclass or patch `lock_probe.py`.
Three differences from the guard's probe:

1. The target oids **enlist a backend** rather than select an event.
2. `oid >= 16384` (`FirstNormalObjectId`) excludes catalog relations **in the kernel**.
3. Targets live in a `BPF_HASH` populated from userspace rather than substituted into the BPF source
   at compile time, so any number of relations can be enlisted. This is not worth retrofitting into
   the guard, which needs exactly two.

Ring buffer size, drop counter and `READY` gating are unchanged, because the spike showed them sound
at 158x the guard's load.

### Duplication, stated rather than hidden

`lock_view.py` and `lock_probe.py` will share roughly 40 near-identical lines of BPF C. Each file
carries a header pointing at the other, naming what differs and why they are deliberately not shared:
the guard's instrument must not move when a human tool changes.

## Data flow and the capture contract

Invocation is one command:

```bash
bench/lock_view.sh pgpm_test-locktrace mydb 'public.mg_ret,public.ml' \
  "call pgpm.maintain_all()" [run-name]
```

Steps:

1. Assert the container exists and carries bcc, with a legible error rather than a BCC compile
   traceback.
2. Resolve the enlist relations to oids via psql.
3. Snapshot names BEFORE, into `names.before.csv`.
4. Start `/repo/bench/lock_view.py` detached. The repo is already bind-mounted read-only at `/repo`,
   so there is no `docker cp`.
5. Gate on `READY`, never on anything printed earlier.
6. Record `t_begin` from `CLOCK_MONOTONIC`. Run the supplied SQL, primed (see "Priming enlistment"
   below): the traced statement is one `docker exec ... psql -c <primer> -c <sql>` invocation, not
   a bare run of `<sql>` alone. Record `t_end`.
7. `SIGINT`, then wait for the process to exit. The drop count is written on the way out, and reading
   early truncates the record that says whether anything was lost.
8. Snapshot names AFTER, into `names.after.csv`.
9. Collect into the run directory and render.

### Clock correlation

The probe's `bpf_ktime_get_ns()` and the host's `CLOCK_MONOTONIC` are the same clock domain, verified
rather than assumed on 2026-09-16: a capture's last event read 117,219.6 s against a host
`CLOCK_MONOTONIC` of 118,080.3 s, 861 s apart, matching when that capture ran.

This is why the x-axis origin is the investigator's statement rather than the first event the probe
happened to catch. Locks taken before `t_begin` are drawn, outside the shaded band, so ambient noise
is never mistaken for the statement's own work. **Amended 2026-09-17 (issue #392 review, finding 1):
one mark is a deliberate exception to this rule -- see "Priming enlistment" immediately below.**

Note the asymmetry with a known trap: **clocks survive the container boundary, pids do not.**
`pg_backend_pid()` reports the container namespace while eBPF reports the initial one (measured on
this fixture: 145 against 71,504). Nothing in this tool joins on `pg_backend_pid()`.

### Priming enlistment (added 2026-09-17, issue #392 review, finding 1)

`bench/lock_view.py` enlists a backend into `watched` only once that backend touches one of the
target oids. That has a consequence the original design did not state: a lock the SAME backend took
EARLIER in the traced statement, before it first touches an enlisted relation, is invisible --
`LOCK other; LOCK target;`, traced as one statement, drops `other` entirely, and nothing in the probe
or the renderer refuses on it. A truncated prefix renders as a complete sequence. The reviewer's
suggested alternative, identifying the backend via `pg_backend_pid()` before running the statement, is
exactly the trap the paragraph above already rules out -- that identifier does not agree between the
container and the kernel, so there is nothing to join it against.

The fix instead exploits `docker exec ... psql -c A -c B`: both run in ONE backend. Immediately before
the traced SQL, the harness issues `select 1 from <first enlisted relation> limit 0` as its own `-c`,
in the same invocation that then runs the traced SQL. That backend is enlisted before the traced
statement executes anything at all. The primer is skipped harmlessly, never fatally, when the first
enlisted relation cannot be selected from: its own `-c` fails, psql (run without `ON_ERROR_STOP`, as
every multi-statement invocation in this script is) reports that and moves on to the next `-c`, and
the exit status checked afterward reflects only the LAST command, so a primer failure never surfaces
as the traced statement having failed.

Two things follow, and both are disclosed rather than hidden:

- **The primer takes a real AccessShare lock, and it appears in the capture** -- the first AccessShare
  mark on the first enlisted relation. It is drawn INSIDE the shaded `[t_begin, t_end]` band, not
  before it, because `t_begin` is recorded on the host before the single `docker exec` that runs the
  primer and the traced SQL back to back; there is no point at which this script can record a
  timestamp between them without giving them separate backends, which would defeat priming
  altogether. `bench/README.md` states this plainly rather than leaving a reader to mistake it for the
  traced statement's own first move.
- **The residual blind spot.** A lock this backend held before the primer cannot exist within one
  fresh `psql` invocation, so there is nothing to miss there. But a lock taken by a DIFFERENT backend,
  before THAT backend first touches an enlisted relation, is still invisible: priming enlists only the
  one backend running the traced statement, and every other session on the server is still enlisted
  the same way this tool always enlisted anyone, on first touch. A rendered figure is a complete
  SUFFIX of the one backend under test from the moment it was primed, never a complete prefix of every
  backend's own locking.

Verified against a live capture (bench/lock_view_prefix_demo.sh): tracing `LOCK other; LOCK target;`
against a backend enlisted on `target`'s oid alone drops `other`'s lock without the primer and
captures it with the primer, against the identical, unmodified probe.

### Formats

`events.jsonl` keeps the guard's shape exactly: `{ts, pid, oid, mode, kind}` per event, plus a final
`{"dropped": N}`. One format, two producers. The spike's analysis ran unmodified against both, which
is worth more than a richer schema.

`names.before.csv` and `names.after.csv` are `oid,name,parent,kind`, where `parent` comes from the
fold joins and `kind` is one of `parent`, `partition`, `index`, `toast` or `other`.

The name map used by the renderer is **before union after**, not before alone. Before catches what
gets dropped; after catches what gets created. A tick does both: 21 marks in the spike's capture were
on relations created during the window (the regrain child and new partitions), absent from the before
snapshot by construction.

`meta.json` carries the run name, SQL text, enlist relations, `t_begin`, `t_end`, git SHA, event
count and drop count.

```text
bench/results/lockview-<name>-<YYYYmmdd-HHMMSS>/
  meta.json  events.jsonl  names.before.csv  names.after.csv
  lock-view.png  lock-view.svg
```

`bench/results/` is `*`-ignored with a documented `git add -f` escape, which is the right convention
for per-investigation scratch that occasionally deserves attaching to an issue.

### The capture contract

A picture is more persuasive than a number, so it is held to a higher bar. The renderer refuses,
loudly, rather than drawing:

| condition | why refusing is right |
| --- | --- |
| `dropped > 0` | a truncated trace rendered as a complete one is the exact failure that made pg-lock-tracer unsound |
| no final `{"dropped": N}` record | the probe was killed before draining; completeness is unknown, which is not the same as fine |
| zero events | an empty chart reads as "no locks were taken", indistinguishable from "the probe attached to nothing" |
| no strong-mode mark on any relation | a tick that did nothing renders as a calm, correct-looking figure |

**Amended 2026-09-16 (whole-branch review, fix 6).** This row originally read "on any ENLISTED
relation". That reading is wrong in general: `retain` takes `AccessExclusive` on PARTITION oids,
never on the enlisted table's own oid, so restricting the check to the enlisted set would refuse
the exact captures this refusal exists to accept. The implementation always checked any relation
in the whole capture, which was right; the spec's stricter wording was the defect, and this row now
says what the code does. Separately, "strong-mode" here means `tier() == "strong"` (ShareRowExclusive,
Exclusive or AccessExclusive), not only `AccessExclusive`: the implementation originally hardcoded a
comparison against `AccessExclusive` alone, which `tier()`'s own three-way split (light/saturated/
strong) made an unreconciled second source of truth for the same classification. Reconciled onto
`tier()`, so a tick whose only strong-tier work was `ShareRowExclusive` or `Exclusive` -- never
`AccessExclusive` itself -- is still recognised as having done real, blocking work.

Every figure is stamped with its event count, drop count, traced span and originating SQL, so one
pasted into an issue carries its own provenance.

## The figure

Rows are managed parents. Three fold rules, all catalog joins taken during the window: index to
`pg_index.indrelid`, toast to `pg_class.reltoastrelid`, partition to `pgpm.part.parent_table`.
Measured on the spike's capture, 261 distinct relations fold to 10 rows:

**Amended 2026-09-17 (issue #392 review, finding 2).** The partition fold is scoped by the parent's
own schema, not by `child_name` alone. `pgpm.part`'s key is `(parent_table, child_name)`, not
`(parent_table, nspname, child_name)`, so two managed parents that share a bare relname in different
schemas (`public.orders` and `archive.orders`, say) can register children with the same bare
`child_name`. A bare-name join matches one child oid against BOTH parents' rows and emits duplicate
CSV rows for it with different `parent` labels; the loader's `out[oid] = Relation(...)` then lets
whichever duplicate reads last win, so locks fold onto the wrong parent nondeterministically.
Partitions live in their parent's own schema, so joining on that schema as well as the bare name is
enough to disambiguate. `bench/lock_view_names_scope_demo.sh` proves this discriminates on a
synthetic two-schema fixture, since the golden fixture (one schema) cannot exercise it.

```text
  2077  public.mg_ret        (32 partitions, their indexes, its toast)
   441  public.ml
   313  pgpm.config
   209  pgpm.part
   174  pg_toast             folds onto its table via reltoastrelid
    85  pgpm.log
    21  created during the window
    11  pgpm.dropped_fk
     2  pgpm.log_id_seq
     1  pgpm.archive_result
```

**Marks are instants, not bars.** The release path is deliberately unprobed, because `UnGrantLock`
takes struct pointers and recovering a relation oid from them means reading fields at offsets that
shift between PostgreSQL versions. A bar drawn from lock to commit would be an inference, and
replacing inference with observation is the reason this instrument exists. The only spans drawn are
the statement band and the request-to-grant wait, both measured.

Legibility at 3,347 user marks:

- `AccessShare` draws as thin low-alpha ticks on each row's baseline. It is 2,527 of the 3,347 and
  would otherwise swamp everything.
- Every other mode draws saturated above the baseline, with `AccessExclusive`, `ShareRowExclusive`
  and `Exclusive` tallest, so the eye lands on boundaries first.
- `--modes strong` drops `AccessShare` entirely, taking the figure to 820 marks (3,347 less 2,527).
- A row whose marks are ALL light-tier is annotated with its exact event count. **Amended
  2026-09-16 (whole-branch review, fix 4b)**: this is the minimal form of the annotation, not a
  general "annotate any overplotted cluster". It exists because a row with only a handful of
  light-tier marks (`pgpm.archive_result` in the golden fixture holds exactly one) renders as
  visually EMPTY at the light tier's alpha, even though the figure's own captured count says
  otherwise; writing the count beside such a row closes that specific legibility gap. A saturated
  or strong-tier row that happens to be visually dense from many overlapping marks is not
  separately annotated -- implementing that general form was judged not worth the added
  complexity against what this fixes, and the minimal form covers the only concrete legibility
  defect found (`pgpm.archive_result`, and equally `pgpm.dropped_fk`'s 11 marks).
- A sparse all-light row additionally draws with a **visibility floor**. **Added 2026-09-18 (issue
  #396)**: the count annotation above says how many events such a row holds, but a count written
  beside a row that still shows nothing leaves the reader with a figure whose stamp claims more
  than it displays, which is the smaller version of the problem the refusals exist to prevent. The
  floor raises alpha and linewidth so the marks are visible at all. It deliberately leaves
  `half_height` at the light tier's value: height is the SEVERITY channel (0.10 light, 0.22
  saturated, 0.34 strong), so a floored light mark must never read as a higher tier than the lock
  actually was. It is density-gated at `VISIBILITY_FLOOR_MAX_MARKS = 25`, because a row of 313
  `AccessShare` events is also all-light and already reads as an unmistakable grey band; flooring
  that row would undo the recession the light tier exists for. Both mitigations stay: the count
  answers "how many", the floor answers "where".

Commits are full-height vertical rules across all rows, because a commit is a backend event rather
than a relation event.

Partitions present in the before snapshot and absent from the after snapshot were dropped during the
window; the renderer rings their last mark. **Implemented 2026-09-16** (whole-branch review, fix 4c):
`load_capture` now reads `names.before.csv` and `names.after.csv` separately before folding them into
the union `Relation` map, specifically so it can still answer "which side did this oid come from"
after the union is built; `Capture.dropped_oids` carries the answer. Verified against the golden
fixture: 29 partitions dropped, all 29 carrying at least one lock event, matching the design spike's
own 29-against-29 cross-check under "Cross-checks printed on the figure" below.

Rows stay plain relation rows when one backend is present and become `(relation, pid)` pairs when
more than one is. The spike saw one backend, but that is a fixture accident rather than a property.
**Implemented 2026-09-16** (whole-branch review, fix 4a): `fold_rows` keys each row on `(label, pid)`
whenever the capture's lock events carry more than one distinct pid, verified with a synthetic
two-backend fixture (the golden fixture itself remains single-backend, so it cannot exercise this
path).

Palette is `plot_results.py`'s, unchanged: `#d2553b` for `AccessExclusive`, `#3ecf8e` for commits,
`#9aa0a6` for light modes, `#1c1c1c` ink. No new colours.

### Requests, grants and waits

`lock_probe.py` uses `attach_uprobe`, which fires at function entry, so every mark in the guard and
in this renderer is a lock **request** rather than a grant. Under no contention the two are
microseconds apart, which is why it has never surfaced; the guard's fixture is single-backend and its
conclusions stand.

`lock_view.py` adds `attach_uretprobe` on the same function, stashing the pending request per pid and
emitting the pair on return. Request to grant is then the one span on the figure that is genuinely
observed rather than inferred, and it is exactly what someone changing lock boundaries wants to see.

This introduces one new failure mode, and it must not be silent. A pending request that never gets a
matching return, from a backend killed mid-wait, would otherwise render as an instant grant: a lost
wait drawn as no wait, which is the silent-overflow defect wearing a different hat. Unmatched entries
are counted and the figure names them. **A wait that was lost track of never renders as a zero-length
wait.**

**Amended 2026-09-16 (whole-branch review, fix 2).** Two corrections to the paragraph above:

1. "capped" never described a real mechanism and is removed. There is no cap, and none is needed:
   `pending` is a `BPF_HASH` keyed by pid, so there is at most one live pending entry per watched pid
   at any moment by construction, not because anything enforces a limit.
2. `unmatched` is reported as its own number, **never folded into the same counter as `dropped`, and
   never made a fifth refusal.** A whole-branch review proposed folding `unmatched` into the `dropped`
   refusal to match this section's original wording more literally; that remedy is rejected. The two
   mean different things: `dropped > 0` means the kernel ring buffer overflowed, so the trace is
   incomplete in an UNKNOWN way, and refusing is right. `unmatched > 0` means a lock request never got
   a matching grant; the trace is COMPLETE and is accurately reporting a wait whose end could not be
   observed, which is the normal, expected shape of an aborted wait under `lock_timeout` -- exactly the
   contention case the uretprobe was added to observe. Refusing on `unmatched` would make the tool
   useless in precisely that case. The split field and the shared red footer tint (drawn from
   `footer_color(dropped, unmatched)`, `plot_lock_view.py`) stay: both still deserve a reader's
   attention on a figure that otherwise reads as calm, short of withholding the figure over either one.

**Amended 2026-09-17 (issue #392 review, finding 3).** `meta.json`'s `producer` key (added by fix 7,
above) named which probe wrote a capture, but nothing read it: `load_capture` never looked at
`producer`, so every capture -- including one from `bench/lock_probe.py`, which writes `ts` at the
REQUEST and has no uretprobe -- was drawn as though its marks were grants with observed waits. A
docstring claiming otherwise was worse than not claiming it at all. Fixed, not refused: the design
still values "one format, two producers" (this section's own point above), so a non-`lock_view.py`
capture is drawn, never rejected. `load_capture` now carries `producer` onto `Capture.producer`
(`""` when the key is absent, treated identically to an explicit `"lock_probe.py"` -- absence IS the
guard's signature), and `render`'s footer stamps a sentence naming the producer and saying plainly
that its `ts` is request time and its waits were not observed, whenever the producer is not
`bench/lock_view.py`.

## Verification

The tool splits into an asserting part and a non-asserting part. The figure asserts nothing. The
capture contract asserts four things, and every one of them is a negative, which is the shape this
repo's recurring defect takes.

### Why `bench/mutations/` is not reused

`mutate.py` is a mutator for `pgpm_core/install.sql`: regex patterns with expected site counts that
refuse to write a mutant when a pattern goes stale. `discriminate.sh` builds a mutant install.sql and
runs a guard against a live database. No install.sql defect makes a renderer draw a truncated
capture. Teaching `mutate.py` to mutate Python would be a large change to machinery every real guard
depends on, in service of a tool deliberately kept off the CI path.

Same discipline, different mechanism.

### Every refusal exercised twice

A self-test builds synthetic capture directories and runs the renderer against each with the check in
place and with that check bypassed:

| fixture | check in place | check bypassed |
| --- | --- | --- |
| `dropped: 5` | refuses | must render |
| no final `{"dropped": N}` | refuses | must render |
| zero events | refuses | must render |
| no strong-mode mark on any enlisted relation | refuses | must render |
| a good capture | renders | renders |

The second column is the point: it proves the named check rejected the capture, rather than a missing
file, a parse error or matplotlib choking on an empty array. Without it, a refusal test passes for
the wrong reason, which is this repo's six-times defect transposed into a new file.

The last row is the liveness witness for the refusals themselves. Without a positive fixture, a
renderer that refuses everything passes the other four.

Fixtures are asymmetric (three relations, two commits, never one and one) so a transposition cannot
cancel. The positive fixture is the spike's real capture, trimmed, rather than hand-written: a
hand-written fixture drifts from what the probe actually emits, while a captured one carries the real
shape, final drop record and created-during-window oids included.

This runs with no eBPF, no container, no database and no Linux, in under a second. Everything else in
this neighbourhood is Linux-only, so that is worth preserving.

### Cross-checks printed on the figure

Three checks, each comparing two independent sources:

1. **Captured against drawn.** "3,347 captured, 3,347 drawn", or "820 drawn (`--modes strong`)". A
   gap not explained by a named filter is visible on the artifact itself.
2. **Drops against `pgpm.log`, by identity.** `pgpm.log` has no child-name column, but it has
   `parent_table, action, lo, hi`, and `pgpm.part` has `child_name, lo, hi`. The partitions the
   figure rings are matched to `retain_drop` rows by range bound rather than counted against them. 29
   against 29 is invariant under a compensating error; the set of bounds is not.
3. **Span against statement.** The traced span must contain `t_begin` to `t_end`. A probe that
   started late or was cut short shows as a band running past the events, drawn rather than hidden.

When a cross-check fails the figure is still drawn, stamped with the discrepancy. The line is:
**refuse when the capture is untrustworthy, annotate when the system is surprising.** A disagreement
between the trace and `pgpm.log` is the thing an investigator is hunting, not grounds for withholding
the picture.

### What this does not claim

None of the above verifies the eBPF capture itself. That remains `lock_trace.sh`'s job on the guard's
side, and `lock_view.py` now carries one probe the guard does not have. The uretprobe's correctness
rests on the same reasoning as the entry probe, scalars read out of registers with no struct reads,
plus the counted-unmatched rule. Stating that boundary is better than implying the self-test covers
more than it does.

Two properties fall on the same side of that boundary and, for the same reason, are proved by a
runnable script rather than a `bench/lock_view_selftest.py` assertion (added 2026-09-17, issue #392
review): priming enlistment (finding 1, `bench/lock_view_prefix_demo.sh`, which needs a live eBPF
capture to show a lock actually disappearing and reappearing) and the schema-scoped name fold
(finding 2, `bench/lock_view_names_scope_demo.sh`, which needs a live database to show the SQL join
actually duplicating a row). Both follow the pattern `bench/lock_timeout_pairing_demo.sh` set:
committed rather than left as prose in a report, and run against the unmodified probe or query so
the same script demonstrates the defect and the fix side by side.

As of 2026-09-18 all three are wired into the `lockview` track as steps 2 to 4 and run in CI. They
were already named in `.github/workflows/lockview.yml`'s path filter before that, which was the
worst of both worlds: editing one fired the job, and the job went green without ever executing it.

## Non-goals

- No CI job, no `actions/upload-artifact`, and nothing added to `./test.sh ci`.
  **Amended 2026-09-18 (issue #398): the capture half now has a CI job and a `ci` track.** The
  reasoning is below; `actions/upload-artifact` is still a non-goal.
- No change to `lock_probe.py`, `lock_trace.sh`, `discriminate.sh` or `bench/mutations/`.
- Not a guard. It asserts nothing about pgpm's behaviour and blocks no merge. **Still true, and it
  is what the amendment turns on:** the `lockview` track asserts nothing about pgpm either.
- Not a lock graph. Wait-for edges were `animate_lock_graph`'s deadlock use case, which is not the
  question this repo asks.
- Not reviving pg-lock-tracer, for the reasons recorded in #391 and in `bench/lock_probe.py`'s header.

### Why the first non-goal was amended (2026-09-18, issue #398)

Recorded rather than silently reversed, because a non-goal that quietly stops being one is the kind
of documentation rot `scripts/check_living_docs.sh` exists to catch.

The original reasoning holds for the FIGURE and not for the PROBE, and that distinction is the whole
argument. Nothing ships on a figure. A wrong one is read by the human who asked for it, and that
human is the one who finds out. The renderer's asserting half is covered cheaply anyway, by
`bench/lock_view_selftest.py` in `lint.yml`, in about 25 seconds with no container.

The capture is different. `bench/lock_view.py`'s worst defect during development was invisible to
everything cheap: `on_lock_ret` paired with whatever sat in `pending[pid]`, so an aborted lock wait
left a stale entry that the next catalog return consumed, emitting a fabricated grant and erasing
the evidence that a wait had been lost. It reported `{"dropped": 0, "unmatched": 0}`, loaded cleanly
through the consumer, and was refused by nothing. An instrument in that state has not failed to
inform its reader; it is telling them the confident opposite of the truth. Prose was all that stood
between a simplification of those twenty lines of BPF C and the defect returning.

So the amendment is deliberately narrow. `.github/workflows/lockview.yml` is path-filtered to the
lock-view files alone and fires on no other change. `./test.sh lockview` runs the same two steps
locally and is wired into `./test.sh ci` on Linux beside `locktrace`, so that "green locally" keeps
meaning what this repo has always made it mean. Neither gates anything about pgpm's behaviour. The
remaining non-goals stand unchanged.

## Follow-up

Filed as [#393](https://github.com/dventimisupabase/pg_partition_magician/issues/393), and fixed on
2026-09-18.

The guard's vocabulary called a lock request a grant (`MG_GRANTS`, "took ACCESS EXCLUSIVE") because
`attach_uprobe` fires at function entry. Its conclusions were never affected, and the argument is
worth recording rather than re-deriving: a backend cannot commit while blocked on a lock it has
itself requested, so the request-based and grant-based intervals contain exactly the same commits.
Neither a false pass nor a false fail was reachable through it.

`bench/lock_trace.sh` now reads `MG_REQUESTS` / `requests` / `last_request`, and its check labels say
"requested" rather than "took". That argument is recorded in the guard's own header, next to the code
it applies to, so the next reader meets it there rather than deriving it again. Touching that file
was outside THIS design, which is why it was filed separately rather than folded in.

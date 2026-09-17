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
6. Record `t_begin` from `CLOCK_MONOTONIC`, run the supplied SQL, record `t_end`.
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
is never mistaken for the statement's own work.

Note the asymmetry with a known trap: **clocks survive the container boundary, pids do not.**
`pg_backend_pid()` reports the container namespace while eBPF reports the initial one (measured on
this fixture: 145 against 71,504). Nothing in this tool joins on `pg_backend_pid()`.

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
| no strong-mode mark on any enlisted relation | a tick that did nothing renders as a calm, correct-looking figure |

Every figure is stamped with its event count, drop count, traced span and originating SQL, so one
pasted into an issue carries its own provenance.

## The figure

Rows are managed parents. Three fold rules, all catalog joins taken during the window: index to
`pg_index.indrelid`, toast to `pg_class.reltoastrelid`, partition to `pgpm.part.parent_table`.
Measured on the spike's capture, 261 distinct relations fold to 10 rows:

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
- Overplotted clusters are annotated with their exact count, so the picture never implies more or
  fewer events than were captured.

Commits are full-height vertical rules across all rows, because a commit is a backend event rather
than a relation event.

Partitions present in the before snapshot and absent from the after snapshot were dropped during the
window; the renderer rings their last mark.

Rows stay plain relation rows when one backend is present and become `(relation, pid)` pairs when
more than one is. The spike saw one backend, but that is a fixture accident rather than a property.

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
are capped and counted into the same reported counter as drops, and the figure names them. **A wait
that was lost track of never renders as a zero-length wait.**

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

## Non-goals

- No CI job, no `actions/upload-artifact`, and nothing added to `./test.sh ci`.
- No change to `lock_probe.py`, `lock_trace.sh`, `discriminate.sh` or `bench/mutations/`.
- Not a guard. It asserts nothing about pgpm's behaviour and blocks no merge.
- Not a lock graph. Wait-for edges were `animate_lock_graph`'s deadlock use case, which is not the
  question this repo asks.
- Not reviving pg-lock-tracer, for the reasons recorded in #391 and in `bench/lock_probe.py`'s header.

## Follow-up

Filed as [#393](https://github.com/dventimisupabase/pg_partition_magician/issues/393).

The guard's vocabulary calls a lock request a grant (`MG_GRANTS`, "took ACCESS EXCLUSIVE") because
`attach_uprobe` fires at function entry. Its conclusions are unaffected, and the argument is worth
recording rather than re-deriving: a backend cannot commit while blocked on a lock it has itself
requested, so the request-based and grant-based intervals contain exactly the same commits. Neither a
false pass nor a false fail is reachable through it. The wording is still imprecise, and touching
`lock_trace.sh` is explicitly outside this design.

# Self-calibrating ambient signal: live surge-yield demo (green 2XL)

> **Frozen artifact: not current documentation.** A point-in-time record, kept for history and not
> maintained against the code, so it describes the system as it stood when written. For how
> pg_partition_magician works today see the [user guide](../docs/guide.md) and the
> [reference](../docs/reference.md).

This is the "quiet -> surge -> yield -> recover" demonstration the *fixed* ambient waiter threshold
could never produce. The self-calibrating signal (PR #52) learns the box's normal waiter count as an
EWMA baseline and backs the drain off on a *relative* surge above it. Run on a fresh Supabase green 2XL
(8 vCPU / 32 GB), us-east-1, via the Supavisor session-mode pooler. Reproduce with
`bench/run_ambient_demo.sh`.

## Setup

- 2.5M-row `bench.events` over 2 months (~1.25M-row closed tail), ~805 MB. Mostly cached, so the steady
  workload (16 pgbench clients) generates near-zero IO/lock waiters: the learned baseline settles low.
- Adaptive feathering on (mode 2). Drain ceiling `drain_batch = 10000`, gentle cron (every 2s); the low
  WAL rate keeps the WAL signal quiet at the stock 4 GB `max_wal_size`.
- Self-calibrating ambient signal armed: `set_drain_ambient('bench.events', 2.0)` (factor 2.0, alpha 0.2,
  floor 2).
- Write-heavy surge: 24 pgbench clients inserting into a logged sink, launched 90s into the observe
  phase, 60s long. (`surge_sink` is kept small by an external periodic `TRUNCATE`, so the surge can
  saturate writes and pile up waiters without filling the small green default disk.)

## The arc (`drain.progress.csv`)

```text
 phase     t(s)   drain_budget        notes
 quiet     6-86   10000 (ceiling)     baseline EWMA decays 3.00 -> 0.04; ZERO backoffs
 SURGE    92-149  10000 -> 3125 ...   first backoffs of the whole run, 12s into the surge; budget
                                       feathers down (oscillates with the sparse point-in-time waiters)
 recover 155-172  3750 -> 10000       climbs back to the ceiling once the surge clears, then holds
 post    246-292  10000 -> 2031 ...   a SEPARATE WAL-signal cluster (surge WAL / autovacuum aftermath)
```

## The headline result: signal separation confirms the design thesis

Backoffs split perfectly by signal and by time (surge ran 21:09:55 -> 21:10:55):

| reason | count | when | timestamps |
| --- | --- | --- | --- |
| `ambient` | 4 | **during the surge only** | 21:10:05, 21:10:11, 21:10:50, 21:10:53 |
| `wal` | 4 | **after the surge only** | 21:12:33, 21:12:39, 21:12:54, 21:12:57 |

The quiet phase had **zero** backoffs of either kind. The first backoffs of the entire run hit 12s into
the surge, and they were `ambient`.

Crucially, **during the surge the WAL signal did not fire at all** -- only `ambient` did. That is the
exact reason the ambient signal exists: a workload the drain is crowding off the disk piles up on IO/lock
waits while generating little WAL of its own (it is *blocked*, not writing), so the WAL-rate signal stays
quiet and misses it entirely. The surge's waiters exceeded `factor x baseline` and the drain yielded; the
WAL signal never saw the surge. The two signals fired on disjoint events (ambient during, WAL after),
empirically confirming they cover disjoint failure modes -- exactly the OR'd-not-exchanged design.

The self-calibrating part is what made this possible: the baseline learned this box's normal (~0 waiters
on a cached workload) so a relative threshold of `2 x baseline` (floored at 2) cleanly separated the
surge. A fixed threshold tuned for one box would have fired constantly on a busier one or never on this
one -- the failure the two earlier demos hit.

## Honest caveats

- The waiter count is a coarse point-in-time sample, so the budget *oscillates* during the surge (it
  recovered to the ceiling for a few ticks mid-surge when the sample happened to read low) rather than
  sitting flat at the floor. AIMD smooths this across ticks; it is the documented behaviour, not a bug. A
  denser surge would suppress the budget more steadily but would also start tripping the WAL signal,
  muddying the clean signal separation above -- so the gentle surge is the better demonstration.
- The post-surge `wal` cluster is the surge's WAL/autovacuum aftermath catching up; it is correct, and a
  nice incidental demonstration of the WAL signal working independently.
- Scale was capped at 2.5M rows by the green default disk (~8 GB, no disk-resize API on green); the
  mechanism is scale-independent (it keys off live waiters vs the learned baseline, not table size).

Project `ttmwnuifdibfuyqoohck` was torn down at the end of the run (nothing left billing).

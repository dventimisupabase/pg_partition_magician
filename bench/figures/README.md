# Bench figures (blog-ready)

Time-series figures rendered from the bench runs in `bench/results/` (gitignored scratch) by
`bench/plot_results.py`. PNG (raster, dpi 140) and SVG (vector, best for the web) are committed here.

Regenerate everything after a new run:

```bash
python3 bench/plot_results.py            # all four
python3 bench/plot_results.py ambient-surge ambient-demo   # one figure, explicit run
```

(Needs `matplotlib`; `pip install matplotlib`.)

## The figures

| file | what it shows | source run |
| --- | --- | --- |
| `01-online-conversion` | A 40M-row table partitioned live under load: rows draining out of the DEFAULT while partitions are created, the workload running throughout. Drained 25M rows in the captured window and keeps going to zero. | `R3-stress` (40M) |
| `02-latency-unnoticeable` | The product thesis: ambient-workload p50/p95 latency holds at the baseline (~76 ms) through the whole conversion; only rare p99 spikes (a couple clip off the top). | `R3-gentle` (40M, pooler) |
| `03-adaptive-feathering` | AIMD in action: the per-tick drain budget rides between the `drain_batch` ceiling and the `drain_batch`/16 floor, halving under WAL/checkpoint pressure (heavy early) and recovering to the ceiling once it clears (late). | `R3-stress` (40M) |
| `04-ambient-surge` | The self-calibrating ambient signal: the learned EWMA baseline tracks this box's normal waiter count, and a relative spike during a write surge feathers the budget down (ambient backoffs in the surge band; the later dip is the separate WAL signal's surge aftermath). | `ambient-demo` (2.5M, green 2XL) |
| `05-scale-ladder` | Online conversion time vs table size, 1M -> 40M; the full closed tail drained to zero at every rung. Throughput peaks ~26k rows/s at 10M then drops to ~12k at 40M as adaptive feathering throttles under WAL/checkpoint pressure, so the time jumps super-linearly. | `R0..R3-stress` (adaptive) |
| `06-fixed-vs-adaptive` | At 40M, the adaptive per-tick budget feathered below the fixed `drain_batch` rate (shaded gap), spending 377 backoffs to stay under WAL/checkpoint pressure. Both modes drained the tail to zero; adaptive took ~35% longer (gentler, but slower). | `R3-stress` vs `R3` |

## Honest notes

- The raw pg_flight_recorder system metrics (WAL rate, checkpoints, `pg_stat_io` over time) lived
  server-side on the now-deleted green instances; only the narrative `pgfr_report.md` summaries survive.
  These figures are built entirely from the drain-side series and the client-side pgbench logs, which are
  on local disk.
- Pre-pooler runs have occasional multi-second latency spikes / zero-tps gaps that are NAT/Tailscale
  connection drops, not the drain. `02` uses a pooler run to avoid them; a clipped p99 spike or two remain.
- The ambient waiter dots in `04` are point-in-time samples at the observe cadence, distinct from the
  per-tick samples the controller actually acted on, so they illustrate the mechanism rather than
  pinpoint each backoff (the per-signal split was confirmed from `pgpm.log`).
- In `06` the feathered budget curve is pure `R3-stress` (adaptive) data, but the fixed vs adaptive *time*
  comparison (27 vs 37 min) is from two separate 40M runs (`R3` plain vs `R3-stress`) that also differ in
  maintenance cadence/profile, not just the adaptive flag, so read the +35% as indicative rather than a
  controlled A/B. The conversion durations and "drained to zero" in `05`/`06` are the authoritative numbers
  from each run's `report.md` (the `drain.progress.csv` sometimes stops logging just before the tail hits
  zero).

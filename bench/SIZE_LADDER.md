# Size ladder: pg_partition_magician load test

Climb rung by rung: a larger run is only worth doing once the one below it has passed
cleanly. A "pilot" is the **smallest** run that exercises the whole pipeline, not a
scaled-down replica of the target; bugs are scale-independent but their cost is not.
Run a rung by editing the `BENCH_*` exports in `bench/run_pilot_green.sh`, or by setting
the env vars directly for `bench/run.sh`.

## The ladder (`BENCH_MONTHS=2`; R3 measured, the rest extrapolated from it)

| rung | `BENCH_ROWS` | ~size | closed tail (~69%) | drain rate | ~drain | ~total | regime |
|------|--------------|-------|--------------------|-----------|--------|--------|--------|
| R0 | 1,000,000 | ~0.3 GB | ~0.7M | ~15k rows/s | ~45 s | ~2–3 min | cache-resident |
| R1 | 3,000,000 | ~0.9 GB | ~2.1M | ~15k rows/s | ~2.3 min | ~5–6 min | cache-resident |
| R2 | 10,000,000 | ~3 GB | ~6.9M | ~15k rows/s | ~7.7 min | ~12–15 min | cache-resident |
| **R3** | **40,000,000** | **~12 GB** | **27.4M** | **15.4k rows/s** | **~30 min** | **~40–58 min** | **cache-resident ✅ done** |
| R4 | 120,000,000 | ~36 GB | ~83M | ~3k rows/s | ~7.7 hr | ~8 hr | disk-bound |
| R5 | ~350,000,000 | ~105 GB | ~242M | ~3k rows/s | ~22 hr | ~22 hr | disk-bound, **>100 GB target** |

**Measured anchors** (Supabase 2xlarge, 8 vCPU / 32 GB RAM, gp3 500 GB / 12k IOPS, PG 17.6):
- **size ≈ 0.30 GB per 1M rows** (heap + the one secondary index), pre-conversion.
- **closed-tail fraction ≈ 0.69** at `BENCH_MONTHS=2` (mid-month run; see the months knob).
- **drain throughput ≈ 15.4k rows/s cache-resident** (R3, measured). **~3k rows/s disk-bound
  is a soft estimate** from earlier project runs; R4 is the first rung that would *measure* it.
- adopt ≈ 8 s metadata cutover (size-independent); online PK build ≈ 1.3 s per 1M rows.

## The regime change is the whole point
Below the instance's RAM (~32 GB → about R3) the working set is cache-resident and the drain
moves ~15k rows/s. Above it (R4+) the drain is heap-random-I/O bound and drops toward ~3k rows/s,
so the **>100 GB online conversion under load is roughly a full day** of drain at the measured
rate. **R4 (120M) is the next honest rung**: it crosses into the disk-bound regime and measures
the real rate, de-risking the R5 estimate. Do not leap R3 → R5.

## Second knob: `BENCH_MONTHS` sets how much is drainable
The drain moves only the CLOSED tail (everything before the current month's partition), so
`BENCH_MONTHS` sets the drained fraction independently of total size (mid-month run):

| `BENCH_MONTHS` | closed (drained) fraction |
|----------------|---------------------------|
| 1 | ~35% |
| 2 | ~69% |
| 3 | ~78% |
| 6 | ~89% |
| 12 | ~94% |

Hold table size fixed and dial drain volume up (more months) or down (fewer), e.g. to stress
the drain harder at a given size, or to shrink a fast rung further.

## Suggested per-rung knobs
| rung | `BENCH_DRAIN_BATCH` | `BENCH_MAINT_INTERVAL` | `BENCH_DRAIN_MAX_SECS` | `BENCH_PHASE_SECS` |
|------|---------------------|------------------------|------------------------|--------------------|
| R0–R1 | 100,000 | `2 seconds` | 600 | 45 |
| R2 | 100,000 | `2 seconds` | 1,200 | 60 |
| R3 | 150,000 | `2 seconds` | 2,700 | 90 |
| R4 | 250,000 | `2 seconds` | 36,000 (10 h) | 180 |
| R5 | 500,000 | `2 seconds` | 90,000 (25 h) | 180 |

(Bigger batches at scale amortize per-batch overhead; whether they lift the disk-bound drain
rate is itself something R4 would measure.)

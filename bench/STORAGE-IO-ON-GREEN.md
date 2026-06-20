# Storage IO on Supabase (green): gp3 vs io2, burst vs provisioned

Findings from probing the disk-IO behavior of a **4XL** project on Supabase **green** staging
(project `crmwxthrnykxhcpizkya`, PostgreSQL 17.6, 16 vCPU / 64 GB RAM), 2026-06-20. Motivation: the
docs claim "4XL+ instances get provisioned/sustained throughput without bursting," while the
compute-addon metadata shows a baseline/burst gap, a direct conflict only a measurement can settle.
Tooling: `bench/io_burst_probe.sh` (`MODE=throughput|iops`).

## The two IO layers (don't conflate them)
1. **Volume**, `gp3` (provisioned IOPS ≤16000 + throughput ≤1000 MiB/s; `POST .../config/disk`;
   ~6 h modification cooldown) or **`io2`** (IOPS-only, *no* `throughput_mibps` field; max ratio
   500:1). Neither has volume-level burst; the provisioned rate is steady.
2. **Instance EBS bandwidth**, from the compute addon `meta`. The **baseline is pinned at
   1048 MB/s from XL all the way through 16XL**; bigger tiers raise only the burst *ceiling*
   (max 4750 @2–4XL, 9500 @8XL, 19000 @16XL). Only the 24XL+ rows show baseline==max=30000, and
   24XL is **not** provisionable on Supabase (16XL is the max). So a bigger tier does **not** raise
   the sustained baseline; it only widens the burst headroom.

## What we measured (4XL)
| axis | gp3 (12000 IOPS / 1000 MiB/s) | io2 (32000 IOPS) |
|------|-------------------------------|------------------|
| **Throughput** | stable ~1 GB/s (volume-bound; the gp3 cap ≈ the 1048 instance baseline, so a throughput probe can't even reach the instance-burst regime) | unchanged (~1 GB/s; io2 is IOPS-only and the instance baseline still binds bandwidth) |
| **IOPS** | flat ~12000 (its provisioned cap was the binding constraint) | **sustained ~15–29k, peak ~33k, 2–2.5× gp3, no depletion knee** |

**Verdict: on 4XL green, storage behaved as *provisioned* on both axes, no clean burst depletion
was observable.** The docs' "provisioned" claim held. io2's concrete payoff is a **higher IOPS
ceiling** (~2.5× gp3), *not* removing a burst; there wasn't a clean one to remove.

## Confounds that fooled earlier attempts (so the methodology is reusable)
- **The 322 s CIC that started this** was on a *2XL*, end-of-day, over the pooler; never reproduced
  on 4XL (CIC was 31 s there). Likely the smaller 2XL instance-bandwidth layer, heavily confounded.
- **A first IOPS probe read "BURSTING" (20k→8k), false.** That was **cache-cooldown** (the build
  warms ~64 GB; early random reads hit it) plus a **concurrency ceiling** (aggregate IOPS ≈
  readers ÷ latency, so 12 sync readers cap ~8k). The 32-reader io2 run reaching ~30k proved the
  8k "floor" was just the gp3 cap + too few readers, not a throttle.
- **`pg_stat_io` lags**: backends flush IO stats only when a query *finishes*, so it reports ~0
  during a long scan then one meaningless spike. **Measure by timing bounded units directly.**

### How to probe IOPS/throughput honestly here
- Lake **must exceed RAM** (64 GB) so reads hit disk, not cache.
- **Many readers** for IOPS (aggregate ≈ readers÷latency) and **time bounded chunks** (ctid-range
  for throughput, single-block ctid fetches for IOPS), never rely on `pg_stat_io` rate for long ops.
- **Exclude the first ~90 s** (cache warmup) and score the knee on steady state; a real burst
  knee falls and *stays*, cache-noise dips *recover*.
- The definitive source for the instance burst-balance itself is the **dashboard "Disk IO Burst
  Balance" chart** (the Management API doesn't expose it).

## Does io2 speed the pgpm conversion? No, on 4XL gp3 was already enough
Ran the gentle R3 (40 M-row) online conversion on gp3-4XL and again on io2-4XL:

| | gp3-4XL | io2-4XL @32000 |
|---|---------|----------------|
| `build_pk` CIC (online PK) | 31.4 s | **31.4 s (identical)** |
| `adopt()` cutover | 1.5 s | 1.5 s |
| convert latency vs baseline | tracks baseline | tracks baseline (p50 75.81 vs 75.54; p99 99.8 vs 79.8; n=53816, full window, no stall) |

The CIC time is **identical**, the one-time index build was never IOPS-starved by gp3's 12000, so
io2's higher ceiling went unused. **io2's ~2.5× IOPS only pays off under *sustained* heavy IOPS; a
one-time conversion doesn't generate it.** The 322 s CIC that originally motivated io2 was a
*2XL/end-of-day/over-the-pooler* confound, never reproduced on 4XL. **Bottom line: gp3-4XL is
sufficient for the pgpm online conversion; io2 is overkill for this workload.**

## Practical guidance
- For **IOPS-bound** work (online `CREATE INDEX CONCURRENTLY`, random access, the pgpm drain under
  scattered IO), **io2 is a real upgrade**, ~2.5× the sustained IOPS of gp3 at the same tier.
- For **throughput-bound** work, gp3 and io2 are the same on 4XL (~1 GB/s, instance-baseline-bound).
- Sustained throughput can't exceed ~1 GB/s on 4XL regardless of volume, that's the instance
  baseline, unchangeable below 24XL (unavailable). Plan IO-heavy setup phases around it.

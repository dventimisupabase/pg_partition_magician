# Banked result: from_hypertable cutover lock window, drained vs undrained (R2 + R3, #170/#176)

The #173 cutover-lock-window bench arm run at scale on Supabase **green**, to see whether the online
pre-drain (#170 tracking delta, #176 append-only tail) shortens the cutover's `ACCESS EXCLUSIVE` window.
Each rung is four arms = {tracking, append-only} x {drained, undrained}, each on its **own fresh 2XL PG15
project with TimescaleDB 2.16.1** (one arm per instance, run in parallel), us-east-1, gp3 12 000 IOPS.
`BENCH_DRAIN_BATCH=5000` (the pre-drain micro-batch and residual threshold), `BENCH_REFINE=0` (the lock
window is at cutover, before any refine). Lock window timed by the harness's `pg_locks` probe.

## Results

| Rung | Path | Arm | **ACCESS EXCLUSIVE window** | whole cutover call | copy |
|------|------|-----|------------------------------|--------------------|------|
| R2 (10M) | tracking (#170)    | undrained | **1.162 s** | 17.8 s | 37.7 s |
| R2 (10M) | tracking (#170)    | drained   | **0.611 s** | 25.8 s | 50.5 s |
| R2 (10M) | append-only (#176) | undrained | **0.433 s** | 20.1 s | 37.9 s |
| R2 (10M) | append-only (#176) | drained   | **0.223 s** | 20.9 s | 37.8 s |
| R3 (40M) | tracking (#170)    | undrained | **3.635 s** | 64.6 s | 230.6 s |
| R3 (40M) | tracking (#170)    | drained   | **1.129 s** | 89.0 s | 230.8 s |
| R3 (40M) | append-only (#176) | undrained | **0.642 s** | 65.2 s | 257.2 s |
| R3 (40M) | append-only (#176) | drained   | **0.625 s** | 65.3 s | 247.1 s |

Conservation held on **all eight arms** (the immutable cohort survived each online migration unchanged).

## What it shows

- **#170 (tracking delta drain): a clear benefit that grows with scale.** The pre-drain shortened the lock
  window ~1.9x at R2 (1.162 -> 0.611 s) and ~3.2x at R3 (3.635 -> 1.129 s). The tracked delta accumulates
  over the **whole** copy (the trigger logs updates/deletes to already-copied rows throughout), so the
  undrained under-lock reconcile grows with copy duration while the drained one stays bounded -- the gap
  widens as the table gets bigger. Note the *whole* cutover call is **longer** when drained (it does the
  pre-drain online), which is the mechanism working: it moves reconcile work off the lock.

- **#176 (append-only pre-drain): correct and works, but not a perf win in this workload.** The R3 windows
  are flat (0.642 vs 0.625 s; R2's apparent 2x was noise on small numbers). The reason is structural: the
  online copy reads the **current chunk last**, so it captures appends as it goes -- only the brief tail
  written after that final read remains to catch up (~5-8k rows here, *independent of copy duration*). So
  the append-only cutover is already brief without pre-draining; there is little backlog for the pre-drain
  to remove. #176 still matters for consistency with the tracking path and for pathological cases (a very
  high append rate, or a long gap between the copy's last-chunk read and the cutover), but it is not the
  headline win that #170 is.

## Caveat on the "at-lock residual" column

The harness reports the catch-up backlog read at **copy-end** (`DELTA_PENDING`), *before* the O(rows) index
pre-build, during which -- on the undrained path -- the delta keeps growing until the lock is taken. So for
undrained arms the reported residual **undercounts** the true at-lock value (e.g. R3 track-undrained reports
2 871 yet the lock ran 3.635 s, implying a much larger at-lock delta). The `pg_locks` lock-window
measurement is the trustworthy metric; the residual is a copy-end approximation. Measuring the exact at-lock
residual would need product-side logging inside the cutover (the external probe cannot read the delta
without holding AccessShare on it and deadlocking the cutover's drop).

## Notes

- Each arm ran on a fresh instance (fresh-instance-per-arm); all instances torn down via the API after.
- Append-only (`p_track_changes => false`) initially crashed the harness (`run_fh.sh` read the backlog from
  the non-existent delta table); fixed to read the append tail (`control > max(dest)`); that fix ships with
  this result.

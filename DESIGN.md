# DESIGN: the operating model of pg_partition_magician

> Internal engineering rationale, not user documentation. The README and the explainer say
> *what* pgpm does and *how* to use it; this note captures *how to think about* what it does to
> the system it runs on, so later refinements share a frame. It is raw material for future work,
> not a build plan or a set of commitments. It grew out of an extended at-scale benchmarking
> exercise (see `bench/`); the point here is to keep the understanding, generalized past the
> particular hardware we measured on.

## Why this note exists

We spent a long stretch characterizing pgpm's performance up and down a size ladder on a specific
substrate (Supabase, which is EC2 instances on EBS volumes). In the process we learned a lot about
the interplay between instance sizes, volume types, volume settings, and pgpm's behavior. The risk
is mistaking that worked example for the whole truth. pgpm is a **PostgreSQL tool, not an AWS or
Supabase tool**, and the model below is the part that transfers.

## 1. The substrate is a variable

Postgres, and therefore pgpm, runs on whatever is underneath it: EC2 + EBS, a Docker container, a
Kubernetes pod, a local NVMe drive, a Raspberry Pi in a closet. What every substrate has in common
is what matters:

- a finite **I/O budget**, some mix of throughput, IOPS, and sometimes burst credits; and
- a **working-set-versus-RAM regime**: cache-resident (the hot set fits in memory) or disk-bound.

The AWS specifics we measured are *one instance* of that general shape, not the shape itself: the
two-layer `min(volume, instance)` cap, the instance EBS baseline pinned across tiers, gp3 versus
io2 as an IOPS lever. Those are recorded as a worked example in
[`bench/STORAGE-IO-ON-GREEN.md`](bench/STORAGE-IO-ON-GREEN.md). Do not over-index on EBS
idiosyncrasies; treat them as a concrete reading of a generic dial that every substrate has.

## 2. Supply and demand

The useful abstraction is economic. The substrate offers **supply**; pgpm imposes **demand**.

**Supply is leftover headroom, not total capacity.** The number that matters is what is left after
the real workload has taken its share, and that is smaller than the nameplate capacity and varies
minute to minute. "Unnoticeable" means living within the leftover.

**Demand is two cost centers, and they have different shapes:**

- **Setup (one-time, and conditional): the `build_pk` CIC.** A partitioned table's primary key must
  include the partition key, so when the existing PK doesn't already, it has to widen (e.g. `(id)` to
  `(created_at, id)`), a lump paid once. The design makes the lumpy parts *non-blocking* so they
  don't violate the invariant below: build the index `CONCURRENTLY` (off the blocking lock), attach
  partitions with the scan-skip trick (`NOT VALID` CHECK then `VALIDATE` under a gentle lock), and
  keep the cutover catalog-only and brief. **This cost is conditional, not inherent.** When the
  partition key is already covered by the existing PK (partitioning on a monotonic `id`, or on a
  `uuidv7` / ULID key, where the key *is* the PK), Postgres's rule is already satisfied and no
  widening is needed; see section 8. In that common case this cost center collapses to zero and only
  the drain remains.
- **Steady (ongoing): the drain** (plus tiny, periodic premake and retention). Moving the closed
  tail out of `DEFAULT` in microbatches is **infinitely divisible**: a batch can be made
  arbitrarily small and spaced arbitrarily far apart.

**The currency of demand is I/O, and its natural unit is the block, not the row and not time.** A
row is not a unit of constant cost, and the clearest reason is TOAST: a row carrying a wide
`jsonb` / `bytea` / `text` value stores it out-of-line in the table's TOAST table, and moving that
row during the drain physically rewrites those bytes (a cross-table `INSERT` cannot move a TOAST
chunk by reference; it detoasts and re-toasts into the destination partition's own TOAST table). So
one "row" can cost a few bytes or a few megabytes; measuring the drain in rows inherits all the
variance of the data model. Time is no better: it is dominated by the substrate (the same work is
fast on NVMe and slow on a depleted burst balance), exactly the variance section 1 warns against.
This mirrors a familiar `pg_stat_statements` habit, where `total_exec_time` is hardware-variant and
noisy while the `shared_blks_{read,hit,dirtied,written}` counters are stable units of actual work.

So the model's unit of account is the **block** (Postgres's 8 KB page, the unit it already uses
wherever it accounts for I/O: `pg_stat_statements`, `pg_stat_io`, `EXPLAIN (BUFFERS)`, the buffer
cache). Blocks have two properties that rows and time lack: they are **hardware-invariant**
(intrinsic to the work, not to the box), and they **subsume TOAST automatically** (a fat row simply
touches more TOAST-table blocks, with no schema-specific accounting). Bytes would be
hardware-invariant too, but the block is the native, already-instrumented unit, so it is the natural
choice; whether an implementation eventually budgets in blocks or raw bytes is a detail that can be
deferred.

## 3. The invariant, and why divisibility makes it satisfiable

The prime directive is: **be unnoticeable. Demand stays safely under supply, leaving the real
workload its headroom.** Everything else is subordinate to this.

Because the drain is divisible, demand can *always* be feathered below any positive supply. That is
what makes the invariant achievable on *any* substrate, from a 16XL down to a Pi. The price you pay
for feathering finer is time.

## 4. Completion is a derived outcome, not a guarantee

Given a supply and a demand held under the invariant, the rate at which pgpm converges toward a
fully-drained table is *determined*, not chosen. On generous hardware it finishes quickly; on
constrained hardware, slowly; on hardware where the leftover supply is near zero, **possibly
never**. There is no free lunch: you cannot have unnoticeable, fast, and tiny-hardware all at once.
Pick two, and the third falls out.

## 5. The `DEFAULT` partition is what makes non-completion safe

This is the keystone that licenses everything above. From the moment of the cutover the table is
correct, online, and partitioned *in form*; rows that haven't been drained yet simply live in the
`DEFAULT` partition and remain fully queryable. So "nominally partitioned but not fully drained" is
a **correct, functioning state, not a failure mode**. That is precisely why completion is allowed
to be optional, and why "slow" or "never" is a tradeoff rather than a bug.

## 6. The operator contract

The model gives the operator an honest, two-sided message:

- **Good news:** partitioned in form, zero downtime, zero interference, and the `DEFAULT` net means
  nothing is ever lost or wrong while the drain catches up.
- **Bad news:** under tight supply the closed tail may drain slowly, or never converge.
- **The lever:** acquire more supply (a bigger tier, a faster volume, io2's higher IOPS), or
  *temporarily* relax the unnoticeable constraint to spend more budget and converge faster. The
  operator chooses where to sit on the tradeoff; pgpm defaults to unnoticeable.

## 7. Modes: one dial, three settings

The operator controls two knobs the model exposes: **the supply** (whether to clear the field of
ambient workload) and **the target** (where to sit on the unnoticeable-versus-fast dial). Three
modes fall out. They are not competing features; they are one mechanism, feathered draining, read
at different points on the same dial.

1. **Unnoticeable / online (today's default).** Supply is the leftover headroom. Demand is feathered
   under it, currently at a fixed gentle rate. Completion is best-effort and possibly never, which
   is safe because of `DEFAULT`. This is pgpm's intended posture.
2. **Adaptive / online (a direction, not built).** Same invariant, but the feather rate becomes
   closed-loop: sense the leftover supply and ride just under it. Faster when there's slack, still
   invisible when there isn't. Removes the arbitrariness of the fixed constant.
3. **Maintenance window / offline (a direction, not built).** The operator clears the field (stops
   serving traffic), so supply jumps to roughly the *full system budget*, and pgpm spends it
   aggressively to converge inside a bounded window. This trades the invariant for speed and a
   completion target, while keeping pgpm's automation and the same correctness (the `DEFAULT` net,
   the online cutover). It is "offline" only because the operator chose to stop serving, not because
   pgpm requires it.

The fixed gentle rate we ship today is just one arbitrary point on this dial. The throttle
primitives that move along it already exist: `drain_batch` (set at `adopt`) and the
`pgpm.maintenance` cron cadence. "Gentle" versus "aggressive" is nothing more than those two knobs.

## 8. Future directions (raw material, not commitments)

- **Adaptive closed-loop feathering (mode 2).** Sense leftover supply (wait events, checkpoint
  pressure, recent latency of the ambient workload, replication lag) and adjust the drain rate to
  ride just under it. The bench already shows the symptoms to watch for: forced checkpoints, temp
  spills, sequential-scan storms are what over-driving looks like.
- **Block-budgeted batching.** Today the drain batches by row count (`drain_batch`), which is unsafe
  when TOAST width varies: 20 000 narrow rows is nothing, but 20 000 rows each carrying a 2 MB
  document is tens of gigabytes rewritten in one microbatch, a spike that breaks the unnoticeable
  invariant and can blow `statement_timeout`. Budgeting a batch by blocks (or bytes) instead bounds
  its I/O footprint regardless of the data model, which is the practical reason for measuring demand
  in blocks (section 2).
- **A maintenance-window estimator (mode 3's helper).** Tell the operator how long a window to book,
  reckoned in blocks rather than rows. It needs two inputs: the **work size**, which pgpm can read
  from the catalog (the `DEFAULT`'s heap + TOAST + index `relpages`, scaled by the closed-tail
  fraction, plus the one-time CIC cost), and the **full-budget rate on this substrate** in blocks per
  second, either supplied by the operator or measured by a short on-system **calibration probe**
  (drain a sample at full tilt and measure it). The estimate must be **regime-aware**: cache-resident
  and disk-bound deliver very different rates (the bench measured roughly 15k versus 3k *rows*/s as a
  uniform-width proxy, see [`bench/SIZE_LADDER.md`](bench/SIZE_LADDER.md)), so it is piecewise across
  the RAM crossing and the honest output is a *range* with its regime assumption stated. It is a
  forecast, not a promise: other tenants on shared substrate, run-to-run variance, and the soft
  disk-bound number all mean the window should carry slack.
- **Reuse the existing PK when the partition key already covers it (drop a whole cost center).** Today
  `adopt` always drops the old PK and re-establishes one on the computed columns; when the partition
  key is already in the PK (the `id` and `uuidv7` / ULID cases), those computed columns equal the
  existing PK, so it rebuilds an index identical to the one it just dropped, paying the setup cost
  center for nothing. The optimization is to detect that case and reuse the existing PK index to back
  the parent's PK instead of rebuilding it. The wrinkle: Postgres won't let you drop a constraint
  while keeping its index, so the reuse needs the attach-reconcile path (let `ATTACH PARTITION` match
  the existing index, or `ALTER INDEX parent ATTACH PARTITION child`) rather than the current
  drop-then-rebuild, and it wants a test matrix across PG 15 to 18. The payoff: in the common case the
  setup cost center disappears and only the drain remains.
- **Retention on a semantic axis, via a key-to-time bridge.** Partitioning happens on a *physical*
  axis (the key); operators reason about retention on a *semantic* axis (time, "older than 90 days").
  A mapping from time to key bridges them, so a table can partition on its `id` (no widening, per the
  previous bullet) and still express calendar retention. The bridge comes in three fidelities: (1)
  **exact**, when time is encoded in the key (`uuidv7` / ULID, which `adopt_by_uuidv7` already
  decodes, and Snowflake bigints if the operator supplies the encoding): no approximation, no
  widening, exact calendar retention; (2) **approximate**, for a plain serial `id` alongside a
  co-monotonic timestamp column: record each partition's observed `min`/`max` of that column as its
  id-range closes, then map a cutoff to the nearest boundary and drop only partitions fully below it
  (round toward keeping). Partition-granular retention is already approximate, so this adds just one
  clearly labeled layer; (3) **impossible**, when the table carries no time information at all, so
  retention is by id-range only. Tier 2 is sound only when `id` and the timestamp are co-monotonic
  (backfills, event-time, and out-of-order arrival break it), so it needs a correlation check and an
  honest warning, exactly analogous to `check_uuidv7`'s plausibility sampling and the rejection of
  float keys.

## What already exists toward all this

- The **throttle primitives** are in the product today: `drain_batch` + the maintenance cron cadence.
- The **bench** (`bench/`) is the instrument that measures the supply side and pgpm's demand against
  it; the **size ladder** (`bench/SIZE_LADDER.md`) is the beginnings of the calibration curve; the
  **storage-IO note** (`bench/STORAGE-IO-ON-GREEN.md`) is the AWS worked example of the substrate
  model in section 1.

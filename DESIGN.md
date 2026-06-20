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

- **Setup (one-time): the `build_pk` CIC.** Widening the primary key to include the partition key
  is a lump that must be paid once. The whole design works to make the lumpy parts *non-blocking*
  so they don't violate the invariant below: build the index `CONCURRENTLY` (off the blocking
  lock), attach partitions with the scan-skip trick (`NOT VALID` CHECK then `VALIDATE` under a
  gentle lock), and keep the cutover itself catalog-only and brief.
- **Steady (ongoing): the drain** (plus tiny, periodic premake and retention). Moving the closed
  tail out of `DEFAULT` in microbatches is **infinitely divisible**: a batch can be made
  arbitrarily small and spaced arbitrarily far apart.

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
- **A maintenance-window estimator (mode 3's helper).** Tell the operator how long a window to book.
  It needs two inputs: the **work size**, which pgpm knows (the closed-tail row count via
  `check_default` / the registry, plus the one-time CIC cost), and the **full-budget drain rate on
  this substrate**, which is either supplied by the operator or measured by pgpm with a short
  on-system **calibration probe** (drain a sample at full tilt, measure rows/s). The estimate must
  be **regime-aware**: cache-resident and disk-bound are different rates (we measured roughly 15k
  versus 3k rows/s, see [`bench/SIZE_LADDER.md`](bench/SIZE_LADDER.md)), so it is piecewise across
  the RAM crossing and the honest output is a *range* with its regime assumption stated. This is
  exactly the size-ladder calibration curve turned into an operator-facing forecast. A forecast, not
  a promise: other tenants on shared substrate, run-to-run variance, and the soft disk-bound number
  all mean the window should carry slack.

## What already exists toward all this

- The **throttle primitives** are in the product today: `drain_batch` + the maintenance cron cadence.
- The **bench** (`bench/`) is the instrument that measures the supply side and pgpm's demand against
  it; the **size ladder** (`bench/SIZE_LADDER.md`) is the beginnings of the calibration curve; the
  **storage-IO note** (`bench/STORAGE-IO-ON-GREEN.md`) is the AWS worked example of the substrate
  model in section 1.

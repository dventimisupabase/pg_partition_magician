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
- **Steady (ongoing): the drain** (plus tiny, periodic obtain and retain). Moving the closed
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

A quieter clause in the same contract: **pgpm does not leave.** It is tempting to picture it as a
one-shot converter that transmutes a table, drains it, and exits stage left, but the drain is only the
*backlog*. Keeping live writes landing in real partitions means creating partitions ahead of the
frontier *forever* (obtain), and PostgreSQL ships no mechanism to do that: declarative partitioning
hands you the partition primitives but no policy engine to create, retain, and drop partitions on a
schedule. Someone has to run that loop, whether `pg_partman`, an operator's own cron, or pgpm, so
once you transmute, pgpm stays on as a standing companion, the way `pg_partman` would. Less Houdini than
Merlin: not a travelling act that performs the trick and departs, but a resident steward who keeps
the kingdom's partitions in order long after the coronation. That standing role is also why pgpm,
not the operator, is the natural place to absorb the awkward edges of this corner of PostgreSQL, the
incoming-foreign-key dance of section 8 among them. If a future PostgreSQL ever folded scheduled
partition management into core (which would first want something like `pg_cron` in core, long
discussed among its hackers), the standing job would vanish and the steward, pgpm or `pg_partman`
alike, could step off the stage. On the versions pgpm targets, 15 through 18 and, on the current
trajectory, 19, that day has not come: future partitions do not make themselves, and it might as
well be pgpm that makes them.

## 7. Modes: one dial, three settings

The operator controls two knobs the model exposes: **the supply** (whether to clear the field of
ambient workload) and **the target** (where to sit on the unnoticeable-versus-fast dial). Three
modes fall out. They are not competing features; they are one mechanism, feathered draining, read
at different points on the same dial.

1. **Unnoticeable / online (today's default).** Supply is the leftover headroom. Demand is feathered
   under it, currently at a fixed gentle rate. Completion is best-effort and possibly never, which
   is safe because of `DEFAULT`. This is pgpm's intended posture.
2. **Adaptive / online (IMPLEMENTED).** Same invariant, but the feather rate becomes closed-loop:
   sense the leftover supply and ride just under it. Faster when there's slack, still invisible when
   there isn't. Removes the arbitrariness of the fixed constant. Shipped as the `drain_adaptive` mode
   (off by default); see section 8 for the controller.
3. **Maintenance window / offline (a direction, not built).** The operator clears the field (stops
   serving traffic), so supply jumps to roughly the *full system budget*, and pgpm spends it
   aggressively to converge inside a bounded window. This trades the invariant for speed and a
   completion target, while keeping pgpm's automation and the same correctness (the `DEFAULT` net,
   the online cutover). It is "offline" only because the operator chose to stop serving, not because
   pgpm requires it.

The fixed gentle rate we ship today is just one arbitrary point on this dial. The throttle
primitives that move along it already exist: `drain_batch` (set at `transmute`) and the
`pgpm.maintain` cron cadence. "Gentle" versus "aggressive" is nothing more than those two knobs.

## 8. Future directions (raw material, not commitments)

- **The `transmute` redesign: one function, metadata-only, never rewrites the PK (IMPLEMENTED).** Two
  changes that compose into a sharper, smaller tool. Shipped: the two-overload `transmute`, the no-rewrite
  gate with its ∈-PK reuse and helpful rejection, and the removal of `build_pk_concurrently` and the
  composite-FK recovery path. Tests in `tests/25` (the PK rule) and across the reworked suite;
  cross-version PG 15 to 18.

  *One front door.* The three wrappers (`transmute` / `transmute_by_id` / `transmute_by_uuidv7`) collapse into a
  single `transmute` with two type-safe overloads on the width parameter: `bigint` selects the integer
  grid (`id`), `interval` selects the time grid, within which a `uuid` control column is *treated as*
  `uuidv7`, anything else `time`. This is an assumption, not a detection: PostgreSQL has no UUIDv7 type
  and v7-ness is not knowable from the catalog (the column is just `uuid`), so a `uuid` control column
  opts into time-ordered semantics and the `check_uuidv7` plausibility sampling warns if its values
  look random rather than time-ordered. The kind argument disappears; the width picks the grid and the
  column type picks `uuid`-vs-timestamp. The
  price of type safety is that a bare interval literal is ambiguous between the two overloads, so
  callers write `transmute(t, c, interval '1 month')` (an integer width needs no cast); that is the right
  trade against string parameters that secretly carry meaning. The `_transmute` engine (text params plus a
  kind) is unchanged; the `by_` functions are removed outright (hard replace, acceptable pre-1.0).

  *Never rewrites the primary key.* `transmute` reuses the existing PK when the control column is already
  a **member** of it (Postgres requires a partitioned table's PK only to *include* the partition key,
  not to lead it, so `PK (tenant_id, id)` partitioned by `id` qualifies with zero rebuild, broader
  than today's control-must-lead test), and it works with a table that has no PK at all. If the table
  has a PK that *excludes* the control column, the classic `events(id PRIMARY KEY, created_at)` that
  wants time partitioning, `transmute` refuses and emits a suggested migration (how to get the control
  column into the PK) rather than just erroring. The widening that today's drop-and-rebuild performs
  becomes the operator's deliberate job, not something `transmute` attempts online behind their back.

  *Why this is a net subtraction.* Forbidding widening lets whole subsystems be deleted, not merely
  guarded: the PK drop/rebuild, `build_pk_concurrently` and its `pg_cron` `CREATE INDEX CONCURRENTLY`
  polling, the in-transaction-versus-online build choice, most of the capture-max-identity dance, and,
  because a primary key that never changes means an incoming FK's referenced unique key always
  survives, the entire composite-FK recovery path (`generate_fk_recovery`, the `'drop'` mode's
  denormalization, `dropped_fk`'s composite columns). Every incoming FK becomes the `preserve` happy
  path: the suspend/restore lifecycle stays, the composite path goes. The guarantees become absolute,
  every `transmute` is metadata-only and every incoming FK is preservable, with no "depends whether the PK
  widens" branch anywhere in the tool.

  *The bet.* This cedes the most common legacy case, a `bigint` or UUIDv4 `id` PK alongside a separate
  `created_at`, partitioned on time, which is pg_partman's territory. The trade is deliberate: in the
  era of Snowflake bigints, UUIDv7, and ULID, a single-column time-ordered primary key is the better
  data model, and the gymnastics to retrofit a legacy table onto it belong to the operator (with
  pgpm's guidance) rather than hidden inside an `transmute` that quietly pays an `O(rows)` cost. pgpm
  becomes opinionated and predictable: bring a time-ordered key that *is* your primary key and it
  partitions flawlessly, always online, always cheap. Less ambitious, more reliable, the right trade
  for a background steward.
- **Adaptive closed-loop feathering (mode 2) (IMPLEMENTED).** The drain rate is no longer a fixed
  constant: when `drain_adaptive` is on, each `pgpm.maintain` tick senses checkpoint pressure and
  rides the per-tick row budget just under supply, instead of always draining `drain_batch` rows.

  *The signal (leading).* The **WAL generation rate** versus the rate the checkpointer can sustain. A
  forced checkpoint fires when WAL written since the last checkpoint reaches ~`max_wal_size` before the
  `checkpoint_timeout` timer does, and the I/O storm of that flush is the R3 latency tail (a 40M drain at
  a fixed cadence triggered ~12 forced checkpoints). So the sustainable rate is
  `max_wal_size / checkpoint_timeout`: outrun `drain_wal_high_water` of it (default 1.0, i.e. the
  sustainable rate itself) and a forced checkpoint is coming. Sensing the *rate* (`pg_current_wal_lsn()` deltas, all non-superuser, vs
  the two settings, in `pgpm._wal_sustainable_bps()` / `pgpm._feather_congested()`) lets the drain ease
  off *before* the checkpoint fires. This is the key correction over the first cut, which keyed on the
  forced-checkpoint *counter*: that counter only moves once the storm is already underway, so a reactive
  controller barely changed the tail (a clean fresh-2XL A/B measured it roughly tied with fixed). The
  exact distance-to-threshold would come from `pg_control_checkpoint().redo_lsn`, but that is
  superuser-gated on managed Postgres, so the rate is the accessible proxy; the forced-checkpoint counter
  (`pgpm._forced_checkpoints()`, version-aware: `pg_stat_bgwriter.checkpoints_req` →
  `pg_stat_checkpointer.num_requested` in PG 17) is kept only as a reactive backstop. Wait events and
  ambient latency are further refinements.

  *A known limitation of the threshold (raw material for the next iteration).* The sustainable rate is
  derived from settings (`max_wal_size / checkpoint_timeout`), not from the disk's real capacity. On a
  well-provisioned tier the disk absorbs WAL far faster than that settings-rate implies, so the
  controller throttles to protect a budget the hardware would shrug off, and at the default
  `drain_wal_high_water = 1.0` it can pin the drain to the floor and never finish even when fixed mode
  is perfectly clean (measured directly: a 4XL banished the storms for fixed mode at the stock 4GB
  `max_wal_size`, max 60.7s -> 7.2s, while adaptive over-throttled). Two consequences. (1) The right
  operator move on bigger or write-heavy hardware is to raise `max_wal_size` so the computed sustainable
  rate reflects the disk (which also lifts the controller's threshold and reduces forced checkpoints for
  everyone); on Supabase that GUC is not scaled by compute tier (pegged 4GB) and must be set via the
  CLI. `drain_wal_high_water` is the manual stand-in to widen the threshold per-hardware. (2) A better
  future signal would key off *observed* I/O saturation (checkpoint sync duration, IO-wait) rather than
  the settings proxy, so it self-calibrates to the hardware. A natural companion is for `transmute` to
  inspect `max_wal_size` against the expected drain WAL rate and advise raising it -- the steward
  surfacing the relevant GUC, not just throttling around it.

  *A second, complementary signal: ambient contention (IMPLEMENTED).* The WAL-rate signal is a
  *producer* self-limit -- it stops the drain over-driving WAL into its own checkpoint storms. It does
  **not** make the drain yield to ambient *workload*: a bench surge proved it. When the drain crowds the
  workload off the disk, those backends pile up on IO/lock waits while generating little WAL of their
  own (they are *starved*, not writing), so the WAL signal stays quiet and the drain keeps hogging the
  disk. The fix is a *consumer-priority* signal that sees the contention directly: `pgpm._ambient_io_waiters()`
  counts non-pgpm client backends currently stuck on IO/Lock/LWLock/BufferPin waits, and the controller
  backs off when they spike. The two signals are **OR'd, not exchanged** -- they cover disjoint failure
  modes (over-driving WAL vs starving the workload), so the drain feathers down if *either* fires and
  recovers when *both* are clear.

  *Self-calibrating the ambient signal (IMPLEMENTED).* A *fixed* waiter threshold is the wrong shape: the
  "normal" waiter count is box- and workload-dependent (near zero on an idle box, double digits on a busy
  one where every client occasionally IO-waits), so one constant fires everywhere or nowhere -- two bench
  demos confirmed a fixed threshold could not separate a surge from the baseline. So the signal learns its
  own normal: `drain_ambient_baseline` is an EWMA (smoothing `drain_ambient_alpha`, default 0.2) of the
  per-tick waiter count, and `_ambient_surge` fires when the current count exceeds `drain_ambient_factor`
  times that learned baseline (default factor 0 = off; a typical on-value is 2.0), floored at
  `drain_ambient_floor` (default 2) so an idle box does not back off on a couple of transient waiters. The
  baseline's smoothing is damped 10x during a surge, so a transient spike barely moves it (the surge stays
  visible for its whole duration) while a *sustained* regime shift is still relearned over many ticks --
  and the AIMD floor guarantees forward progress throughout. The old fixed `drain_ambient_max_waiters`
  remains as an optional absolute cap, OR'd on top (0 = off). Both are set with `set_drain_ambient(parent,
  factor, alpha, floor)`. This is the *self-calibrates to the hardware* idea applied to the consumer
  signal, mirroring the WAL signal's settings-derived proxy. Further supply signals (replication lag, an
  ambient-latency delta) plug in as additional OR'd terms; the waiter count is a coarse, point-in-time
  sample, smoothed by AIMD and now the EWMA baseline across ticks. Tests in `tests/26`; cross-version PG
  15 to 18. (Cross-role visibility of `wait_event` needs `pg_monitor`; same-role backends are always
  visible.)

  *The controller.* AIMD, the additive-increase / multiplicative-decrease law TCP uses to ride just
  under a link's capacity: a calm tick recovers the budget up by a small step, a tick whose WAL rate is
  over the high-water mark (or that saw a forced checkpoint) halves it. It is a pure function
  (`pgpm._aimd_next`), unit-tested directly. The
  **ceiling is `drain_batch` itself**, and this is the crux: a bigger per-tick budget is a bigger
  single `DELETE`+`INSERT`, hence a bigger WAL spike per tick, hence *more* checkpoint pressure (the
  very thing being throttled), so the controller must never exceed the operator's tuned rate. Adaptive
  therefore only ever feathers *down* from `drain_batch`; it can never drive harder than fixed mode and
  so cannot worsen the tail. The "faster when there's slack" half of the dial is delivered by the
  operator setting `drain_batch` to their optimistic slack rate, with adaptive automatically backing
  off from it under pressure (the floor, `drain_batch`/16, is the gentlest sustained rate that still
  makes progress; recovery is `drain_batch`/8 per calm tick). It composes with `drain_max_blocks` (the
  controller sets the row target; the block budget still caps wide rows on top). The controller state
  advances only on a tick that did work, so a fully-drained idle table (the standing-steward state)
  never churns config or bloats the log. Tests in `tests/26`; cross-version PG 15 to 18. Left off by
  default: it is mode 2, a deliberate posture, not a silent change to every existing managed table.

  *What the leading signal bought (clean fresh-2XL A/B, R3/40M, one fresh 2XL per arm, drained to
  completion or the 45-min cap).* It is a trade, exactly as the "only feathers down" invariant requires,
  not a free win. At `drain_wal_high_water` 0.7 the controller pinned the budget to the floor (960 of 974
  ticks backed off): convert p99 fell 328 → 212 ms and p95 237 → 155 ms (the workload became genuinely
  unnoticeable below the extreme tail), but the drain throttled to ~24% of disk and did **not** finish
  (9.7M of 26M rows in 45 min). That over-throttling is because the WAL rate is *total cluster* WAL
  (workload + autovacuum + drain), so under a write-heavy workload it stays over a 0.7 threshold even with
  the drain at the floor. The default is therefore **1.0** (back off only when WAL is at/over the
  sustainable rate that actually forces a checkpoint), which lets the drain finish while still capping the
  genuine over-drive; lower values are the gentler, completion-optional end of the dial. The lone
  worst-case `max` spike (tens of seconds) did **not** improve under any setting and persists when the
  drain is a trickle, so it is not drain-WAL-driven (autovacuum on the churned default, the bulk-load
  checkpoint aftermath, or the one attach lock are the suspects) -- a separate problem from the pace.
- **Block-budgeted batching.** Today the drain batches by row count (`drain_batch`), which is unsafe
  when TOAST width varies: 20 000 narrow rows is nothing, but 20 000 rows each carrying a 2 MB
  document is tens of gigabytes rewritten in one microbatch, a spike that breaks the unnoticeable
  invariant and can blow `statement_timeout`. Budgeting a batch by blocks (or bytes) instead bounds
  its I/O footprint regardless of the data model, which is the practical reason for measuring demand
  in blocks (section 2). **Implemented** as the `drain_max_blocks` config knob: `drain_step` caps
  each microbatch at roughly that many heap+TOAST blocks (translated to a row limit via the default's
  average bytes/row) and falls back to the old row cap when unset. Tests in `tests/17`; cross-version
  PG 15 to 18.
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
  `transmute` always drops the old PK and re-establishes one on the computed columns; when the partition
  key is already in the PK (the `id` and `uuidv7` / ULID cases), those computed columns equal the
  existing PK, so it rebuilds an index identical to the one it just dropped, paying the setup cost
  center for nothing. The optimization is to detect that case and reuse the existing PK index to back
  the parent's PK instead of rebuilding it. The wrinkle: Postgres won't let you drop a constraint
  while keeping its index, so the reuse needs the attach-reconcile path (let `ATTACH PARTITION` match
  the existing index, or `ALTER INDEX parent ATTACH PARTITION child`) rather than the current
  drop-then-rebuild, and it wants a test matrix across PG 15 to 18. The payoff: in the common case the
  setup cost center disappears and only the drain remains. **Implemented**: `transmute` detects when the
  partition key already covers the PK (the `id` / `uuidv7` cases) and reuses the existing index in
  place, skipping the drop+rebuild. Tests in `tests/15`; validated flat (single-digit ms) to ~40M rows.
- **Preserve incoming foreign keys on the happy path (no denormalization).** Today `transmute` treats
  every incoming FK the same: refuse (`'error'`) or drop-and-record (`'drop'`), and recovery means
  denormalizing the partition key into the referencing table and rebuilding a composite FK
  (`generate_fk_recovery`). That cost is only real when the PK *widens away* from the referenced key,
  the `time` case (partition on `created_at`, FK references `id`): the single-column unique on `(id)`
  ceases to exist, so a `-> messages(id)` FK is genuinely impossible and a composite `(created_at, id)`
  FK is the only way to keep DB-enforced RI. But on the `id` / `uuidv7` happy path (the same
  partition-key-covers-PK condition as the PK-reuse bullet above), the parent *keeps* its single-column
  PK on `(id)`: a partitioned table's unique key need only *include* the partition key, and here it
  equals it, and Postgres has allowed an FK to *reference* a partitioned table since PG 12. So the
  incoming FK survives against the new parent verbatim, no companion column and no composite key.
  Verified on PG 17: a single-column PK on an id-partitioned table is legal, an incoming FK to it is
  enforced, and that same FK re-added against a drained parent enforces correctly. The catch is
  mechanical, not structural: the drain moves the closed tail through a standalone, not-yet-attached
  child table, so a referenced row is transiently *outside* the parent while it is moved, and a
  `NO ACTION` FK rejects the move (verified: `update or delete ... violates foreign key constraint ...
  still referenced`). So the FK cannot ride through the conversion in place. The design that fits the
  paced, online drain is **drop-at-transmute, re-add-at-completion**: record the incoming single-column
  FKs (as `'drop'` does), run the drain, then re-create each FK against the new parent with
  `NOT VALID` + `VALIDATE` once its referenced ranges are attached, leaving the referencing table
  untouched. Restoration is driven either by `maintain` noticing the closed tail has fully drained,
  or by an explicit `restore_incoming_fks(parent)` the operator runs after `drain_all`. Gating is
  exact: this path applies only when the FK's referenced columns equal the parent's surviving unique
  key; anything else (a different referenced column, a multi-column referenced key, the widening
  `time` case) falls back to the composite-FK recovery. This is a PostgreSQL compositional
  gap, not a pgpm shortcut: declarative partitioning offers FKs that reference a partitioned parent
  and a `DEFAULT` that accumulates rows, but no online, FK-preserving way to relocate those rows into
  dedicated partitions on *any* version pgpm targets. Every alternative was tested and fails. There is
  no in-place `SPLIT PARTITION` (the SPLIT/MERGE feature was reverted before PG 17 and is still absent
  in 17 and 18, verified). `ATTACH`-first is a chicken-and-egg: you cannot attach a partition for
  `[lo,hi)` while the `DEFAULT` still holds rows in that range. And a `DEFERRABLE INITIALLY DEFERRED`
  FK does not rescue it: even a single transaction that moves the row into the child and attaches it
  before commit still fails the deferred check (verified on PG 17), because the row's reappearance via
  a mid-transaction attach of a formerly-standalone child does not satisfy the queued check. So the
  unattached-intermediate move is the only online drain, and dropping the FK around it is the only way
  to keep that move legal, which is exactly what a vanilla operator converting a table with incoming
  FKs is already forced to do by hand. These negative results hold on PG 17 and 18. Open questions for the test matrix (PG 15 to 18): non-`NO ACTION` referential actions
  (`CASCADE` / `RESTRICT` / `SET NULL`) and `DEFERRABLE` FKs, self-referential FKs, several incoming
  FKs on one parent, the `VALIDATE` scan cost on a large referencing table, and the contract when a
  drain never completes (the FK stays dropped and recorded, surfaced by `status`). **Implemented**:
  `p_incoming_fks => 'preserve'` records and drops eligible incoming FKs at transmute (and refuses the
  widening case), and `pgpm.restore_incoming_fks(parent)` re-adds them against the new parent once the
  drain is quiescent; `maintain` calls it automatically. Tests in `tests/19`-`tests/23`,
  cross-version PG 15 to 18. Covered on the id/uuidv7 happy path: single and multiple incoming FKs,
  their referential actions (`CASCADE` / `SET NULL` / `RESTRICT`) and `DEFERRABLE`-ness (both ride
  along in the recorded definition), and self-referential FKs (verified: a single-column FK to a
  partitioned-by-id table is legal and enforced). The self-referential re-add is validating, not
  online, because the referencing side is then the partitioned parent and Postgres rejects a
  `NOT VALID` FK there; acceptable as a one-time step. The lifecycle is managed: a preserve-managed FK
  is **live if and only if the closed tail is empty**. `maintain` suspends (re-drops) a live managed
  FK before any drain that would move referenced rows and restores it once the tail is drained, so a
  later obtain-miss drain neither stalls (`NO ACTION`) nor silently mutates the referencing side
  (`CASCADE` / `SET NULL`, verified on PG 17). `suspend_incoming_fks` shares the drain's subtransaction:
  if it cannot drop a live FK the drain is skipped that tick rather than run past it. `drain_all`
  suspends too. The `dropped_fk` record persists after restore (marked live via `restored_at`) so the
  cycle can repeat.
- **The drain visibility gap is general, not only an FK problem.** The "referenced row transiently
  outside the parent" above is one face of a structural property: the unattached-intermediate move
  means that during a multi-batch drain the already-moved rows of the draining interval are durable
  but not reachable through the parent. A plain `SELECT` against the parent mid-drain *undercounts*
  that interval, and a write through the parent that targets an already-moved row is a silent no-op
  (`0 rows`) until the interval attaches. A fresh `INSERT` is unaffected (it routes to the DEFAULT and
  the next batch sweeps it up), but an upsert (`INSERT ... ON CONFLICT`) against an already-moved row
  misses it, writes a duplicate key into the DEFAULT, and the next batch then stalls the drain on a
  duplicate-key error, so the gap can wedge the drain on tables that upsert into historical ranges, not
  merely no-op. The deciding question for an operator is not whether the data is old but whether a row
  *settles before its interval closes*: append-only facts and `DROP`-based retention are immune, and so
  are mutable-but-time-local entity tables (orders, tickets) as long as the partition interval is
  coarser than the mutation-settling window (the churn then lands while the interval is open, in the
  fully-writable DEFAULT). Only tables that mutate *arbitrarily old* rows (backdated ledgers, historical
  upserts) are genuinely exposed; for those, `drain_all`/`pause` or a different partition axis. This is inherent: Postgres exposes no way to make an
  unattached relation visible through a partitioned parent, and forbids attaching `[lo,hi)` while the
  DEFAULT holds rows in that range. Both rejected fixes were worse: a copy-then-swap (leave rows in
  the DEFAULT, fill the child, then atomic delete+attach) closes the read gap but risks *silent* lost
  updates if the closed tail is mutated mid-copy, strictly worse than today's *loud* anomalies; and a
  UNION view cannot replace the parent (writes, FK targets, and native routing all require a real
  table). So the posture is to be loud about it and offer `pgpm.snapshot(null::parent)`, a read-only
  set-returning function (parent UNION every in-flight child) for consistency-sensitive reads during a
  drain, queried inline. It takes a typed-NULL rowtype anchor rather than a regclass because a
  function's return shape is fixed at plan time and cannot be derived from a regclass value; it recovers
  the table from the anchor's type. It is always fresh (rediscovers the in-flight child each call, so it
  neither double-counts an attached child nor misses a new one) and leaves no object behind, unlike the
  earlier stored-view form which also stranded a view in the user's schema on uninstall. Two inherent
  costs, documented: it is an optimization fence (dynamic-SQL SRF, no predicate pushdown or child
  `CHECK` exclusion, so it materializes the union before filtering), and it does nothing for writes
  (read-only; an already-moved row is a `0 rows` no-op until attach). Single-batch intervals and
  `drain_all` (one transaction) never open the gap, and only the old closed tail is ever affected.
  Implemented: `pgpm.snapshot`, `tests/30`.
- **Retain on a semantic axis, via a key-to-time bridge.** Partitioning happens on a *physical*
  axis (the key); operators reason about retention on a *semantic* axis (time, "older than 90 days").
  A mapping from time to key bridges them, so a table can partition on its `id` (no widening, per the
  previous bullet) and still express calendar retention. The bridge comes in three fidelities: (1)
  **exact**, when time is encoded in the key (`uuidv7` / ULID, which `transmute_by_uuidv7` already
  decodes, and Snowflake bigints if the operator supplies the encoding): no approximation, no
  widening, exact calendar retention; (2) **approximate**, for a plain serial `id` alongside a
  co-monotonic timestamp column: record each partition's observed `min`/`max` of that column as its
  id-range closes, then map a cutoff to the nearest boundary and drop only partitions fully below it
  (round toward keeping). Partition-granular retention is already approximate, so this adds just one
  clearly labeled layer; (3) **impossible**, when the table carries no time information at all, so
  retention is by id-range only. Tier 2 is sound only when `id` and the timestamp are co-monotonic
  (backfills, event-time, and out-of-order arrival break it), so it needs a correlation check and an
  honest warning, exactly analogous to `check_uuidv7`'s plausibility sampling and the rejection of
  float keys. **Implemented** for tier 2: `pgpm.check_time_monotonic` is the additive, read-only
  co-monotonicity check (tests in `tests/16`); recording per-partition min/max and the cutoff-to-key
  mapping remain future work.

## What already exists toward all this

- The **throttle primitives** are in the product today: `drain_batch` + the maintenance cron cadence.
- **Three of the directions above are now shipped**: PK reuse (`tests/15`), block-budgeted batching
  via `drain_max_blocks` (`tests/17`), and the tier-2 co-monotonicity check `check_time_monotonic`
  (`tests/16`). Validating block-budgeted batching at 2M wide rows also surfaced an operational
  footgun, now guarded: a drain creates each child partition as a standalone table and attaches it
  only at the end, so an interrupted drain leaves an un-attached child that `DROP TABLE <parent>
  CASCADE` does not remove. Re-transmuting the recreated table would let the next drain reuse that orphan
  by name and collide on its stale keys. `transmute` now refuses up front when such an orphan exists
  (`tests/18`).
- The **bench** (`bench/`) is the instrument that measures the supply side and pgpm's demand against
  it; the **size ladder** (`bench/SIZE_LADDER.md`) is the beginnings of the calibration curve; the
  **storage-IO note** (`bench/STORAGE-IO-ON-GREEN.md`) is the AWS worked example of the substrate
  model in section 1.

# REDESIGN: bounded-child transmute with on-demand refinement

> A proposal, not a commitment, and not yet built. It describes a successor to the current
> transmute model in which the original table becomes a bounded **coarse child** instead of the
> `DEFAULT` partition, no rows move at cutover, and the historical bulk is split into proper
> partitions lazily ("refined") only when the operator asks. It builds directly on
> [`DESIGN.md`](DESIGN.md), especially section 8, and reuses that note's vocabulary (frontier,
> supply and demand, the block as the unit of account, the unnoticeable invariant, completion as a
> derived outcome). Read DESIGN.md first; this note records only what changes and why.

## Why this exists

Today transmute attaches the original table as the `DEFAULT` partition. That makes the cutover
metadata-only and instant, but it puts the entire history in the `DEFAULT`, and the steady-state
**drain** then reads and rewrites every historical row out of it (INSERT into a new child, DELETE
from the `DEFAULT`, WAL for both, detoast and retoast for wide rows). The drain is the expensive,
perpetual, possibly-never-completing operation the whole supply-and-demand model is built to keep
unnoticeable, and it carries the read-consistency caveat that `snapshot()` exists to paper over.

This redesign moves the historical bulk off that path entirely. The original table is relabeled as
one bounded child and its rows never move. The expensive work becomes a one-time, online,
read-once `VALIDATE` scan at cutover, plus an optional, operator-gated **refinement** that splits
the coarse history into proper partitions by copying (never deleting), so it incurs no dead
tuples, no vacuum, and no bloat.

## What changes, in one breath

At transmute, rename the original to a coarse-child name, create the empty partitioned parent under
the original name, and attach the original as **one bounded child** covering
`[grid_floor(min), B)` (the "monolith"), using a validated `CHECK` so the attach skips its scan.
Create a fresh **empty `DEFAULT`** as a pure safety net. Going forward, `obtain` makes
normal-sized partitions ahead, `retain` drops whole children, and the drain shrinks to the assistant
that keeps the `DEFAULT` empty. The monolith can later be **refined** (coarse to fine, hierarchically)
on demand. The `DEFAULT` keystone is kept; it just no longer stores the history.

## Settled decisions

### 1. The transmute layout

- The original table becomes **one bounded coarse child**, the monolith, covering
  `[grid_floor(min), B)`. `grid_floor(min)` snaps the low edge to the partition grid (all rows
  satisfy it, since `grid_floor(min) <= min`). `B` is a grid boundary chosen **with headroom**
  above the frontier (see the validate-window race below), not merely the next boundary.
- A **fresh empty `DEFAULT`** is created as the safety net. The original is no longer the `DEFAULT`.
- The cutover is online: the heavy `VALIDATE` runs under a gentle `SHARE UPDATE EXCLUSIVE` lock
  before the brief metadata-only `ACCESS EXCLUSIVE` cutover.
- **No row movement, no index rebuild, no PK widening.** The monolith is the original heap, so its
  indexes are reused on attach, and the control column is already in the PK (a standing requirement),
  so there is no `build_pk` CIC. The expensive lumps of the current model are all absent here.
- The monolith doubles as the **current/active partition** until the frontier crosses `B`, then it
  freezes. Refinement only ever touches the frozen part.
- The table registers **paused**, as today; `resume()` goes live. This is unchanged.

### 2. The validate-window race, and the fix

The attach-skip `CHECK` is `control >= grid_floor(min) AND control < B`. From the moment that
constraint exists on the still-live original until the cutover commits, any insert with
`control >= B` is rejected by the constraint and errors to the client. `B` is in the future, so
this only bites if the frontier reaches `B` before the scan finishes.

- **Fix: choose `B` with deliberate headroom**, sized so the `VALIDATE` comfortably completes before
  the frontier could plausibly reach `B`. `obtain` simply skips the few "future" intervals the
  monolith already covers (see the overlap check). This turns the cutover from online-with-an-asterisk
  into genuinely online.

### 3. The `DEFAULT` is repurposed, not removed

- Its role flips from **store plus safety net** to **pure safety net**, normally empty.
- **Keeping the `DEFAULT` empty is load-bearing**, not hygiene. `_create_partition` already has a
  fast path: when the `DEFAULT` is empty it creates partitions the plain way (no scan); when it is
  non-empty it takes the `check_skip` path and validate-scans the `DEFAULT`. This redesign makes the
  empty path the common case, so `obtain` is cheap by construction. A non-empty `DEFAULT` re-incurs
  a scan proportional to its contents, which stays cheap only because the `DEFAULT` never holds the
  bulk.
- **What can land in the net** (all bounded, never the bulk): a leading-edge miss (the frontier
  outruns `obtain`, including during the `obtain_retry_after` backoff); a backdated write below the
  retention floor whose partition was intentionally dropped; a gap write into an uncovered range.
- **NULL control values cannot occur.** The control column must be a member of the PK, and PK columns
  are `NOT NULL`, so the net never sees a NULL and the design never depends on it for NULL handling.
  This also satisfies range partitioning's own non-null-key requirement for free.
- **The drain is demoted to the magician's assistant.** It no longer moves the bulk; it evacuates the occasional
  stray to keep the net empty so `obtain` stays on its plain path. `obtain` already declines to cover
  a range the `DEFAULT` still holds rows for, which defines the assistant's remit.

### 4. The trilemma and the chosen strategy

For the historical bulk you cannot have all three of:

- **(a) cheap transmute** (no redistribution, no transient doubling),
- **(b) bounded peak transient storage** (well under 2x of the bulk during conversion),
- **(c) fine-grained history** (pruning and fine retention on the old data).

`(b)` and `(c)` together are impossible from a single-heap source: reaching fine granularity means
copying essentially all of the bulk into new heaps (about 1x new) while the source still exists
(1x), then dropping the source, so the peak is about 2x, unavoidably, because a single heap can only
be reclaimed by dropping it whole. `DELETE`-as-you-go does not help (Postgres does not shrink a heap
file without `VACUUM FULL`, so the source holds its size until dropped anyway, plus dead tuples).

**Chosen: strategy 2, monolith plus refine-on-demand.** Cheap transmute, fine history when the
operator chooses, accepting a roughly 2x disk spike, the copy IO, and the CPU at refinement time.
These costs are inherent, online-preserving, and buyable (disk is cheap, managed CPU upsizes). The
operator is told to **prearrange about 2x disk** for the refinement they intend to run. The
alternatives are recorded for completeness: strategy 1 (monolith, never refine: coarse history is a
correct permanent terminal state) and strategy 3 (pre-split at transmute: pay the 2x once up front
so future refinements have bounded peaks).

### 5. Hierarchical refinement keeps it online

Because the monolith is one indivisible partition, the swap that replaces it must attach children
covering its whole range at once, and a single-level monolith-to-fine swap attaches `span / interval`
children under `ACCESS EXCLUSIVE` (sub-second for years-of-monthly, a multi-second-to-minute freeze
for a decade-of-daily). So refine **hierarchically**.

- **First pass, monolith to coarse** (for example per-year): a small-N swap, a brief freeze. This is
  the single roughly-2x-of-the-monolith disk event the operator prearranged.
- **Later passes, each coarse child to fine**: small-N swaps again, and transient now bounded to
  about 2x of one coarse unit.

Every swap attaches only a handful of children, so every freeze is a metadata-only blip, the same
class the current cutover already accepts as online. Two pieces of hygiene make the swaps safe:

- **`lock_timeout` plus retry** on each swap, so it never piles up behind a long-running query.
- **Atomic small-N swap is preferred over `DETACH CONCURRENTLY`-plus-sequential-attach**, because the
  concurrent path trades the brief freeze for a transient partial-read window (the `snapshot()` gap
  class). A sub-second freeze beats reopening the read gap.

### 6. Naming

Extend `_part_name` to take `hi` (every caller already has it) and branch:

- If `hi = _grid_next(kind, step, lo)` (an exact-step, fine child), emit the **existing** name
  unchanged, `events_p<lo>`. Every partition that exists today takes this branch, so all current
  names, fixtures, and tests are byte-for-byte unchanged.
- Otherwise (coarse or monolith), emit `events_p<lo>_to_<hi>`, both bounds at the same granularity
  `fmt`. Example monolith: `events_p2015_03_to_2026_07`.

Properties: collision-proof by construction (the full range is in the name, and the `_to_` infix
cannot collide with the fine child at the low edge), reversible, sorts with the family via the `_p`
prefix, zero churn to fine names. The name is a **label, not the source of truth**: `pgpm.part`
holds the authoritative bounds, so the 63-byte identifier limit is a cosmetic concern, never a
correctness one. For the rare long-relname overflow (a limit the fine scheme already shares), fall
back to `events_p<lo>_<8-hex-of-hash(lo||hi)>`.

### 7. The overlap check in `obtain`

The monolith covers `[grid_floor(min), B)`, which overlaps `obtain`'s active-interval candidate
under a non-matching name, so today's name-only guard misses it and `CREATE` errors on overlap. Add
an explicit kind-aware overlap precheck against attached `pgpm.part` rows. Half-open `[a,b)` and
`[c,d)` overlap iff `a < d AND c < b`, expressed with the existing `_native_gt`:

```sql
-- skip candidate [v_lo, v_hi) when it overlaps an existing attached partition
exists (
  select 1 from pgpm.part p
  where p.parent_table = p_parent
    and p.attached
    and pgpm._native_gt(cfg.control_kind, p.hi, v_lo)   -- p.hi > v_lo
    and pgpm._native_gt(cfg.control_kind, v_hi, p.lo)   -- v_hi > p.lo
)
```

- The `attached` filter is deliberate: only attached partitions can cause a `CREATE`/`ATTACH`
  overlap error. This states the real invariant: **ranges are non-overlapping over `attached = true`
  rows only.** During refinement the unattached fine children sit inside the still-attached coarse
  child, so `pgpm.part` legitimately holds overlapping rows transiently.
- Keep the existing name check (idempotency and `pg_class` drift) and the `DEFAULT`-holds-rows check.
- This makes the headroom-on-`B` case work automatically: every candidate inside the monolith is
  skipped, so `obtain` starts creating fine partitions exactly at `B`.
- Cost is fine (`obtain` checks only `obtain+1` candidates); if a huge partition count ever matters,
  restrict the scan to rows with `hi` beyond the frontier, the only ones a forward candidate can hit.
- **Prerequisite:** transmute must record the monolith in `pgpm.part` with its wide range,
  `attached = true`, and the `_to_` name. The monolith is attached directly in transmute (not via
  `_create_partition`), so transmute needs its own insert for it.

### 8. Metadata lives in three tiers

- **`pgpm.part`, the machine tier (already built).** Authoritative, engine-read, no length limit.
- **The table name, the identity tier (required).** Made legible by encoding the range; capped at 63
  bytes; hash fallback for uniqueness. A label over `pgpm.part`.
- **`COMMENT ON TABLE`, the optional human tier.** Unbounded, display-only, never engine-read. Held in
  reserve purely for legibility, never for correctness.

### 9. A consequence worth recording

Because refinement copies and never deletes, and the swap is atomic, **the read-consistency caveat
nearly disappears**. The `snapshot()` gap existed because the drain moved rows through an unattached
child; refinement leaves rows visible in the monolith until the swap commits, so it never opens the
gap, and the demoted assistant drain only ever touches a thin stray population. `snapshot()` remains
for that residual assistant case, but the honest caveat that shaped the current design is largely
retired here.

### 10. The refinement procedure

One primitive, `pgpm.refine(p_parent, p_coarse_child, p_target_step)`, invoked hierarchically.

- **Preconditions, refuse rather than improvise.** The child is a managed coarse row (`attached`,
  `hi <> _grid_next(lo)`); it is **frozen**, `coarse.hi <= _grid_floor(frontier)` (kind-aware), else
  refuse with "partition still active, wait until the frontier passes its upper bound"; and the
  `DEFAULT` holds no rows in its range, else refuse and direct the operator to drain the strays first
  (a thin backdated-below-floor population, if any).
- **Tile** `[coarse.lo, coarse.hi)` into grid-aligned sub-ranges by `p_target_step`.
- **Build standalone children.** For each sub-range,
  `CREATE TABLE <fine_name> (LIKE <parent> INCLUDING DEFAULTS INCLUDING INDEXES INCLUDING CONSTRAINTS EXCLUDING IDENTITY)`,
  the clause `drain_step` already uses and proves attachable, born with its bounding `CHECK`
  validated while invisible. Record each in `pgpm.part` with `attached = false` and the fine
  `_p<lo>` name. These rows transiently overlap the coarse row, which the section 7 invariant allows.
- **Copy without deleting, feathered by the drain's adaptive and ambient controller.**
  `INSERT INTO <fine_i> SELECT * FROM <coarse_child> WHERE control >= lo_i AND control < hi_i`, in
  microbatches governed by `drain_budget` / AIMD / the WAL and ambient signals. This is the reuse
  that makes refinement unnoticeable for free: the drain's feathering applied to copy-into-standalone
  instead of move-into-attached. Parallelizable across children. The frozen precondition makes the
  copy a consistent snapshot. Build one child to completion before the next, so an interrupt loses at
  most one partial child, truncated and recopied on resume (the child is invisible).
- **Swap atomically, small-N, under `lock_timeout` plus retry.**

  ```sql
  -- per coarse child; wrap in a retry loop
  set local lock_timeout = '<short>';
  begin;
    alter table <parent> detach partition <coarse_child>;
    alter table <parent> attach partition <fine_i> for values from (lo_i) to (hi_i);  -- one per sub-range
    -- flip the fine pgpm.part rows to attached = true; delete the coarse pgpm.part row
  commit;
  ```

  On lock-timeout the txn aborts and retries; the copies are already done, so retry is cheap.
- **Drop the vestigial source** after commit (`DROP TABLE <coarse_child>`). No `DELETE`, no dead
  tuples, no vacuum, disk reclaimed.
- **Hierarchical control.** A thin `refine_history` helper (or the operator) calls `refine` first
  with a coarse target (monolith to per-year, the single roughly-2x disk event), then once per coarse
  child with the configured `partition_step` (bounded transient per unit). Same primitive throughout.

### 11. Transmute step ordering and transactionality

The heavy `VALIDATE` must run **outside** the cutover transaction, the lesson the current code records
at line 871: inside, it holds `ACCESS EXCLUSIVE` for the whole scan. Split into two phases, mapping
onto the existing 10-step sequence.

**Phase A, on the live original (online, gentle locks only), before any rename:**

- A0. Eligibility checks, unchanged (kind, float guard, uuidv7 sample, orphan guard, PK membership,
  secondary-unique, incoming-FK capture and drop).
- A1. Compute frontier and `min`; choose `B` = grid boundary with headroom `H` above the frontier.
- A2. Capture identity max(s) (index lookup, as today).
- A3. `ADD CONSTRAINT <monolith_bound> CHECK (control >= grid_floor(min) AND control < B) NOT VALID`
  (brief metadata lock).
- A4. `VALIDATE CONSTRAINT <monolith_bound>` (`SHARE UPDATE EXCLUSIVE`, the one online scan). Then
  re-read the frontier; if it has crept within a safety margin of `B`, abort with "headroom too
  small, retry" (or auto-retry with a larger `B`). Headroom makes this never fire in practice.

**Phase B, the cutover (one transaction, brief, metadata-only):**

- B1. Drop identity on the original; `SET NOT NULL` on control and PK cols (metadata no-ops, since PK
  implies `NOT NULL`).
- B2. `RENAME` original to the monolith name `_p<grid_floor(min)>_to_<B>`.
- B3. `CREATE` parent `LIKE` monolith `INCLUDING DEFAULTS INCLUDING GENERATED PARTITION BY RANGE(control)`
  under the original name.
- B4. Re-establish identity on the parent; advance the sequence past the captured max.
- B5. `ATTACH` the monolith `FOR VALUES FROM (grid_floor(min)) TO (B)`, metadata-only thanks to the
  validated `CHECK`; then drop the now-redundant `monolith_bound`.
- B6. `CREATE` and attach a **fresh empty `DEFAULT`** (scans nothing).
- B7. Parent `PRIMARY KEY` (reuses the monolith's promoted PK index, metadata).
- B8. Recreate secondary indexes as partitioned, attaching the monolith's (today's step 9b, monolith
  in place of the default).
- B9. Register config (`paused`, `default_table` = the new empty `_default`); insert the monolith into
  `pgpm.part` (`lo`, `hi = B`, `attached = true`, `_to_` name); log; record dropped FKs.

Two simplifications fall out. The aggressive autovacuum knobs the current step 9 sets on the draining
default are **dropped**: the monolith is frozen and never drains, so nothing churns. And `obtain` still
does not run inside transmute (no reason to, and the monolith covers up to `B`), but afterward it takes
the cheap plain path because the `DEFAULT` is empty.

### 12. The frozen-monolith rule and refinement policy

Refinability is **derived, no flag**: a coarse row is refinable iff `coarse.hi <= _grid_floor(frontier)`
(kind-aware), which `maintain` evaluates from the frontier it already computes each tick. The monolith
freezes once the frontier crosses `B`.

- **Default off.** Refinement is the heavy roughly-2x operation, so it is operator-gated, consistent
  with completion-being-optional. Manual is `pgpm.refine(...)` on the operator's schedule.
- **Optional auto.** A config opt-in (`refine_enabled`, a target granularity, and a **disk-headroom
  guard**) lets `maintain`, as a low-priority step after obtain/drain/retain, run one bounded
  refinement step per tick on a frozen coarse child, **prioritized by the retention floor** (refine the
  child the floor is crossing, so `retain` can then drop sub-ranges). The headroom guard refuses to
  start a refinement that would not fit in free space, protecting fixed-disk operators.
- `maintain` never blocks on this: not-frozen, `DEFAULT`-not-clear, or insufficient-headroom all defer
  cleanly.

### 13. `untransmute` under the new layout

Today's gate counts non-default attached partitions and refuses if any exist. That breaks two ways
here: the monolith is a non-default attached partition (the gate would fire immediately after
transmute), and empty obtained partitions are non-default attached partitions too (they would trip it
even though the table is fully reversible). **The gate must become monolith-based and data-based, not
count-based.** Three tiers:

- **Tier 1, clean (recommended to build).** While `frontier < B` and no refinement has run, the
  monolith is still the active partition holding the whole table and obtained partitions are empty.
  Reverse is metadata-only: drop live preserved FKs, `DETACH` the monolith, `DROP` the parent and the
  empty `DEFAULT` and any empty obtained partitions, re-establish identity, rename the monolith back,
  re-add FKs, clear `pgpm` state. This is **cleaner than today**, because the monolith is the pristine,
  untouched original (today's default may already be partially drained).
- **Tier 2, foldback (optional).** Once `frontier >= B`, obtained partitions hold post-`B` writes.
  Reverse additionally folds those back into the restored original (`INSERT ... SELECT`, then drop
  them), bounded row movement over recent data only.
- **Tier 3, the one-way door.** After the first refinement the monolith is gone, so reversal would be a
  full merge-rebuild. This is the new door, replacing today's "once draining begins."

### 14. `status()` surfacing

Extend the existing return shape:

- **Split the partition count** into fine versus coarse, predicate `hi <> _grid_next(kind, step, lo)`.
  Add `coarse_partitions bigint`.
- **Surface the refinement backlog**, the new notion of outstanding work now that `default_rows` is
  normally about zero: an `unrefined_span text` (the extent covered by coarse children) plus a
  `history_unrefined boolean`, so the operator sees that pruning and fine retention are suspended over
  that span. Keep `default_rows` / `closed_rows`, which now report only the strays the assistant evacuates.
- **Reuse `inflight_partitions`** (the `attached = false` count, issue #94) to show
  refinement-in-progress. To tell a refinement child from an assistant-drain child, add a small
  `purpose text` tag to `pgpm.part` (`'drain'` or `'refine'`) and report it; deriving it from "range
  sits inside an attached coarse child" also works, but the tag is clearer.

The quiet payoff: because refinement copies-then-swaps and the drain is demoted to the stray-evacuating
assistant, the `snapshot()` read gap nearly disappears, surviving only for that residual case, not the bulk
(echoing section 9).

## Build order

The pieces are independently shippable, and the table is correct and online without refinement
(strategy 1 is a valid terminal state), so they sequence naturally:

1. **Naming and the overlap check** (sections 6, 7), plus transmute recording the monolith `pgpm.part`
   row. Prerequisites for even the never-refine path.
2. **The new transmute layout and ordering** (sections 1, 2, 11): the validated-`CHECK` monolith
   attach, the fresh empty `DEFAULT`, the two simplifications.
3. **The `untransmute` gate change** (section 13, Tier 1).
4. **`status()` coarse-awareness** (section 14).
5. **The `refine` primitive and hierarchical control** (sections 10, 12), last, because the table is
   already correct, online, and partitioned in form without it.

# pg_partition_magician operational runbook

Symptom-driven, step-by-step procedures for operators. When something alerts you, find the matching entry
and follow the steps top to bottom. This is the "do this, then this" book, deliberately distinct from the
other docs:

- the [README](../README.md) is the front door;
- the [user guide](guide.md) explains the *concepts* and how to use pgpm;
- the [reference](reference.md) documents *every* function and catalog object;
- the [explainer](https://dventimisupabase.github.io/pg_partition_magician/) is the visual overview;
- **this runbook** is what you reach for at 2am, when you do not want to reconstruct a procedure from bits
  scattered across the others.

Every entry has the same shape: **Symptom** (how you noticed) -> **What it means** (one paragraph) ->
**Steps** (numbered, copy-paste) -> **Verify** -> **Prevent**.

## Entries

- [Referential-integrity violations after a `preserve` drain](#referential-integrity-violations-after-a-preserve-drain)
- [The history is not splitting into fine partitions](#the-history-is-not-splitting-into-fine-partitions)
- [A write is refused: `no partition of relation ... found for row`](#a-write-is-refused-no-partition-of-relation--found-for-row)
- [Disk is filling during a regrain](#disk-is-filling-during-a-regrain)
- [Storage is not dropping despite a retention policy](#storage-is-not-dropping-despite-a-retention-policy)
- [Re-transmute fails with an orphan-table error](#re-transmute-fails-with-an-orphan-table-error)
- [A `from_hypertable` cutover is slow or its pre-drain will not converge](#a-from_hypertable-cutover-is-slow-or-its-pre-drain-will-not-converge)

## Referential-integrity violations after a `preserve` drain

**Symptom.** Any of: an incoming foreign key on a table that points at a pgpm-managed parent shows as
`NOT VALID`; `pgpm.status()` reports `fks_unvalidated > 0`; `pgpm.log` has `fail_validate_incoming_fk`
rows; or a periodic RI audit (or an application error) flags dangling references into the parent.

**What it means.** You converted with `p_incoming_fks => 'preserve'`. While the **drain** moved
referenced rows (evacuating a stray from the `DEFAULT` through an unattached child), the incoming FK was
dropped, so referential integrity was off on the referencing table for that window. (This is by design and
visible as `status().fks_suspended`; see the guide's
[incoming foreign keys](guide.md#incoming-foreign-keys).) When the drain reached quiescence, pgpm re-added
the FK so it once again enforces every *new* write (as `NOT VALID`), but it could not fully *validate* the
constraint because rows that violate it were written during the window. Those orphans are real RI
violations to reconcile; new writes are already guarded again. The attribution is exact: the FK was valid
when pgpm dropped it, so any orphan present now arose during the window. (Note: **regrain** does *not* open
this window -- it copies, and its swap drops and re-adds the FK within one atomic transaction -- but the
same reconciliation applies if a regrain or retention drops aged, still-referenced history: the re-validate
then finds a true orphan.)

**Steps.**

1. Confirm the state and see which parents are affected:

   ```sql
   select parent, fks_suspended, fks_unvalidated from pgpm.status();
   ```

   `fks_unvalidated > 0` for a parent means an incoming FK was re-added but is blocked from validation. (If
   instead `fks_suspended > 0`, a move is still in flight and the FK is currently fully dropped: let it
   finish, or bound it, before reconciling -- see **Prevent**.)

2. List the blocked foreign keys and how many orphan rows each has:

   ```sql
   select * from pgpm.incoming_fk_orphans('public.events');   -- the managed parent
   -- referencing_table | constraint_name | orphan_rows
   ```

3. Inspect the offending rows so you can decide what to do. For a single-column FK (`reactions.event_id`
   referencing `events.id`, say):

   ```sql
   select r.*
     from public.reactions r                                  -- referencing_table from step 2
    where r.event_id is not null                              -- the FK column(s)
      and not exists (select 1 from public.events p where p.id = r.event_id);
   ```

   For a composite FK, repeat the equality for each referencing/referenced column pair.

4. Reconcile, according to your data model. Choose one per table:

   - **Delete** the orphans if they are junk:

     ```sql
     delete from public.reactions r
      where r.event_id is not null
        and not exists (select 1 from public.events p where p.id = r.event_id);
     ```

   - **Repoint** them to a valid parent key, if they belong elsewhere (an `update`).
   - **Restore** the missing parent rows, if a parent-side delete during the window was the mistake.

5. Finish validating the foreign key(s) now that the data is clean:

   ```sql
   select pgpm.validate_incoming_fks('public.events');        -- returns the number newly validated
   ```

6. **Verify** it is clean:

   ```sql
   select fks_unvalidated from pgpm.status() where parent = 'public.events'::regclass;  -- expect 0
   select * from pgpm.incoming_fk_orphans('public.events');                             -- expect no rows
   ```

   The foreign key is fully valid again.

**Prevent.** Referential integrity is necessarily off while the **drain** relocates referenced rows: the FK
must be dropped so a row can move through an unattached child, and that cannot be avoided. In the monolith
model the conversion itself moves no rows, so the FK is typically restorable immediately after `transmute`
(`select pgpm.restore_incoming_fks('public.events');`); the window opens only if a later drain
actually moves referenced rows. To shrink it: keep `obtain` ahead so strays never accumulate, so the drain
rarely runs; or `pause` heavy referencing-table write bursts while the drain catches up. A `regrain` (manual
or auto) opens no RI window of its own -- the copy never moves a referenced row out of the parent, and the
swap's FK drop/re-add is one atomic transaction. The one regrain-related caveat is data, not timing: if a
regrain or a retention policy drops aged history that is still referenced, the FK re-validates against a real
orphan -- do not retain below rows you still reference.

## The history is not splitting into fine partitions

**Symptom.** `pgpm.status()` shows `history_unregrained = true` and `coarse_partitions > 0` that does not
fall; queries over old data do not prune to a single partition; retention is not reclaiming old data.

**What it means.** After `transmute`, the history lives in one coarse **monolith** partition. That is a
correct, permanent state, but pruning and fine-grained retention are suspended over its span until it is
**regrained** into proper partitions. If you want fine history, regrain has either not been enabled, or it
cannot make progress yet.

**Steps.**

1. See the backlog and whether auto-regrain is on:

   ```sql
   select parent, coarse_partitions, history_unregrained from pgpm.status();
   select parent_table, regrain_to from pgpm.config where regrain_to is not null;   -- auto-regrain targets
   ```

2. If `regrain_to` is null, the history is intentionally coarse. To split it, either enable paced
   auto-regrain or do it by hand once the monolith has **frozen** (the frontier has moved past its upper
   bound `B`):

   ```sql
   select pgpm.set_regrain('public.events', '1 month');   -- paced: one microbatch per maintain tick
   -- or, synchronously now (atomic, one transaction):
   select pgpm.regrain_history('public.events');
   ```

3. If auto-regrain is on but `coarse_partitions` is not falling, check why a tick is not progressing in
   `pgpm.log`:

   ```sql
   select at, action, method from pgpm.log
    where parent_table = 'public.events'::regclass and action in ('skip_regrain', 'regrain')
    order by id desc limit 10;
   ```

   - A `maintain` summary of `regrain=active` means the monolith has **not frozen yet** (the current
     interval still lands in it); it will regrain once the frontier crosses `B`.
   - `regrain=default_dirty` means a stray sits in the monolith's range in the `DEFAULT`; let the
     drain clear it (see the next entry), then regrain resumes.
   - `regrain=copied:N` is healthy forward progress (one budget-sized copy microbatch); `regrain=swapped:K`
     is a completed regrain (K fine children attached). A `regrain_skip` log row is a lock-race deferral, and
     a `regrain_aged` row is a below-horizon sub-range skipped under a retention policy; both are normal.

4. If disk is the constraint, see [Disk is filling during a regrain](#disk-is-filling-during-a-regrain).

**Verify.**

```sql
select coarse_partitions, history_unregrained from pgpm.status() where parent = 'public.events'::regclass;
-- coarse_partitions falling toward 0; history_unregrained false once fully split
```

**Prevent.** Decide up front whether the table needs fine history. If it does, enable `set_regrain` after
`transmute` (or regrain by hand in a maintenance window). If a coarse monolith is acceptable, leave it.

## A write is refused: `no partition of relation ... found for row`

**Symptom.** The application sees

```text
ERROR:  no partition of relation "events" found for row
DETAIL:  Partition key of the failing row contains (id) = (...).
```

**What it means.** pgpm keeps **no `DEFAULT` partition**. `obtain` maintains a grid of real partitions
running `config.obtain` steps ahead of the write frontier, and a row outside that grid has nowhere to go,
so PostgreSQL refuses it. There are exactly two ways to be outside it.

**Above the grid** -- the value is further ahead than the lookahead reaches. Check the ceiling:

```sql
select newest_bound from pgpm.status() where parent = 'public.events'::regclass;
```

Either maintenance has stalled (see below) or the write is genuinely further ahead than
`config.obtain x partition_step`. The latter is common on **id** grids, where the frontier is data-driven
and can jump: a sequence restart, a Snowflake generator, a bulk import carrying its own ids. Time grids
advance predictably and rarely hit this.

**Below the grid** -- the value is older than the retention floor, so its partition was deliberately
dropped. This is correct: retention reclaimed that range. Do not widen retention to make the write
succeed unless you actually want that data kept.

**What to do.**

1. Confirm maintenance is running at all. If `pg_cron` is stopped or the table is `paused`, `obtain` is
   not extending the grid and the ceiling is frozen where it stopped:

   ```sql
   select parent, paused, newest_bound from pgpm.status();
   select jobname, active from cron.job where jobname like 'pgpm%';
   ```

2. If maintenance is healthy and you simply need more headroom, raise the lookahead. It is cheap:
   partitions are empty and creating one is pure catalog work.

   ```sql
   update pgpm.config set obtain = 90 where parent_table = 'public.events'::regclass;
   select pgpm.obtain('public.events');
   ```

3. For a one-off bulk load with known-high ids, extend before loading rather than raising the standing
   lookahead.

**Why there is no `DEFAULT` to catch these.** It used to exist, and a background **drain** evacuated it.
That machine was removed deliberately: it was the only part of pgpm that opened a referential-integrity
window, and it carried its own class of defects. A refused write is loud and immediate; a silent backlog
in a `DEFAULT` was neither.

## Disk is filling during a regrain

**Symptom.** Free space drops while a regrain is running; `pgpm.status()` shows `inflight_partitions > 0`
for the table.

**What it means.** `regrain` **copies** the monolith's rows into new fine partitions and only drops the
source after they are swapped in, so it transiently needs roughly **2x the disk** of the range being
regrained while the copies coexist with the source. On an elastic or auto-scaling volume this is absorbed;
on a fixed volume it can be a problem if you regrain a large coarse child in one shot.

**Steps.**

1. See what is in flight:

   ```sql
   select parent, coarse_partitions, inflight_partitions from pgpm.status();
   ```

2. If you are disk-bound, stop starting new work and let the current regrain finish (it drops its source at
   the swap, reclaiming the transient space):

   ```sql
   select pgpm.set_regrain('public.events', null);   -- pause auto-regrain (the in-flight one still completes)
   ```

3. Regrain **hierarchically** so each step's footprint stays bounded: split the monolith into coarse units
   first (for example per year), then regrain one coarse unit at a time. Each later step only needs ~2x of
   one unit, not of the whole history:

   ```sql
   -- one coarse unit, by hand (target a coarser step first, then the fine step per unit)
   select pgpm.regrain('public.events', '<monolith child name from pgpm.part>', '1 year');
   ```

4. Or acquire more disk: on a managed/elastic volume, grow it (or let auto-scaling absorb the spike), then
   resume `set_regrain`.

**Verify.**

```sql
-- free space recovers after the swap drops the source; the coarse child is gone from pgpm.part
select coarse_partitions, inflight_partitions from pgpm.status() where parent = 'public.events'::regclass;
```

**Prevent.** Before regraining a large history on a fixed volume, prearrange about 2x the headroom of the
span you will regrain, or regrain hierarchically so the transient footprint stays bounded to one unit at a
time. On an elastic volume, no special preparation is needed.

## Storage is not dropping despite a retention policy

**Symptom.** `config.retain` is set, but disk is not falling as old data ages out: aged partitions linger,
or the below-horizon tail sits in the `DEFAULT` and never goes away.

**What it means.** Retention is enforced only while maintenance runs and the drain keeps pace. Two
mechanisms reclaim aged data, both driven by `maintain` on pg_cron:

- `retain()` drops whole materialized partitions older than the horizon (a `retain_drop` log row).
So retention is **best-effort**: if the table is `paused`, or if `maintain_all` is not scheduled, aged
data lingers and storage does not fall. It bounds storage only when maintenance actually runs.
(Watch the unit, too: `retain` is an **interval** for `time`/`uuidv7` and a **count of intervals** for
`id` -- a misread makes the horizon far longer than intended.)

Three more shapes look like this symptom but are working as designed: a `retain_batch` cap paces drops
one batch per tick, so a large aged-out backlog takes several ticks to clear (`retain_backlog` falling
tick over tick is that pacing, not a stall); a child with `config.archive_fn` set defers its own drop
until archiving actually catches up (`retain_backlog` flat with `retain_drop_failures` staying at
**zero** -- this is not a failure, just chunked archiving still in progress); and an unexpected `DROP`
failure blocks that one partition on purpose (`retain_drop_failures` climbing instead).

**Steps.**

1. Confirm the policy is set and that maintenance can act on it:

   ```sql
   select parent, paused, retain_backlog, retain_drop_failures
     from pgpm.status() where parent = 'public.events'::regclass;
   select retain, retain_batch, archive_fn from pgpm.config where parent_table = 'public.events'::regclass;
   ```

   `paused = true` means maintenance is doing nothing. A flat `retain_backlog` with `retain_drop_failures`
   also flat at zero, and `archive_fn` set, means chunked archiving simply hasn't caught up yet for the
   partitions at the head of the backlog -- not a failure, just run more maintenance ticks (or check
   `pgpm.archive_ledger`/`pgpm._archive_fully_covered` for that child directly). A flat `retain_backlog`
   with `retain_drop_failures` actually **climbing** is a real, unexpected `DROP` failure: the error is in
   the log (`retain_drop_fail` rows, `method`).

2. Run a maintenance pass, or force the reclaim by hand:

   ```sql
   call pgpm.maintain('public.events');       -- one pass: obtain, retain, drain (and auto-regrain)
   -- or catch up now, synchronously:
   call pgpm.drain_all('public.events');      -- evacuate / reclaim the closed tail
   select pgpm.retain('public.events');       -- drop aged partitions now
   select pgpm.retire('public.events', 'events_p...');  -- or surgically: drop ONE eligible partition
   ```

3. Confirm reclamation actually happened:

   ```sql
   select at, action, lo, hi, rows from pgpm.log
    where parent_table = 'public.events'::regclass and action in ('retain_drop', 'retain_reclaim')
    order by id desc limit 20;
   ```

**Verify.**

```sql
-- aged partitions are gone; storage falls once the drops are reclaimed
select n_partitions, retain_backlog from pgpm.status() where parent = 'public.events'::regclass;
```

**Prevent.** Keep `maintain_all` scheduled on pg_cron so aged partitions are dropped in time, and do not leave a
managed table `paused` if you rely on retention to bound storage. A lagging or paused drain turns retention
into best-effort.

## Re-transmute fails with an orphan-table error

**Symptom.** `transmute` refuses up front with an error like:

> pg_partition_magician: public.events_p2026_03 already exists as a standalone table matching this
> parent's partition naming -- most likely an orphan left by an interrupted drain. Drop it
> (drop table public.events_p2026_03) and retry transmute.

**What it means.** The drain (and regrain) builds each child as a **standalone** table and only `ATTACH`es
it when the interval finishes. A standalone child has no dependency on the parent, so a
`DROP TABLE <parent> CASCADE` does **not** remove an un-attached child -- it survives the cascade. If the
parent is then recreated and re-transmuted, the next drain would reuse that orphan by name and collide on
its stale keys. So `transmute` refuses when it finds a standalone table matching the parent's
child-partition naming (`<rel>_p<digits>`), rather than silently adopting stale data (the orphan guard;
`tests/18`). Since #94, an in-flight child is also tracked in `pgpm.part` with `attached = false`.

**Steps.**

1. The error names the orphan. Confirm it is a leftover standalone table, not a live attached partition --
   it is a partition of no parent, and (post-#94) it may show in `pgpm.partitions` with `attached = false`:

   ```sql
   select inhparent::regclass from pg_inherits
    where inhrelid = 'public.events_p2026_03'::regclass;            -- expect no rows (not attached anywhere)
   select * from pgpm.partitions where child_name = 'events_p2026_03';  -- attached = false, if still tracked
   ```

2. Drop the orphan and retry:

   ```sql
   drop table public.events_p2026_03;   -- the table the error named
   -- then re-run your transmute(...) call
   ```

**Verify.**

```sql
select * from pgpm.status() where parent = 'public.events'::regclass;   -- transmute succeeded; the table is managed
```

**Prevent.** Do not `DROP`/recreate a parent mid-conversion. Let an interrupted drain finish (it attaches
the child, so it becomes a real partition rather than an orphan), or `untransmute` while the conversion is
still reversible, rather than dropping the parent out from under its in-flight children.

## A `from_hypertable` cutover is slow or its pre-drain will not converge

**Symptom.** Migrating a TimescaleDB hypertable with `from_hypertable`, either: `from_hypertable_cutover`
sits for a long time before (or during) its brief lock; or a hand-driven `from_hypertable_drain_delta` /
`from_hypertable_drain_appends` raises `pg_partition_magician: from_hypertable_drain_delta(...) did not
converge within N iterations` (or the cutover's best-effort pre-drain returns having left a large residual
that is then applied under the lock).

**What it means.** When `p_track_changes` is on, the cutover catch-up is the change **delta** captured
during the online copy; otherwise it is the rows appended past the copy watermark. Either backlog is drained
online, in bounded micro-batches, *before* the lock (`p_predrain`, default true), so the lock applies only a
tiny residual. Non-convergence means the workload is dirtying keys / appending faster than the micro-batch
drain clears them, so the residual never falls to the threshold within the iteration budget (`p_max_iter`).
The drain is best-effort and the under-lock pass is the correctness backstop, so the migration stays
**correct** either way -- the symptom is a *long lock* (the under-lock pass applies a big residual), not data
loss. (At-scale figures and the structural note that the append-only backlog stays small are in
`bench/result-fh-cutover-lockwindow.md`.)

**Steps.**

1. See how big the backlog is (run during the online window, before cutover). For tracking, count the delta;
   for append-only, count rows past the destination watermark:

   ```sql
   -- tracking (p_track_changes => true):
   select count(*) from public.events_pgpm_delta;
   -- append-only (no tracking):
   select count(*) from public.events where created_at > (select max(created_at) from public.events_pgpm_dest);
   ```

2. Drain it down by hand, with a bigger batch, before cutting over (this is the two-phase flow -- it lets
   the backlog shrink while the source stays live):

   ```sql
   -- tracking:
   call pgpm.from_hypertable_drain_delta('public.events', 'created_at', p_batch => 200000);
   -- append-only:
   call pgpm.from_hypertable_drain_appends('public.events', 'created_at', p_batch => 200000);
   ```

3. If the workload genuinely outruns the drain, accept a larger final batch instead of chasing zero -- raise
   the threshold so the drain stops sooner and the (still bounded) remainder is applied under the lock:

   ```sql
   call pgpm.from_hypertable_drain_delta('public.events', 'created_at', p_batch => 200000, p_threshold => 100000);
   ```

   Or pause / throttle the write workload briefly, then cut over. As a last resort, raise `p_max_iter`.

4. Cut over. The cutover re-runs a best-effort pre-drain and then applies whatever residual remains under the
   lock:

   ```sql
   call pgpm.from_hypertable_cutover('public.events', 'created_at', interval '1 day', p_drain_batch => 200000, p_paused => false);
   ```

   To skip the cutover's own pre-drain (e.g. you already drained by hand and want the lock taken
   immediately), pass `p_predrain => false`.

**Verify.**

```sql
select relkind from pg_class where oid = 'public.events'::regclass;   -- 'p' = migrated to a partitioned table
select * from pgpm.status() where parent = 'public.events'::regclass; -- registered and managed
```

**Prevent.** For update/delete-heavy workloads, drive the drain in the two-phase flow (copy, let it drain,
then cutover) rather than relying on the one-shot, and size `p_drain_batch` to the write rate. Append-only
migrations rarely hit this (the backlog is structurally small -- the copy reads the current chunk last, so
it captures appends as it goes). Migrate during a quieter write window when possible.

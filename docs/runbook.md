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
- [Monitoring a non-empty DEFAULT](#monitoring-a-non-empty-default)
- [A stray is stuck in the DEFAULT (the drain is behind)](#a-stray-is-stuck-in-the-default-the-drain-is-behind)
- [Disk is filling during a refine](#disk-is-filling-during-a-refine)
- [Storage is not dropping despite a retention policy](#storage-is-not-dropping-despite-a-retention-policy)
- [Re-transmute fails with an orphan-table error](#re-transmute-fails-with-an-orphan-table-error)

## Referential-integrity violations after a `preserve` drain

**Symptom.** Any of: an incoming foreign key on a table that points at a pgpm-managed parent shows as
`NOT VALID`; `pgpm.status()` reports `fks_unvalidated > 0`; `pgpm.log` has `validate_incoming_fk_blocked`
rows; or a periodic RI audit (or an application error) flags dangling references into the parent.

**What it means.** You converted with `p_incoming_fks => 'preserve'`. While the **assistant drain** moved
referenced rows (evacuating a stray from the `DEFAULT` through an unattached child), the incoming FK was
dropped, so referential integrity was off on the referencing table for that window. (This is by design and
visible as `status().fks_suspended`; see the guide's
[incoming foreign keys](guide.md#incoming-foreign-keys).) When the drain reached quiescence, pgpm re-added
the FK so it once again enforces every *new* write (as `NOT VALID`), but it could not fully *validate* the
constraint because rows that violate it were written during the window. Those orphans are real RI
violations to reconcile; new writes are already guarded again. The attribution is exact: the FK was valid
when pgpm dropped it, so any orphan present now arose during the window. (Note: **refine** does *not* open
this window -- it copies, and its swap drops and re-adds the FK within one atomic transaction -- but the
same reconciliation applies if a refine or retention drops aged, still-referenced history: the re-validate
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
(`select pgpm.restore_incoming_fks('public.events');`); the window opens only if a later assistant drain
actually moves referenced rows. To shrink it: keep `obtain` ahead so strays never accumulate, so the drain
rarely runs; or `pause` heavy referencing-table write bursts while the drain catches up. A `refine` (manual
or auto) opens no RI window of its own -- the copy never moves a referenced row out of the parent, and the
swap's FK drop/re-add is one atomic transaction. The one refine-related caveat is data, not timing: if a
refine or a retention policy drops aged history that is still referenced, the FK re-validates against a real
orphan -- do not retain below rows you still reference.

## The history is not splitting into fine partitions

**Symptom.** `pgpm.status()` shows `history_unrefined = true` and `coarse_partitions > 0` that does not
fall; queries over old data do not prune to a single partition; retention is not reclaiming old data.

**What it means.** After `transmute`, the history lives in one coarse **monolith** partition. That is a
correct, permanent state, but pruning and fine-grained retention are suspended over its span until it is
**refined** into proper partitions. If you want fine history, refine has either not been enabled, or it
cannot make progress yet.

**Steps.**

1. See the backlog and whether auto-refine is on:

   ```sql
   select parent, coarse_partitions, history_unrefined from pgpm.status();
   select parent_table, refine_to from pgpm.config where refine_to is not null;   -- auto-refine targets
   ```

2. If `refine_to` is null, the history is intentionally coarse. To split it, either enable paced
   auto-refine or do it by hand once the monolith has **frozen** (the frontier has moved past its upper
   bound `B`):

   ```sql
   select pgpm.set_refine('public.events', '1 month');   -- paced: one microbatch per maintain tick
   -- or, synchronously now (atomic, one transaction):
   select pgpm.refine_history('public.events');
   ```

3. If auto-refine is on but `coarse_partitions` is not falling, check why a tick is not progressing in
   `pgpm.log`:

   ```sql
   select at, action, method from pgpm.log
    where parent_table = 'public.events'::regclass and action in ('refine_skip', 'refine')
    order by id desc limit 10;
   ```

   - A `maintain` summary of `refine=active` means the monolith has **not frozen yet** (the current
     interval still lands in it); it will refine once the frontier crosses `B`.
   - `refine=default_dirty` means a stray sits in the monolith's range in the `DEFAULT`; let the assistant
     drain clear it (see the next entry), then refine resumes.
   - `refine=copied:N` is healthy forward progress (one budget-sized copy microbatch); `refine=swapped:K`
     is a completed refine (K fine children attached). A `refine_skip` log row is a lock-race deferral, and
     a `refine_aged` row is a below-horizon sub-range skipped under a retention policy; both are normal.

4. If disk is the constraint, see [Disk is filling during a refine](#disk-is-filling-during-a-refine).

**Verify.**

```sql
select coarse_partitions, history_unrefined from pgpm.status() where parent = 'public.events'::regclass;
-- coarse_partitions falling toward 0; history_unrefined false once fully split
```

**Prevent.** Decide up front whether the table needs fine history. If it does, enable `set_refine` after
`transmute` (or refine by hand in a maintenance window). If a coarse monolith is acceptable, leave it.

## Monitoring a non-empty DEFAULT

**Symptom.** Monitoring fires on a non-empty `DEFAULT`: `pgpm.check_default('public.events')` reports
`default_rows > 0`, or `pgpm.status()` shows it. Even a brief, self-clearing occupancy counts.

**What it means.** In the monolith model the `DEFAULT` is the empty leading-edge net, so an **empty**
`DEFAULT` is the healthy steady state: it means your partitioning matched reality (keys landed where you
predicted, `obtain` stayed ahead of the frontier). Any occupancy means reality diverged from the model --
worth knowing even when it self-heals, because a race lost briefly tends to be lost less briefly later.
Landing in the `DEFAULT` *routinely* is an anti-pattern: a net you use every day is a hammock, and a
load-bearing `DEFAULT` quietly signs you up for the assistant drain and its
[read-consistency window](guide.md#read-consistency-during-a-move). Keep it a **tripwire** -- alarmed and
empty.

**Steps.**

1. Alarm on the level, the age, and the trend -- not just presence:

   ```sql
   select default_rows, closed_rows, oldest from pgpm.check_default('public.events');
   select default_oldest, last_drained, drain_skips from pgpm.status() where parent = 'public.events'::regclass;
   ```

   Alert when `default_rows > 0`. The oldest `DEFAULT` key (`oldest` / `default_oldest`) is the sharpest
   single number -- it is at once "how long has coverage been missed" and "how stale is the unsorted
   data." A rising oldest-age alongside a flat `default_rows` is a **wedged** drain (see
   [A stray is stuck in the DEFAULT](#a-stray-is-stuck-in-the-default-the-drain-is-behind)).

2. Triage the cause by comparing the `DEFAULT`'s key range to the frontier (`now()` for `time`,
   `max(control)` for `id`/`uuidv7`). The `oldest` value usually settles it; for the full spread, read the
   `DEFAULT` partition directly (its name is `config.default_table`, conventionally `<table>_default`):

   ```sql
   select min(created_at), max(created_at), count(*) from public.events_default;
   ```

   - **Leading-edge lag** -- the keys sit at/near the frontier: `obtain` fell behind the writers. The
     urgent case, since it recurs and grows into a write-availability risk. Confirm it is `obtain`
     deferring (not just slow cadence): `pgpm.log` shows repeated `obtain_skip` rows, the maintain note
     carries `obtain_backoff`, `config.obtain_retry_after` is set in the future, and no new future
     partitions appear in `pgpm.partitions`. The cause is lock contention -- obtaining a future partition
     briefly needs `ACCESS EXCLUSIVE` on the populated `DEFAULT`, so under sustained writes `obtain` keeps
     losing that race and maintenance backs it off (it waits out `obtain_retry_after` rather than retrying
     every tick). Keep more partitions ahead
     (`update pgpm.config set obtain = <n> where parent_table = 'public.events'::regclass;`) and/or run the
     cron more often; force one now in a brief write lull with `select pgpm.obtain('public.events');`, and
     catch up the backlog with `select pgpm.drain_all('public.events');`. On a perpetually-hot table,
     schedule the conversion/obtain during a quieter window.
   - **Backdated / late-arriving** -- the keys sit well below the frontier: a producer is emitting old
     timestamps/ids (clock skew, a replay or backfill), or your `retain` window is narrower than the real
     late-arrival tail. Fix the producer, or widen retention. The drain homes these into a partition (or
     reclaims them if they are already below the retention horizon).
   - **A coverage gap** -- a key in a range you never provisioned (not ahead of the frontier, not in the
     monolith). The drain homes it into a new partition for that interval like any stray; a *recurring* gap
     points at a scheme assumption that does not hold (a key kind or range you did not expect), worth
     chasing at the source.

3. In every case the rows are safe in the `DEFAULT` and the assistant drain will home them; the alarm
   exists to fix the *cause* so the `DEFAULT` returns to empty, not to rescue the rows.

**Verify.**

```sql
select default_rows from pgpm.check_default('public.events');   -- expect 0 once the cause is fixed and the drain has caught up
```

**Prevent.** Treat the `DEFAULT` as a tripwire, not a landing zone. Keep `obtain` comfortably ahead of the
frontier so steady-state writes always have a real partition and never reach the net, and alarm on *any*
occupancy so a momentary miss gets attention before it becomes a standing one. The empty `DEFAULT` is
insurance you are glad to hold and alarmed to ever use.

## A stray is stuck in the DEFAULT (the drain is behind)

**Symptom.** `pgpm.status()` shows `closed_rows > 0` (or `pgpm.check_default()` does); optionally a stale
`last_drained` and a climbing `drain_skips`.

**What it means.** In the monolith model the `DEFAULT` is the empty leading-edge net; in steady state it
holds nothing. A non-zero `closed_rows` means a stray landed there (obtain fell behind the frontier, a
backdated row, or a gap) and the **assistant drain** has not yet evacuated it into a proper partition. A
falling `closed_rows` with `drain_skips ~ 0` is merely slow; a stuck `closed_rows` with a stale
`last_drained` and a climbing `drain_skips` is a **wedged** drain. Since the monolith+refine redesign a
true wedge is rare: the bulk move is `refine`, which copies and cannot strand a duplicate; the drain only
relocates strays; and upserts to historical keys hit the attached monolith rather than an invisible child.
So **merely slow** is the common case and **wedged** is a corner -- but both are worth recognizing.

**Steps.**

1. Quantify the backlog and the progress signal:

   ```sql
   select closed_rows, default_rows, oldest from pgpm.check_default('public.events');
   select last_drained, drain_skips from pgpm.status() where parent = 'public.events'::regclass;
   ```

2. If it is merely behind, raise the pace or catch up by hand:

   ```sql
   update pgpm.config set drain_batch = 20000 where parent_table = 'public.events'::regclass;  -- bigger microbatch
   select pgpm.drain_all('public.events');                                                     -- catch up now (synchronous)
   ```

3. If it is **wedged** (a stale `last_drained`, climbing `drain_skips`), look for the cause in the log:

   ```sql
   select at, action, method from pgpm.log
    where parent_table = 'public.events'::regclass and action = 'drain_skip' order by id desc limit 10;
   ```

   A recurring duplicate-key error is the upsert-into-a-moved-row wedge (see the guide's
   [read consistency](guide.md#read-consistency-during-a-move)): an `INSERT ... ON CONFLICT` targeted a
   stray already moved into an unattached drain child and wrote a duplicate into the `DEFAULT`, which the
   next batch then collides on. Post-redesign this is the narrow residual case -- it needs a concurrent
   upsert to a *stray* mid-move, since historical keys live in the attached monolith and `refine` never
   moves through an invisible child. Remove the duplicate from the `DEFAULT` (keep the already-moved copy),
   then let the drain continue.

**Verify.**

```sql
select closed_rows from pgpm.check_default('public.events');   -- expect 0
```

**Prevent.** Keep `obtain` comfortably ahead of the frontier (raise `config.obtain`, or run the cron more
often) so the frontier never outruns the real partitions and writes never fall to the `DEFAULT`. For
tables that upsert into historical ranges, prefer the synchronous `drain_all()` in a window over the paced
drain.

## Disk is filling during a refine

**Symptom.** Free space drops while a refine is running; `pgpm.status()` shows `inflight_partitions > 0`
for the table.

**What it means.** `refine` **copies** the monolith's rows into new fine partitions and only drops the
source after they are swapped in, so it transiently needs roughly **2x the disk** of the range being
refined while the copies coexist with the source. On an elastic or auto-scaling volume this is absorbed;
on a fixed volume it can be a problem if you refine a large coarse child in one shot.

**Steps.**

1. See what is in flight:

   ```sql
   select parent, coarse_partitions, inflight_partitions from pgpm.status();
   ```

2. If you are disk-bound, stop starting new work and let the current refine finish (it drops its source at
   the swap, reclaiming the transient space):

   ```sql
   select pgpm.set_refine('public.events', null);   -- pause auto-refine (the in-flight one still completes)
   ```

3. Refine **hierarchically** so each step's footprint stays bounded: split the monolith into coarse units
   first (for example per year), then refine one coarse unit at a time. Each later step only needs ~2x of
   one unit, not of the whole history:

   ```sql
   -- one coarse unit, by hand (target a coarser step first, then the fine step per unit)
   select pgpm.refine('public.events', '<monolith child name from pgpm.part>', '1 year');
   ```

4. Or acquire more disk: on a managed/elastic volume, grow it (or let auto-scaling absorb the spike), then
   resume `set_refine`.

**Verify.**

```sql
-- free space recovers after the swap drops the source; the coarse child is gone from pgpm.part
select coarse_partitions, inflight_partitions from pgpm.status() where parent = 'public.events'::regclass;
```

**Prevent.** Before refining a large history on a fixed volume, prearrange about 2x the headroom of the
span you will refine, or refine hierarchically so the transient footprint stays bounded to one unit at a
time. On an elastic volume, no special preparation is needed.

## Storage is not dropping despite a retention policy

**Symptom.** `config.retain` is set, but disk is not falling as old data ages out: aged partitions linger,
or the below-horizon tail sits in the `DEFAULT` and never goes away.

**What it means.** Retention is enforced only while maintenance runs and the drain keeps pace. Two
mechanisms reclaim aged data, both driven by `maintain` on pg_cron:

- `retain()` drops whole materialized partitions older than the horizon (a `retain_drop` log row).
- since #91, the drain also reclaims below-horizon rows still in the `DEFAULT` **in place**, instead of
  materializing a partition only to drop it next tick (a `retain_reclaim` log row).

So retention is **best-effort**: if the table is `paused`, if `maintain_all` is not scheduled, or if the
drain is lagging (a large `closed_rows` backlog, so the aged tail never reaches a partition), aged data
lingers and storage does not fall. It bounds storage only when maintenance runs and the drain keeps up.
(Watch the unit, too: `retain` is an **interval** for `time`/`uuidv7` and a **count of intervals** for
`id` -- a misread makes the horizon far longer than intended.)

**Steps.**

1. Confirm the policy is set and that maintenance can act on it:

   ```sql
   select parent, paused, closed_rows from pgpm.status() where parent = 'public.events'::regclass;
   select retain from pgpm.config where parent_table = 'public.events'::regclass;
   ```

   `paused = true` means maintenance is doing nothing; a large `closed_rows` means the drain is behind, so
   the aged tail has not been homed (or reclaimed) yet.

2. Run a maintenance pass, or force the reclaim by hand:

   ```sql
   select pgpm.maintain('public.events');     -- one pass: obtain, retain, drain (and auto-refine)
   -- or catch up now, synchronously:
   select pgpm.drain_all('public.events');    -- evacuate / reclaim the closed tail
   select pgpm.retain('public.events');       -- drop aged partitions now
   ```

3. Confirm reclamation actually happened:

   ```sql
   select at, action, lo, hi, rows from pgpm.log
    where parent_table = 'public.events'::regclass and action in ('retain_drop', 'retain_reclaim')
    order by id desc limit 20;
   ```

**Verify.**

```sql
-- aged partitions are gone and the closed tail has drained; storage falls once the drops are reclaimed
select n_partitions, closed_rows from pgpm.status() where parent = 'public.events'::regclass;
```

**Prevent.** Keep `maintain_all` scheduled on pg_cron and the drain keeping pace (raise `drain_batch` / run
the cron more often) so the aged tail always reaches a partition in time to be dropped, and do not leave a
managed table `paused` if you rely on retention to bound storage. A lagging or paused drain turns retention
into best-effort.

## Re-transmute fails with an orphan-table error

**Symptom.** `transmute` refuses up front with an error like:

> pg_partition_magician: public.events_p2026_03 already exists as a standalone table matching this
> parent's partition naming -- most likely an orphan left by an interrupted drain. Drop it
> (drop table public.events_p2026_03) and retry transmute.

**What it means.** The drain (and refine) builds each child as a **standalone** table and only `ATTACH`es
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

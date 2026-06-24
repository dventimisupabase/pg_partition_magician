# pg_partition_magician operational runbook

Symptom-driven, step-by-step procedures for operators. When something alerts you, find the matching
entry and follow the steps top to bottom. This is the "do this, then this" book, deliberately distinct
from the other docs:

- the [README](../README.md) is the front door;
- the [user guide](guide.md) explains the *concepts* and how to use pgpm;
- the [reference](reference.md) documents *every* function and catalog object;
- the [explainer](https://dventimisupabase.github.io/pg_partition_magician/) is the visual overview;
- **this runbook** is what you reach for at 2am, when you do not want to reconstruct a procedure from
  bits scattered across the others.

Every entry has the same shape: **Symptom** (how you noticed) -> **What it means** (one paragraph) ->
**Steps** (numbered, copy-paste) -> **Verify** -> **Prevent**.

## Entries

- [Referential-integrity violations after a `preserve` drain](#referential-integrity-violations-after-a-preserve-drain)

## Referential-integrity violations after a `preserve` drain

**Symptom.** Any of: an incoming foreign key on a table that points at a pgpm-managed parent shows as
`NOT VALID`; `pgpm.status()` reports `fks_unvalidated > 0`; `pgpm.log` has `validate_incoming_fk_blocked`
rows; or a periodic RI audit (or an application error) flags dangling references into the parent.

**What it means.** You converted with `p_incoming_fks => 'preserve'`. While pgpm drained the closed
tail, the incoming FK was dropped, so referential integrity was off on the referencing table for that
window. (This is by design and is itself visible as `status().fks_suspended`; see the guide's
[incoming foreign keys](guide.md#incoming-foreign-keys).) When the drain reached quiescence, pgpm
re-added the FK so it once again enforces every *new* write (as `NOT VALID`), but it could not fully
*validate* the constraint because rows that violate it were written during the window. Those orphans
are real RI violations to reconcile. New writes are already guarded again; you are cleaning up the
historical rows. The attribution is exact: the FK was valid when pgpm dropped it, so any orphan present
now arose during the drain window.

**Steps.**

1. Confirm the state and see which parents are affected:

   ```sql
   select parent, fks_suspended, fks_unvalidated from pgpm.status();
   ```

   `fks_unvalidated > 0` for a parent means an incoming FK was re-added but is blocked from validation.
   (If instead `fks_suspended > 0`, a drain is still in flight and the FK is currently fully dropped:
   let the drain finish, or bound it, before reconciling -- see **Prevent**.)

2. List the blocked foreign keys and how many orphan rows each has:

   ```sql
   select * from pgpm.incoming_fk_orphans('public.events');   -- the managed parent
   -- referencing_table | constraint_name | orphan_rows
   ```

3. Inspect the offending rows so you can decide what to do. For a single-column FK
   (`reactions.event_id` referencing `events.id`, say):

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

**Prevent.** Referential integrity is necessarily off while a `preserve` drain runs: the FK must be
dropped so the drain can relocate referenced rows through an unattached child, and that cannot be
avoided. To shrink the window, drive the conversion to completion in a maintenance window with
`select pgpm.drain_all('public.events', p_include_open => true);`, or `select pgpm.pause('public.events');`
during heavy bursts of writes to the referencing table. If that table takes continuous heavy writes
throughout a long conversion, prefer the default `p_incoming_fks => 'error'` and convert during a
quieter period. Background: the guide's [incoming foreign keys](guide.md#incoming-foreign-keys).

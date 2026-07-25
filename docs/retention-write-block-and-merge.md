# Retention write-blocking and the retention/archiving merge

> The positioning doc for a stack that closes a real gap chunked archiving opened
> (#213, #221): the span between "a partition crossed the retention boundary" and "the
> last archive chunk landed" is unbounded, attached, and today still writable. Read this
> first, before #235-#241, which land the mechanism this doc motivates. It also settles
> a standing question: retention and archiving stay one module, not a two-module split.
> **Documentation only -- nothing below is built yet** (see [Honest scope](#honest-scope)).

## The problem: chunked archiving reopens a write window

Byte-budget chunked archiving (#213, #221; today's `archive._next_range_byte_budget`,
`archive.archive_range`, `archive.ledger` in `pgpm_archive/install.sql`) exists to bound
the size and duration of a single archive operation. That is a real concern, and a
separate one from anything about *when* a partition is eligible to be touched. But those
two concerns interact: a single large partition can now take several `maintain()` ticks
to fully archive, and for the whole span between crossing
[`_retain_boundary()`](../pgpm_core/install.sql) and the last chunk landing, the
partition remains attached, and, absent anything to stop it, fully writable.

A backdated write anywhere in that span, including into a range some earlier chunk
already archived and ledgered, silently diverges the archived copy from what is still
live. Nothing today prevents that write before the fact.
[`archive.file_gate`](../pgpm_archive/docs/chunked-parquet.md) recounts and catches the
divergence, but only reactively, after the write has already happened, and only on the
paced/gate-only path -- a table using the synchronous hook, or one with no archiving
configured at all, has no check at all.

## Why write-blocking, not `REVOKE` or a spanning lock

The fix reframes what "retain-eligible" means: instead of being purely a drop
precondition, crossing the retention boundary becomes a **write-block precondition**
too, independent of whether archiving is configured or how far along it is. A table with
no archive strategy at all still gets its old partitions write-blocked before they drop,
for the same reason a table with S3 archiving does.

Two other mechanisms were considered and ruled out empirically, not on paper:

- **`REVOKE`ing `INSERT`/`UPDATE`/`DELETE` on the child partition does not work.**
  PostgreSQL checks privileges against the relation actually named in the query, so a
  parent-routed write (an `INSERT` into the parent, routed by the partitioning machinery
  to a child) is checked against the *parent's* ACL. The child's own privileges are
  never consulted unless something addresses that child directly by name -- which a
  normal application write never does.
- **Holding an exclusive lock across the whole archiving span does not work either.**
  That span is unbounded by design; holding it open as one long transaction is exactly
  what chunking exists to avoid.

What does work, verified directly: a `BEFORE INSERT OR UPDATE OR DELETE FOR EACH ROW`
trigger installed on the specific child fires on parent-routed writes regardless of
routing (triggers, unlike ACL checks, run on the partition PostgreSQL actually routes
the write to), leaves reads and every other partition untouched, cannot be silently
bypassed by an owner or superuser the way a privilege check or row-level security policy
can, and is torn down automatically when the partition is eventually dropped -- no
separate cleanup step. In shape:

```sql
create function pgpm._write_block_raise() returns trigger language plpgsql as $$
begin
  raise exception '% is past its retention boundary and is no longer writable', tg_table_name;
end;
$$;

create trigger pgpm_write_block
  before insert or update or delete on <child>
  for each row execute function pgpm._write_block_raise();
```

## The target end state

Three pieces, landing in the order below, close the gap and fold retention and
archiving into one lifecycle:

- **A write-block trigger tied to retain-eligibility**, installed and removed by
  comparing every attached child against `_retain_boundary()` on each `maintain()`
  tick -- ahead of any drop logic, so a partition is write-blocked before it is ever a
  drop candidate. Loosening `config.retain` un-blocks a partition that becomes eligible
  no longer, the same eligibility check running in reverse.
- **A pluggable `archive_fn` contract on `pgpm.config`**, replacing `pgpm.hook`'s
  single-purpose `pre_drop` registry. One nullable `regprocedure` column
  (`null` = no archiving, drop as soon as write-blocked) with a resumable calling
  contract: called once per tick against a given child, expected to make bounded
  incremental progress on `[lo, hi)` and report how much is now durably archived, not to
  finish the whole range in one call.
- **Ledger-driven chunked archiving as the one built-in strategy on that contract**,
  porting today's byte-budget range-picking and `archive.ledger` onto it, operating only
  on children the write-block trigger already protects -- so the two mechanisms compose
  by construction rather than by convention.
- **A unified drop path**: `pgpm.retire()`'s precondition becomes fully internal --
  past the retention boundary, write-blocked, and archive-covered -- with no external
  hook registry and no coordination required between an archiving module and core.

This also settles a related question raised alongside the prior harmonization stack
(#217-#222): retention (`pgpm.config.retain`, `_retain_boundary`, the drop path) and
archiving were considered for a hard module split, a standalone module independently
versioned from `pgpm_core`. The dependency surface such a split would leave behind
(shared read access to `pgpm.config`/`pgpm.part`, shared native-type comparison helpers,
a narrow write-back API into the drop path) was not small enough to be worth a second
module. The `archive` schema stays as a namespace for S3/target-specific transport code
-- the encode/upload/sign machinery genuinely is a separate concern -- but it ships as
part of the same install as `pgpm_core`, not a dependency of it.

## Implementation order

The issue numbers below are not in build order (this doc landed last in creation order
despite being step 1). Follow this sequence, not the numeric one:

1. **#242** (this doc) -- positioning, read first.
2. **#235** -- the write-block trigger, tied to retain-eligibility, wired into
   `maintain()` ahead of any retain/drop logic. Purely additive: nothing yet depends on
   the trigger existing.
3. **#236** -- the pluggable `archive_fn` contract on `pgpm.config`, plus a no-op
   built-in strategy to exercise dispatch. Schema and contract only, not wired into a
   drop path yet.
4. **#237** -- byte-budget chunked archiving and its ledger, ported onto the contract,
   operating only on already write-blocked children. Independently testable; nothing
   drops because of it yet.
5. **#238** -- `pgpm.retire()`'s drop precondition becomes write-blocked +
   archive-covered; the `pgpm.hook` loop, `pgpm.hook`/`hook_register`/`hook_unregister`,
   and `retain_hook_fail` are removed. The cutover for `pgpm_core`'s own drop path.
6. **#239** -- the real S3 archiving functions (`archive.to_s3`, `archive.to_s3_parquet`)
   move onto the contract, output-preserving for identical input.
7. **#240** -- the old paced/self-driving apparatus this stack supersedes is deleted
   outright: `archive.tick`, `_tick_one`, `_next_range_partition_aligned`,
   `_next_range_byte_budget`, `_retire_covered`, `file_gate`, `_file_watermark`,
   `archive_range`, `archive.ledger`, `archive.config`'s `drop_trigger` modes, and the
   `archive.configure`/`schedule` operator interface (#233). Deletion only, no migration
   shim -- this project is pre-1.0 with no live installs (#217's precedent).
8. **#241** -- docs, README pointers, and the archive CI test track updated to describe
   the system as it then actually works, plus the `CHANGELOG.md` entry for the whole
   stack.

## Honest scope

Documentation only -- no code changes, no behavior changes. Every mechanism named above
under [The target end state](#the-target-end-state) is a plan, not yet-shipped fact:
`pgpm._install_write_block`/`_enforce_write_blocks`, `pgpm.config.archive_fn`,
`pgpm.archive_ledger`, and the changed `pgpm.retire()` precondition all still need
issues #235-#238 to land. Nothing in `pgpm_core/install.sql` or
`pgpm_archive/install.sql` changed to add this doc, and every mechanism described in
[Choosing an archival strategy](../pgpm_archive/docs/strategies-overview.md) and its
three sibling pages continues to work exactly as those pages describe until the stack
above actually replaces it.

## References

- [`docs/guide.md`](guide.md), [`docs/reference.md`](reference.md) -- `retain`, `retire`,
  `pgpm.hook` as they work today.
- [Choosing an archival strategy](../pgpm_archive/docs/strategies-overview.md) -- the
  equivalent anchor doc for the prior harmonization stack (#217-#222), whose shared
  machinery (`archive.ledger`, `archive.file_gate`, the boundary-rule dispatch) this
  stack carries forward onto the `archive_fn` contract.
- #213, #221 -- byte-budget chunked archiving, the mechanism whose implications motivate
  this stack.
- #218 -- `archive.gate`/`archive.file_gate` unification, the existing reactive check
  this stack makes non-load-bearing.
- #235-#241 -- the rest of this stack, in implementation order above.

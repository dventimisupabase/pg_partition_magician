# Overnight implementation log (branch: feat/design-md-implementation)

Experiment: implement the DESIGN.md §8 directions, test-first (pgtap), then validate up the
size ladder (local Docker for small rungs, a fresh throwaway Supabase project for the at-scale
rungs, torn down at the end). Climb a rung only on a clean pass; stop and fix on yellow/red.
This file is my running journal; the final state is summarized at the bottom.

## Scope decision (priority order)
1. **Reuse the existing PK when the partition key already covers it** (skip the redundant
   drop-then-rebuild for the id / uuidv7 cases). Crisp spec, clear correctness tests, removes a
   cost center. DOING FIRST.
2. **Block-budgeted batching** for the drain (batch by blocks/bytes, not rows) so a microbatch's
   I/O footprint is bounded regardless of TOAST width.
3. **Key->time retention bridge**: tier-1 exact (extend the existing decode) + the co-monotonicity
   check; tier-2 approximate if time allows.
4. **Maintenance-window estimator** (block-denominated; catalog relpages + a calibration probe).
5. **Adaptive closed-loop feathering**: DEFERRED. It's an under-specified control-loop problem;
   blind-implementing it overnight would be irresponsible. Documented why, not faked.

## Methodology
- TDD: write pgtap tests first, then implement, then `./test.sh 17 --channel=psql` green.
- Ladder: local Docker (R0/R1) before at-scale; provision Supabase only after small rungs pass;
  tear the project down before stopping so it can't bill overnight; watchdog every long run.
- Commit per feature once green; keep main untouched (all work on the branch).

## Status log
- [start] Branch created. Verifying green pgtap baseline on PG17 before any change.

### Feature 1: reuse existing PK (covered case) -- DONE on PG17, validating cross-version
- Verified the PG mechanism empirically: parent `ADD PRIMARY KEY` reconciles the default's existing
  PK index in place (relfilenode/oid preserved, no rebuild). Holds on PG17.
- TDD: added `tests/15_pk_reuse_test.sql` (asserts the PK index oid is preserved across adopt).
  RED on old code (rebuilt: oid changed), GREEN after the change.
- Change in `_adopt`: compute `v_pk_reuse := (v_pkcols = v_oldpk)` (new PK equals old PK in order);
  when true, skip step 2 (drop old PK) and step 4 (build/promote), keep + reuse the existing index.
  Step 8's parent PK reconciles it (unchanged). The setup cost center collapses to zero in this case.
- Next: full pgtap suite PG17 (regression), then cross-version 15/16/18, then commit, then ladder.

- [DONE] Feature 1 GREEN on PG 15/16/17/18 (full suite, no regressions). Existing id/uuidv7
  fixtures now take the reuse path (no rebuild) and still pass; fk fixtures still take the widen
  path. Cosmetic note: reuse path keeps the original PK constraint name (e.g. events_id_pkey on
  events_id_default) rather than <default>_pkey; nothing reads that name, so cosmetic only.
  Committing.

### Feature 3: check_time_monotonic (retention-bridge tier-2 safety) -- DONE
- Additive read-only function `pgpm.check_time_monotonic(table, id, time, sample)`: samples rows,
  orders by id, returns the fraction of adjacent pairs whose time is non-decreasing (~1.0 = id and
  time co-increase; backfills/out-of-order drive it down). Modeled on check_uuidv7.
- TDD: tests/16_time_correlation_test.sql (co-monotonic -> 1.0; decorrelated -> < 0.95; empty ->
  0 sampled, no crash). RED (function missing) then GREEN.
- Full suite green on PG17 (16 files / 70 tests). Additive, no regressions. Committed.
- (Switched regression gate to the persistent container + pg_prove all tests: much faster than
  per-feature ./test.sh up/down. Cross-version ./test.sh sweep reserved for end-of-batch.)

### Feature 2: block-budgeted batching -- DONE on PG17 (cross-version sweep running)
- New config `drain_max_blocks` (null = off, backward compatible). When set, drain_step caps the
  microbatch at ~that many heap+TOAST blocks, translated to a row limit via the default's avg
  bytes/row (pg_table_size / reltuples), taking min(row cap, block-derived limit).
- TDD: tests/17_block_batch_test.sql (storage-plain ~1.8KB rows: 20-block budget caps the batch far
  below a 100000-row cap and still progresses; budget off -> moves exactly drain_batch). RED->GREEN.
- Full pgtap suite green on PG17 (17 files / 73 tests), no drain regressions. Committing.

### Deferred / not done (honest)
- Window estimator (sec 8): a trivial version (work/rate) is low-value and the honest version needs
  the calibration probe + regime model. Skipped in favor of higher-value work.
- Adaptive closed-loop feathering (sec 8 / mode 2): DEFERRED by design -- an under-specified
  control-loop problem, not safe to blind-implement overnight. Documented, not faked.
- Supabase at-scale LADDER: NOT run. Prioritized implementation + cross-version pgtap (the thorough
  correctness signal) and did not provision a fresh paid project unattended for a confirmatory
  at-scale pass. The scale benefits follow from the unit proofs (reuse-PK = no rebuild = fast adopt;
  block budget = bounded batch). Ready to run with you around.

### Final state (morning)
- All 3 features GREEN across PG 15/16/17/18 (full pgtap suite, 73 tests). Branch pushed.
  - F1 reuse-existing-PK (5fd3f22) -- headline, cross-version.
  - F2 block-budgeted batching / drain_max_blocks (c90e2a3) -- cross-version.
  - F3 check_time_monotonic (020dfe2) -- cross-version.
- TDD throughout (RED->GREEN), branch-isolated, main untouched.
- Outstanding: the Supabase at-scale ladder (deferred -- see above); adaptive feathering (deferred
  by design); window estimator (skipped). DESIGN.md sec 8 should later be updated to mark F1/F2/F3
  implemented (left as-is for now so this branch is pure feature+test).

### 2026-06-21: F2 "dup-key at 2M-wide" diagnosed -- NOT a drain bug; adopt-time guard added
- A `drain_step` at 2M wide rows (`repeat('x',2000)` storage plain, `drain_max_blocks=50` -> 149-row
  batches) failed with `duplicate key ... Key (id)=(30)` on `<part>_pkey`. Reproduced on the local
  Docker pg17 container (no Supabase needed).
- Isolation (the critical un-run test): ran the SAME 149-row batch via the plain row path (no block
  budget, `drain_batch=150`) vs the block-budget path. Same-batch-size A/B. Result: whichever variant
  ran SECOND on a re-`adopt`ed table failed; whichever ran FIRST on a pristine fixture was clean.
  Block budget exonerated.
- Root cause: `drain_step` creates each child partition as a standalone table (`CREATE TABLE ... LIKE`)
  and ATTACHes it only at the END of that child's drain. While mid-drain it is un-attached, so
  `DROP TABLE <parent> CASCADE` (my fixture rebuild) does NOT drop it -- an un-attached child has no
  dependency on the parent. The next campaign re-`adopt`ed the recreated table, the next drain found
  the orphan by name and re-INSERTed rows whose ids already lived in it -> dup-key. Proof: dropping
  the orphan made the exact failing config drain cleanly (149/step, overlap=0), and running the
  block-budget variant FIRST on a pristine fixture was clean. F2's logic is correct and shippable.
- Fix (adopt-time guard): `_adopt` now refuses when a standalone (un-attached) table matching this
  parent's child-partition naming exists, with an actionable "drop the orphan" message -- turning a
  cryptic mid-drain dup-key into a clear up-front error. TDD via tests/18 (RED->GREEN). Full suite
  green PG 15/16/17/18 x psql/bundle/dbdev (18 files / 79 tests), clean uninstall.
- Note: the committed bench teardown (`bench/run_rung.sh`) uses `DROP SCHEMA bench CASCADE`, which
  DOES drop orphaned children (they live in the schema), so it was never affected; the footgun is
  table-level `DROP TABLE <parent> CASCADE`, which the guard now covers.

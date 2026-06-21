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

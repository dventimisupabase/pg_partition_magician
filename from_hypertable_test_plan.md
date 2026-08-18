# Test plan: `from_hypertable`

> **Frozen artifact: not current documentation.** A point-in-time record, kept for history and not
> maintained against the code, so it describes the system as it stood when written. For how
> pg_partition_magician works today see the [user guide](docs/guide.md) and the
> [reference](docs/reference.md).

Status: Draft / proposed
Companion to: `from_hypertable` design doc

## Why this is a separate track

The rest of pgpm's suite runs the matrix PG15-18 x install channels on stock Postgres images. `from_hypertable` cannot run there, because it needs TimescaleDB installed to have a hypertable to migrate from, and TimescaleDB is a preloaded C extension with a narrower version range than pgpm targets. The official `timescale/timescaledb` images are tagged per Postgres major (`<tsversion>-pg14|15|16|17`) and there is no pg18 image; Postgres 15 support is being removed from TimescaleDB in mid-2026. The population we actually migrate is Supabase PG15 (and soon PG14) on older Apache builds.

So `from_hypertable` is its own track: its own image, PG15-centric, run via a dedicated subcommand, kept out of the default `./test.sh` matrix.

### Apache vs the test image

Supabase ships TimescaleDB **Apache 2 Edition** (no compression, no continuous aggregates available). The `timescale/timescaledb` Docker image is the full **Community** edition, which *does* have compression and continuous aggregates. That mismatch is useful, not a problem: the Community image lets us construct the very objects we need to assert refusals or special handling against (compressed chunks, CAGGs), even though the target population can't have them. Happy-path tests use plain hypertables (the Apache-equivalent shape); refusal and edge tests use the Community-only features the image happens to provide.

## Harness changes

1. **Image.** Add `tests/timescale/Dockerfile` based on `timescale/timescaledb:<pinned>-pg15` (and a pg14 variant). Layer in pgTAP (the timescale image does not ship it) and `pg_prove`, copy in the pgpm source, and ensure `shared_preload_libraries='timescaledb'` is set. Pin an explicit TimescaleDB version rather than `latest`, and test against at least two: an older 2.x that approximates the oldest Apache build in the Supabase PG15 fleet, and a more recent 2.x, so the "works on the oldest build" claim in the design doc is actually exercised.

2. **Subcommand.** Add `./test.sh timescale [tsversion]` (and document it in ONBOARDING.md alongside the existing matrix). It builds the timescale image, installs pgpm, and runs `tests/timescale/*`. It is explicitly excluded from the default `./test.sh` run because it uses a different base image and a narrow PG range.

3. **Two execution modes.** Split the test files by whether they can run inside a single rolled-back transaction:
   - **Transactional** (`tests/timescale/txn/`): pre-flight refusals and pure structural assertions. Standard pgTAP per-file transaction with rollback. Fast, no cleanup.
   - **Disposable-database** (`tests/timescale/db/`): anything that exercises the batched copy loop, `regrain`, or `maintain`, all of which use procedures that `COMMIT` between batches and therefore cannot run inside an outer transaction. Each file runs against a freshly `createdb`'d database and drops it on teardown. `from_hypertable` itself commits (it drops the source and renames in a real transaction, and the copy loop commits per batch), so most happy-path tests live here.

4. **CI.** Add a separate GitHub Actions job for the timescale track, matrixed over the pinned TimescaleDB versions on PG15 (plus PG14). It does not run on the pg16/17/18 legs. Keep it required for merges that touch `from_hypertable` and the migration SQL.

## Fixtures

`tests/timescale/fixtures.sql`: helper functions to stamp out hypertables of known shapes, so test bodies stay declarative.

- `mk_plain_hypertable(rows, chunk_interval, span)` -> a time hypertable with a PK that includes the time column, populated with a known number of rows spread across a known number of chunks, time-ordered.
- `mk_hypertable_with_retention(...)` -> same, plus a `drop_chunks` retention policy at a known interval.
- `mk_hypertable_composite_pk(...)` -> composite PK `(id, time)` with an identity/sequence on `id`.
- `mk_hypertable_cagg(...)` -> plain hypertable plus a continuous aggregate (Community image only).
- `mk_hypertable_compressed(...)` -> plain hypertable with at least one compressed chunk (Community image only).
- `mk_hypertable_space(...)` -> a hypertable with a second (space) dimension via `add_dimension`.
- `snapshot_rows(tbl)` / `assert_same_rows(a, b)` -> capture and compare full row sets with symmetric `EXCEPT`, for fidelity checks.

## What is reused from existing transmute tests

`from_hypertable` ends by calling `transmute`, so the *result* state (native partitioned parent, bounded monolith with `[min, frontier]` bounds, empty default, PAUSED registration, monolith constraint validated) is already covered by the transmute suite. The new tests should call the existing transmute result-assertion helpers rather than re-asserting that structure. The genuinely new surface to test is everything upstream of the handoff: extraction fidelity, Timescale teardown, the refusals, retention translation, and the delta catch-up.

## Test groups

### A. Pre-flight refusals (transactional)

- **A1 refuse on continuous aggregate.** `mk_hypertable_cagg`, call `from_hypertable`, expect a clean `throws_ok` with a message naming the CAGG. Asserts we never silently destroy a materialized view.
- **A2 refuse on multiple dimensions.** `mk_hypertable_space`, expect `throws_ok` naming the space dimension. pgpm is single-key RANGE.
- **A3 refuse when control not in PK.** Hypertable with no primary key at all (the realistic failing shape, since Timescale forbids a PK that excludes the partition column). Expect `throws_ok`.
- **A4 disk estimate accounts for decompressed size.** Unit-test the pre-flight size estimator directly against `mk_hypertable_compressed`: assert the estimate reflects logical/decompressed size, not the on-disk compressed footprint, so the headroom gate is honest. (Estimator tested in isolation; the actual free-space check is environment-dependent and asserted via a stubbed input.)

### B. Happy-path fidelity and structure (disposable-db)

- **B1 row count.** `mk_plain_hypertable(N, ...)`, run `from_hypertable`, assert the result under the original name has exactly N rows.
- **B2 row fidelity.** `assert_same_rows(snapshot, result)` both directions empty. No row lost, altered, or duplicated.
- **B3 handoff occurred.** Result is `relkind 'p'`, registered in pgpm's config, PAUSED. (Reuse transmute helper.)
- **B4 monolith bounds.** Monolith partition is `[min(control), frontier]`; default exists and is empty. (Reuse transmute helper.)
- **B5 schema fidelity.** PK present and includes the control column; declared secondary indexes present; defaults, NOT NULL, CHECK constraints, and generated columns carried over.
- **B6 Timescale teardown.** No `_timescaledb_catalog.hypertable` row for the old name; no orphan chunk tables in `_timescaledb_internal`; the original name now resolves to the partitioned table.

### C. Timescale-specific handling (disposable-db)

- **C1 retention translation.** `mk_hypertable_with_retention(90 days)`, assert the resulting pgpm config has `retain = 90 days`.
- **C2 reads through compression.** `mk_hypertable_compressed`, run `from_hypertable`, assert B1/B2 still hold. Validates the design claim that the copy reads decompressed through Timescale's SELECT path and therefore does not need a compression-specific branch.
- **C3 identity continuity.** `mk_hypertable_composite_pk`, capture the sequence high-water mark, migrate, then insert a new row and assert it receives the next value with no collision and no gap that breaks uniqueness. (tests/timescale/db/04, db/11)
- **C4 change-tracking apparatus refusals.** `p_track_changes => true` is refused on a keyless table (no key to reconcile by) and on a key with a nullable non-control column (a NULL key component can never be reconciled). (tests/timescale/db/10, db/14)
- **C5 delta ordering column.** With tracking on, `<rel>_pgpm_delta` carries the monotonic `pgpm_seq` column (so the drain can batch by a watermark) and the cutover excludes it from the reconcile key set. (tests/timescale/db/14)
- **C6 apparatus cleanup.** After cutover, the `<rel>_pgpm_delta` table is gone, no `_pgpm_drainkey`/temp `_pgpm_new` index survives, and the final table carries no `pgpm_seq` column. (tests/timescale/db/10, db/14)

### D. Online and delta behavior (disposable-db)

`from_hypertable` exposes its phase boundaries as separate procedures (`from_hypertable_copy` then
`from_hypertable_cutover`), so writes can be injected between them without true concurrency, and the online
pre-drain (`from_hypertable_drain_delta` / `from_hypertable_drain_appends`) can be driven and observed on
its own.

- **D1 append-only catch-up.** Copy, then `INSERT` rows past the watermark into the still-live hypertable, then cutover. Assert the late rows are present. Covers the common append-only path. (tests/timescale/db/05)
- **D2 tracking reconcile.** Copy with `p_track_changes`, then UPDATE/DELETE/INSERT already-copied rows (including a key-changing UPDATE), then cutover. Assert the reconcile applied all three change kinds by key. (tests/timescale/db/10, db/14)
- **D3 online delta pre-drain.** With tracking, drain the delta **online (source still a live hypertable)** and assert the destination already reflects the changes *before* any cutover; a single `_step` reconciles a bounded batch; post-drain changes are still caught at cutover. (tests/timescale/db/14)
- **D4 online append pre-drain.** Without tracking, drain the appended tail **online** and assert the destination gained the appends before cutover; one `_step` copies a bounded batch; works on a keyless hypertable. (tests/timescale/db/15)
- **D5 threshold + convergence.** Draining with a threshold leaves a residual the cutover then finishes (correct final counts); the driver's iteration budget (`p_max_iter`) bounds non-convergence loudly rather than spinning. (tests/timescale/db/14, db/15)
- **D6 auto pre-drain via `p_predrain`.** The cutover (default `p_predrain => true`) drains a backlog above the threshold online before the lock, then finishes the residual under it — exercising the nested cutover -> drain -> per-batch-commit path. (tests/timescale/db/14)
- **D7 cutover isolation (stretch).** A `pg_isolation_regress` spec asserting reads/writes against the hypertable succeed throughout the copy and only block briefly during the cutover transaction. Lives in its own isolation harness, not pgTAP. (not yet implemented)

### E. Failure and rollback (disposable-db)

- **E1 abort before cutover.** Inject a failure mid-copy. Assert the source hypertable is intact and queryable, the destination is droppable, and no rows were lost from the source. Confirms the "nothing irreversible before cutover" property.
- **E2 cutover rollback.** Inject a failure inside the cutover transaction. Assert it rolls back whole: the original hypertable still exists and serves the same rows, and no half-renamed state remains.

### F. Version matrix (disposable-db, run per pinned TimescaleDB version)

Run B1-B6 and C1-C3 against each pinned TimescaleDB version on PG15 (and PG14). On the **oldest** pinned version specifically, add:

- **F1 catalog cleanup on old builds.** Confirm `DROP TABLE <hypertable>` removes chunks and catalog rows cleanly, since the teardown relies on Timescale's event trigger and we are betting it behaves identically on old builds.
- **F2 chunk exclusion on old builds.** Confirm the time-predicate batched copy drives single-chunk reads (via `EXPLAIN` on the copy query), so the loop stays one-chunk-per-batch rather than degrading to full scans per batch.
- **F3 drain + ordering column on old builds.** Confirm the online drain (delete-returning reconcile / append copy) and the `pgpm_seq GENERATED ALWAYS AS IDENTITY` column behave identically on the oldest pinned TimescaleDB version (both use standard PG15 features, so this is a confirmation, not an expected risk). Currently the default CI leg pins one version (2.16.1); the 2.9.x leg is run by manual dispatch.

## Open dependencies on implementation

Both items below were testability requirements when this plan was written; both are now satisfied by the
shipped design, so they are recorded as resolved rather than open:

1. **Phase boundaries callable separately** (group D) — `from_hypertable_copy`, `from_hypertable_cutover`, and the `from_hypertable_drain_delta`/`_appends` drivers are all separate, hand-drivable entry points.
2. **Disk/size estimator separately callable** (A4) — `from_hypertable_disk_estimate` / `from_hypertable_time_estimate` are standalone functions.

## Minimum bar to ship

Groups A, B, C, E on at least one pinned TimescaleDB version on PG15, plus F1-F2 on the oldest pinned version. Group D is now core, not optional: the online pre-drain is the cutover's main behavior, so D1-D6 are required (D2-D6 cover the tracking reconcile and the online delta/append pre-drain that keep the cutover lock brief). The isolation spec (D7) and the PG14 leg can follow.

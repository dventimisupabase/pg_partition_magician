# Test plan: `from_hypertable`

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
   - **Disposable-database** (`tests/timescale/db/`): anything that exercises the batched copy loop, `refine`, or `maintain`, all of which use procedures that `COMMIT` between batches and therefore cannot run inside an outer transaction. Each file runs against a freshly `createdb`'d database and drops it on teardown. `from_hypertable` itself commits (it drops the source and renames in a real transaction, and the copy loop commits per batch), so most happy-path tests live here.

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
- **C3 identity continuity.** `mk_hypertable_composite_pk`, capture the sequence high-water mark, migrate, then insert a new row and assert it receives the next value with no collision and no gap that breaks uniqueness.

### D. Online and delta behavior (disposable-db; phased API required)

These require simulating writes that arrive during the migration. To make that testable without true concurrency, `from_hypertable` should expose its phase boundaries (bulk-copy-to-watermark, then catch-up-and-cutover) rather than being a single opaque call. This is a testability requirement that feeds back into the implementation.

- **D1 append-only catch-up.** Bulk-copy to watermark T0, then `INSERT` rows with `control > T0` into the still-live hypertable, then run catch-up-and-cutover. Assert the late rows are present in the result. Covers the common append-only path.
- **D2 cutover isolation (stretch).** A `pg_isolation_regress` spec asserting that reads and writes against the hypertable succeed throughout the bulk-copy phase and only block briefly during the cutover transaction. Mirrors the style of Timescale's own `detach_chunk` isolation test. Lives in its own isolation harness, not pgTAP.

### E. Failure and rollback (disposable-db)

- **E1 abort before cutover.** Inject a failure mid-copy. Assert the source hypertable is intact and queryable, the destination is droppable, and no rows were lost from the source. Confirms the "nothing irreversible before cutover" property.
- **E2 cutover rollback.** Inject a failure inside the cutover transaction. Assert it rolls back whole: the original hypertable still exists and serves the same rows, and no half-renamed state remains.

### F. Version matrix (disposable-db, run per pinned TimescaleDB version)

Run B1-B6 and C1-C3 against each pinned TimescaleDB version on PG15 (and PG14). On the **oldest** pinned version specifically, add:

- **F1 catalog cleanup on old builds.** Confirm `DROP TABLE <hypertable>` removes chunks and catalog rows cleanly, since the teardown relies on Timescale's event trigger and we are betting it behaves identically on old builds.
- **F2 chunk exclusion on old builds.** Confirm the time-predicate batched copy drives single-chunk reads (via `EXPLAIN` on the copy query), so the loop stays one-chunk-per-batch rather than degrading to full scans per batch.

## Open dependencies on implementation

Two items in this plan require `from_hypertable` to be built with testability in mind:

1. Phase boundaries must be callable separately (group D), not buried inside one monolithic procedure.
2. The disk/size estimator must be a separately callable function (A4), not an inline check, so it can be asserted in isolation.

Both are reasonable to expose anyway for operational dry-run purposes, so they are not test-only concessions.

## Minimum bar to ship

Groups A, B, C, E on at least one pinned TimescaleDB version on PG15, plus F1 and F2 on the oldest pinned version. Group D's append-only catch-up (D1) is required if `from_hypertable` claims an online mode; the isolation spec (D2) and the PG14 leg can follow.

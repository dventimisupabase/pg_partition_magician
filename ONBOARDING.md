# Onboarding — pg_partition_magician

Welcome. This repo is **`pg_partition_magician`**: a lightweight, **pure-SQL**
RANGE-partition manager for PostgreSQL whose only runtime dependency is **pg_cron**.
It adopts an existing (possibly huge, live) table into a native partitioned table
*online*, then manages the lifecycle (premake → drain → retention) — across three
partition-key dimensions: **time**, **integer/bigint id**, and **UUIDv7/ULID**.

For *what it does and why*, read [`README.md`](./README.md). This file is about
*working in the repo*.

## Get it running (5 minutes)

The only prerequisite is **Docker**. Everything runs in containers — no Postgres,
psql, or other tooling needed on the host.

```bash
./test.sh 15        # PG 15: build a pg_cron+pgtap image, install each channel,
                    # load fixtures, run the 53-test pgTAP suite, verify uninstall
./test.sh           # the full matrix: PG 15, 16, 17, 18
```

`test.sh` exercises all three install channels (`psql`, bundle, dbdev) against a
throwaway container and tears it down after. To poke at it interactively, bring a
container up yourself:

```bash
docker compose --profile pg15 up -d
psql 'postgresql://postgres:postgres@127.0.0.1:5515/postgres' \
  -c 'create extension pg_cron; create extension pgtap;' \
  -f sql/pg_partition_magician.sql -f fixtures/demo.sql
psql 'postgresql://postgres:postgres@127.0.0.1:5515/postgres' -c 'select * from pgpm.status();'
docker compose --profile pg15 down -v
```

## Repo layout

| Path | What it is |
|---|---|
| `sql/pg_partition_magician.sql` | **The product.** The entire tool: schema `pgpm`, tables, functions, views. Pure SQL, idempotent. **Single source of truth.** |
| `sql/uninstall.sql` | Teardown (drops the `pgpm` schema + its cron jobs; leaves your data) |
| `extension.control` | TLE metadata (`requires = 'pg_cron'`) for dbdev / CREATE EXTENSION |
| `scripts/build_install_bundle.sh` / `build_dbdev_package.sh` | Build the bundle / minified dbdev channel artifacts from the source |
| `Dockerfile` / `docker-compose.yml` / `test.sh` | PG 15–18 channel test matrix (pg_cron + pgtap), Docker-only |
| `fixtures/demo.sql` | Builds + adopts the three demo tables (time / id / uuidv7); loaded by the harness, runnable by hand |
| `tests/*.sql` | pgTAP tests (one concern per file), run by `pg_prove` in the matrix |
| `README.md` | Product docs: dimensions, install channels, the design, the control-type contract |
| `postgresql_online_partition_migration_summary.md` | The original design doc the project grew from |

## The mental model (in one breath)

You can't convert a table to partitioned in place, so `adopt()` renames it aside,
makes a partitioned parent under the original name, and attaches the old table as
the **`DEFAULT` partition** (zero data movement). New writes route to premade
partitions; the `DEFAULT`'s **closed tail** drains into proper partitions in paced
microbatches. The unifying idea is the **frontier** (`now()` for time, `max(control)`
for id/uuidv7): intervals below it are closed/drainable, the one at it stays in the
`DEFAULT` until it closes. Adding a partition while the `DEFAULT` has data would scan
it under `ACCESS EXCLUSIVE`; we dodge that with `NOT VALID` CHECK → `VALIDATE` →
attach. See README for the full story.

## Developing here

**TDD is the norm** (see `~/.claude` global guidance and the existing suite). Add a
failing pgTAP test, then make it pass.

`sql/pg_partition_magician.sql` is the single source of truth — edit it directly.
The bundle and dbdev packages are built from it (`scripts/build_*.sh`); nothing else
needs to be kept in sync.

### The inner loop

```bash
# edit sql/pg_partition_magician.sql, then:
./test.sh 15                  # one version, all channels (~3-5 min on a cold image)
./test.sh 15 --channel=psql   # fastest: just the psql channel
./test.sh                     # full matrix PG 15-18 (what CI runs) before pushing
```

Each run starts from a fresh container and tears it down, so tests never depend on
leftover state. Within a run the pgTAP files use `begin/rollback`, so they don't
persist either.

### Adding a test

Drop `tests/NN_my_thing_test.sql` following the existing pattern:

```sql
create extension if not exists pgtap;
begin;
select plan(N);
-- assertions: is(), ok(), cmp_ok(), throws_ok(), lives_ok() ...
select * from finish();
rollback;
```

## Conventions

- **Branch** off `main` with Conventional Branches: `feat/…`, `fix/…`, `docs/…`,
  `chore/…` (kebab-case). Don't commit to `main` directly.
- **Conventional Commits** for messages.
- Workflow: implement → commit → push → PR → merge (squash/merge), delete branch,
  sync local `main`.
- **PostgreSQL 15** is the target (realistic older-but-supported workhorse; behavior
  is identical 15–17). Keep SQL PG-15-compatible.
- Pure SQL + pg_cron only — no new runtime dependencies, no compiled extensions.

## Gotchas worth knowing (learned the hard way)

- **`uuid` has no `min`/`max` aggregate.** Use `ORDER BY … LIMIT 1` (and qualify the
  column with a table alias, or a `::text` projection silently shadows it and sorts
  *lexically*).
- **Bounds are stored as text** in `pgpm.config` / `pgpm.part` so one code path serves
  every kind; cast per kind (`::timestamptz` / `::numeric` / `::uuid`) when comparing.
- **float/double are rejected** as control columns (imprecise boundaries; NaN/Inf
  poison the frontier).
- **UUIDv7/ULID can't be verified by type** — `adopt_by_uuidv7` samples and *warns* if
  the values look random (v4); `pgpm.check_uuidv7(table, col)` runs the check on demand.
- **Incoming FKs**: `adopt` refuses by default; `p_incoming_fks => 'drop'` records +
  drops them; `generate_fk_recovery()` emits the rebuild script.

## Where to go deeper

- `README.md` — dimensions, API, the control-type contract, design facts + timings.
- `sql/pg_partition_magician.sql` — heavily commented; the adapter layer
  (`_grid_floor`/`_grid_next`/`_encode`/`_decode`/`_frontier_native`/`_part_name`) is
  where new partition kinds plug in.
- `postgresql_online_partition_migration_summary.md` — the origin design doc.

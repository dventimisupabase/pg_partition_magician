# Onboarding: pg_partition_magician

Welcome. This repo is **`pg_partition_magician`**: a lightweight, **pure-SQL**
RANGE-partition manager for PostgreSQL whose only runtime dependency is **pg_cron**.
It transmutes an existing (possibly huge, live) table into a native partitioned table
*online*, then manages the lifecycle (obtain, drain, retain, refine) across three
partition-key dimensions: **time**, **integer/bigint id**, and **UUIDv7/ULID**.

For *what it does and how to use it*, read [`README.md`](./README.md) and the
[user guide](./docs/guide.md). This file is about *working in the repo*.

## Get it running (5 minutes)

The only prerequisite is **Docker**. Everything runs in containers: no Postgres,
psql, or other tooling needed on the host.

```bash
./test.sh 15        # PG 15: build a pg_cron+pgtap image, install each channel,
                    # load fixtures, run the pgTAP suite, verify uninstall
./test.sh           # the full matrix: PG 15, 16, 17, 18
./test.sh timescale # the from_hypertable track: TimescaleDB 2.9.1 + 2.16.1 / PG15
                    # (the big fleet clusters), its own image, NOT in the default matrix
                    # (TS_VERSIONS='2.9.1' ./test.sh timescale runs just one)
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
| `sql/from_hypertable.sql` | Optional TimescaleDB-only add-on: migrate a hypertable to a pgpm-managed partition set. Loaded on top of the core, only where `timescaledb` exists |
| `sql/uninstall.sql` | Teardown (drops the `pgpm` schema + its cron jobs; leaves your data) |
| `extension.control` | TLE metadata (`requires = 'pg_cron'`) for dbdev / CREATE EXTENSION |
| `scripts/build_install_bundle.sh` / `build_dbdev_package.sh` | Build the bundle / minified dbdev channel artifacts from the source |
| `Dockerfile` / `docker-compose.yml` / `test.sh` | PG 15–18 channel test matrix (pg_cron + pgtap), Docker-only |
| `fixtures/demo.sql` | Builds + transmutes the three demo tables (time / id / uuidv7); loaded by the harness, runnable by hand |
| `tests/*.sql` | pgTAP tests (one concern per file), run by `pg_prove` in the matrix |
| `tests/timescale/` | The `from_hypertable` track: its own `Dockerfile` (TimescaleDB + pgTAP), `fixtures.sql`, and `db/*.sql` tests, run by `./test.sh timescale` (disposable-db per file) |
| `README.md` | Overview, quickstart, and links into the docs |
| `docs/guide.md` | User guide: concepts, install, transmute, schedule, monitor, retain, FKs, ops |
| `docs/reference.md` | Reference for every public function and catalog object |
| `docs/runbook.md` | Operational runbook: symptom -> step-by-step procedures (e.g. RI violations after a preserve drain) |
| `REDESIGN.md` | The operating model and design rationale (the bounded-child transmute) |
| `postgresql_online_partition_migration_summary.md` | The original design doc the project grew from |

## The mental model (in one breath)

You can't convert a table to partitioned in place, so `transmute()` renames it aside,
makes a partitioned parent under the original name, and attaches the old table **intact**
as one bounded **monolith** child (zero data movement), under a fresh empty **`DEFAULT`**
net. New writes route to premade partitions; the `DEFAULT` stays empty (the assistant
**drain** evacuates any stray that lands there). The historical bulk stays in the monolith
until you **refine** it into proper partitions on demand, by copying (so no dead tuples, no
vacuum). The unifying idea is the **frontier** (`now()` for time, `max(control)` for
id/uuidv7): a child is *frozen* and refinable once its whole range is below it. The cutover
stays online via a scan-skip attach (`NOT VALID` CHECK → `VALIDATE` under a gentle lock →
attach). See REDESIGN.md for the full story.

## Developing here

**TDD is the norm** (see `~/.claude` global guidance and the existing suite). Add a
failing pgTAP test, then make it pass.

`sql/pg_partition_magician.sql` is the single source of truth; edit it directly.
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
- Pure SQL + pg_cron only: no new runtime dependencies, no compiled extensions.

## Gotchas worth knowing (learned the hard way)

- **`uuid` has no `min`/`max` aggregate.** Use `ORDER BY … LIMIT 1` (and qualify the
  column with a table alias, or a `::text` projection silently shadows it and sorts
  *lexically*).
- **Bounds are stored as text** in `pgpm.config` / `pgpm.part` so one code path serves
  every kind; cast per kind (`::timestamptz` / `::numeric` / `::uuid`) when comparing.
- **float/double are rejected** as control columns (imprecise boundaries; NaN/Inf
  poison the frontier).
- **UUIDv7/ULID can't be verified by type**: the uuidv7 kind is assigned to a `uuid`
  control column (PostgreSQL has no UUIDv7 type to detect); `transmute` samples and *refuses* if the
  values look overwhelmingly random (v4), unless `p_force_uuidv7 => true`;
  `pgpm.check_uuidv7(table, col)` runs the check on demand.
- **Incoming FKs**: `transmute` refuses by default; `p_incoming_fks => 'preserve'` records +
  drops them for the conversion, and `restore_incoming_fks` re-adds them against the new
  parent once the drain is idle.

## Releasing and publishing

Tag a version and CI does the rest (`.github/workflows/release.yml`):

```bash
git tag v0.1.0 && git push origin v0.1.0
```

On a `v*` tag the Release workflow runs the full PG 15-18 channel matrix, creates a GitHub Release
with the bundle + minified dbdev package + a source tarball (release notes pulled from
`CHANGELOG.md`), then calls `publish-dbdev.yml` to push the package to
[database.dev](https://database.dev). You can also run either workflow manually via
*workflow_dispatch* with an explicit version.

> **One manual step CI can't do:** on a version bump, bump the pinned `version '…'` in the dbdev
> `create extension` example in [`docs/guide.md`](./docs/guide.md#install). The install page fills it
> in from the release tag automatically; the docs copy is pinned by hand (dbdev recommends pinning).

**One-time setup for publishing** (the publish job is inert until both exist):

1. Create a [database.dev](https://database.dev) account and an API token.
2. Add it as a repo secret named **`DBDEV_TOKEN`** (Settings → Secrets and variables → Actions). The
   package publishes under your account handle as `@dventimisupabase/pg_partition_magician`.

> The dbdev channel is build- and psql-install-tested in CI, but the TLE `CREATE EXTENSION` path
> itself is exercised at publish/install time (no dbdev account in CI).

## Where to go deeper

- [`docs/guide.md`](./docs/guide.md) and [`docs/reference.md`](./docs/reference.md): the user-facing
  guide and the full function/catalog reference.
- [`REDESIGN.md`](./REDESIGN.md): the operating model and design rationale (the bounded-child transmute,
  the refine machinery, and the foundational supply/demand principles).
- `sql/pg_partition_magician.sql`: heavily commented; the adapter layer
  (`_grid_floor`/`_grid_next`/`_encode`/`_decode`/`_frontier_native`/`_part_name`) is
  where new partition kinds plug in.
- `postgresql_online_partition_migration_summary.md`: the origin design doc.

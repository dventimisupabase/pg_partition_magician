# Onboarding — pg_partition_magician

Welcome. This repo is **`pg_partition_magician`**: a lightweight, **pure-SQL**
RANGE-partition manager for PostgreSQL whose only runtime dependency is **pg_cron**.
It adopts an existing (possibly huge, live) table into a native partitioned table
*online*, then manages the lifecycle (premake → drain → retention) — across three
partition-key dimensions: **time**, **integer/bigint id**, and **UUIDv7/ULID**.

For *what it does and why*, read [`README.md`](./README.md). This file is about
*working in the repo*.

## Get it running (5 minutes)

Prereqs: **Docker** (running) and the **Supabase CLI** (`supabase --version`, tested
on 2.105). The local stack is pinned to **PostgreSQL 15** (`supabase/config.toml`).

```bash
supabase start          # first run pulls images
supabase db reset       # apply migrations: install pgpm + adopt the 3 demo tables
supabase test db        # run the pgTAP suite (53 tests, 13 files)
```

After `db reset` you have three adopted demo tables — `public.messages` (time),
`public.events_id` (id), `public.events_uuid` (uuidv7) — each RANGE-partitioned with
maintenance **paused**. Inspect with:

```sql
select * from pgpm.status();
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres   -- local DB URL
```

## Repo layout

| Path | What it is |
|---|---|
| `sql/pg_partition_magician.sql` | **The product.** The entire tool: schema `pgpm`, tables, functions, views. Pure SQL, idempotent. **Single source of truth.** |
| `supabase/migrations/0001..0002` | Demo: create + seed the unpartitioned `messages` table |
| `supabase/migrations/0003_install_pg_partition_magician.sql` | **A copy of `sql/pg_partition_magician.sql`** (see gotcha below) |
| `supabase/migrations/0004..0005` | Demo: `adopt` the time / id / uuidv7 tables + schedule paused pg_cron maintenance |
| `supabase/tests/*.sql` | pgTAP tests (one concern per file) |
| `README.md` | Product docs: dimensions, the design, the control-type contract |
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

### ⚠️ The one gotcha that will bite you

`sql/pg_partition_magician.sql` is the source of truth, but Supabase migrations
can't `\i` an external file, so `supabase/migrations/0003_install_pg_partition_magician.sql`
is a **hand-kept copy**. After editing the module you **must** re-sync:

```bash
cp sql/pg_partition_magician.sql supabase/migrations/20260618000003_install_pg_partition_magician.sql
```

Forgetting this means your changes don't take effect on `db reset`. (Automating /
de-duplicating this is a known deferred TODO.)

### The inner loop

```bash
# edit sql/pg_partition_magician.sql
cp sql/pg_partition_magician.sql supabase/migrations/20260618000003_install_pg_partition_magician.sql
supabase db reset && supabase test db
```

`supabase test db` assumes a **freshly reset** DB (data in the `DEFAULT`, maintenance
paused) — always `db reset` first; a live drain mutates committed state. Tests run in
`begin/rollback`, so they don't persist.

### Adding a test

Drop `supabase/tests/NN_my_thing_test.sql` following the existing pattern:

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

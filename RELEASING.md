# Releasing pg_partition_magician

## What a version number promises

Versions are `MAJOR.MINOR.PATCH`, and the contract is the surface an installed database depends on.
That surface is wider than a list of functions, so it is spelled out:

- **The callable surface.** Every `pgpm.*` function and procedure: name, argument names, argument
  types, argument defaults, return type. Helpers prefixed `_` are internal and carry no promise.
- **The configuration tables.** `pgpm.config` and `pgpm.part`, including the *meaning* of each column.
  A column whose units or default change is a breaking change even though its name did not move.
- **`pgpm.log.action` values.** Operators build alerts on these strings, so renaming one, or ceasing
  to log an event, breaks monitoring that no test here will notice. Non-success events are prefixed
  (`skip_drain`, `fail_retain_drop`) and never suffixed; that is part of the promise, because it is
  what lets an alert match exact values instead of `drain%`.
- **The supported PostgreSQL majors.** Currently 15, 16, 17 and 18. Dropping one is a MAJOR change.
- **The version string itself.** `pgpm.version()`, `extension.control`'s `default_version`, and the
  git tag all carry the same value. `tests/84_version_test.sql` asserts the shape; keep the three in
  step by hand at release time.

What is explicitly *not* promised: partition child names, the contents of `pgpm.log` rows beyond
`action`, anything under `bench/`, and any behaviour reached only by writing to a pgpm table directly
instead of through its wrapper function.

## Before 1.0

`0.MINOR.PATCH`. A MINOR bump may break any of the above, provided the release notes say so and give
the migration. This is the only license pre-1.0 buys, and it should be spent deliberately rather than
treated as a blanket exemption.

`1.0.0` means the callable surface is frozen under semver. The bar for spending that number:

- A production install has run a full lifecycle: transmute, obtain, retain, and a retention drop.
- An in-place upgrade has been performed on a production database, not just in CI.
- Three installs exist that no maintainer hand-held.
- A deprecation policy is published (see the TODO below) and `SECURITY.md` has a working report route.

## Cutting a release

Two files carry the version and both must move together:

```bash
# 1. Bump both, to the same value.
#    pgpm_core/install.sql        the pgpm.version() literal, at the end of the file
#    pgpm_core/extension.control  default_version
#
# 2. Rename the CHANGELOG heading for the release.
#    ## [Unreleased]   ->   ## [0.2.0] - 2026-08-20
#
# 3. The full gate. Not ./test.sh all, which skips five tracks.
./test.sh ci

# 4. Tag and push. Everything after this is automated.
git tag v0.2.0
git push origin v0.2.0
```

Pushing a `v*` tag runs `.github/workflows/release.yml`, which validates the tag shape, runs the
PG 15-18 matrix and the TimescaleDB track, builds the three assets (dashboard bundle, dbdev package,
source tarball), publishes the GitHub Release, and then publishes to database.dev.

Two traps in that pipeline:

- **The CHANGELOG heading is matched exactly.** `release.yml` looks for `## [0.2.0]`. When it cannot
  find one it falls back to a raw `git log` dump without failing, so a mistyped heading produces a
  release whose notes are a commit list. Check the heading before tagging.
- **The tag regex is looser than the version contract.** CI accepts `v0.2`, but `pgpm.version()` is
  asserted to be a bare semver triple. Always tag the triple.

## install.sql is the upgrade path

For the `install.sql` channel there is no separate migration script: operators re-run the file over a
live database, and that *is* the upgrade. Which means a new column reaches an existing database only if
install.sql also carries a line for it:

```sql
alter table pgpm.config add column if not exists obtain_retry_after timestamptz;
```

There are fourteen such lines and they are hand-maintained. **Any change to a `create table` body in
install.sql needs a matching backfill line in the same commit.** Adding a column and forgetting the
line leaves every fresh install correct and every existing install broken, and it is invisible to the
pgTAP suite, which installs fresh into one database per file and never upgrades anything.

`bench/upgrade_in_place.sh` is the guard for exactly this: it installs, degrades the database to an
older shape, re-runs install.sql, and requires the result to be catalog-identical to a fresh install
with its managed tables still working. Its mutation is `upgrade_no_column_backfill`.

The same rule applies to anything else an existing database would miss: a new table needs
`create table if not exists`, a dropped column needs `drop column if exists`, and a changed function
needs `create or replace` rather than `create`.

## Channels

Three install channels exist, and they are not equally exercised:

- **`psql -f pgpm_core/install.sql`.** The tested channel, and the one under pilot. Idempotent and
  re-runnable by design, per the section above.
- **Dashboard bundle.** A single-file concatenation built at release time from the same source.
- **database.dev / TLE.** Published at release time. `ALTER EXTENSION ... UPDATE` is *not* wired up:
  there are no `--0.1.0--0.2.0.sql` migration files, so upgrading on this channel means re-running the
  package body, the same as the install.sql channel.

Prefer one channel per engagement. Supporting a pilot across all three triples the surface for no gain.

## TODO: cadence and deprecation

Deferred deliberately. While iteration speed matters more than predictability, releases are cut when a
coherent set of fixes lands, plus out-of-band patch releases for data-loss-class bugs.

Two things to settle before the install base is real:

1. **A cadence anchored to PostgreSQL's.** PostgreSQL ships a major each September or October, so one
   release a year has to be the "supports PG *N*" release, prepared during that beta rather than after
   its GA. That external calendar is worth more to operators than an invented quarterly one.
2. **A deprecation policy**, which is what actually buys predictability. The shape to adopt: anything
   deprecated in release *N* keeps working through *N+2* and for at least 90 days, emitting a warning
   to `pgpm.log` in the meantime.

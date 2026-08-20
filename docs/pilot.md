# Running a pilot

pg_partition_magician is pre-1.0 and every early install is a pilot with a named human behind it. This
is the template for one. Fill in the bracketed parts, agree it with the customer in writing *before*
anything is installed, and keep the filled copy where both sides can find it.

## 1. What this is, and what it is not

State this plainly, because the failure mode of an engineer-led pilot is a customer who believes they
have bought something. Nothing below is boilerplate; each line exists because its absence has cost
somebody a bad afternoon.

- pg_partition_magician is an open-source project under Apache 2.0. It is **not** a product of, or
  supported by, any vendor whose other services you use.
- It is **not covered by any support contract or SLA you already hold**. A pgpm problem is not a
  ticket you can escalate through your usual channel.
- There is **no warranty**. The license says so in sections 7 and 8, and it means it.
- Support during the pilot is **best-effort, from [maintainer name] personally**, on the terms in
  section 6.
- It **has never run in production anywhere else**. You are the first. Everything below is designed
  around that being true.

Ask for an explicit acknowledgement, by email, from whoever owns the database. Not to create a paper
trail, but because a stakeholder who has not internalised the list above will make a planning mistake
with it.

## 2. The hypothesis

A pilot without a written success condition does not fail, it fades, and nobody learns anything.

- **Table**: `[schema.table]`, `[N]` rows, `[M]` GB, growing `[R]` per day.
- **What it costs today**: `[the actual pain: query latency at p99, storage bill, vacuum duration,
  a maintenance window you cannot take]`.
- **Hypothesis**: pgpm converts it to a partitioned table with retention, online, and `[the measured
  quantity]` improves to `[target]`.
- **Success**: `[one number, measured the same way before and after]`.
- **Timebox**: `[6 to 8 weeks]`, reviewed at `[date]`.
- **Failure is an acceptable outcome.** If the hypothesis is wrong we stop at the rung we reached and
  you are no worse off. Section 4 is what makes that true.

## 3. The ladder

One rung at a time, with an explicit go/no-go before the next. Do not compress this because a rung
went well; the whole point is that each rung risks strictly more than the one before it.

| Rung | Where | What | Go/no-go |
| --- | --- | --- | --- |
| 0a | A clone or branch, no traffic needed | `transmute` the real table with its real schema, then `regrain`, then retention and archiving if the key is time-like | Schema fidelity checklist below passes; rows survive by identity; maintenance does real work |
| 0b | The same clone, plus a synthetic workload | The concurrency claims: conversion while readers and writers are live | No reader or writer error; nothing blocked beyond `p_lock_timeout`; the probe observed the conversion actually in progress |
| 1 | Production, a low-value table | Install, register, retention only. No conversion | A week with no `fail_%` in `pgpm.log` and no operator surprises |
| 2 | Production, the target table | `transmute` in a low-traffic window, maintainer live on a call | Conversion completes inside the agreed window; reads and writes never blocked longer than `p_lock_timeout` |
| 3 | Production, steady state | Scheduled maintenance, hands off | Two weeks clean, and your on-call can read the health checks in section 5 unaided |

Rung 0 is not optional and it uses **your** schema, not a fixture. The failure modes that matter here
are schema-shaped: an RLS policy dropped, a trigger lost, an identity column downgraded. On a database
where row-level security is how the application does authorization, silently losing a policy is an
authorization incident and not a bug report.

`transmute` registers a table **paused**, so conversion and going live are separate decisions. Use
that: convert, inspect, and only then `pgpm.resume`.

### Why 0a and 0b are separate rungs

A clone with no traffic on it is the usual starting arena, and it establishes a lot: that the
conversion is correct, that the schema survives it, that regrain moves a monolith onto a finer grid,
and (for a time-like key) that obtain, retention and archiving do real work on a schedule. Those are
prerequisites for everything else, and they are cheap to check where no user can be hurt.

What it cannot establish is anything about **concurrency**, and that is a different claim rather than a
weaker version of the same one:

- "No reader or writer was blocked" is trivially true where there are no readers or writers. It is
  satisfied by an execution with nothing to block, so on an idle clone it is not evidence.
- `p_lock_timeout` never exercises. With no competing lock the request is granted immediately, so the
  path that bounds a wait is never taken.
- `transmute` splits itself across three transactions specifically so that no ACCESS EXCLUSIVE is held
  across its validation scan. With no concurrent reader, holding it and not holding it look identical.

So 0a proves the conversion is correct and 0b proves it is *online*. Skipping 0b does not make the
ladder shorter, it moves the first real test of online-ness to rung 2, in production, which is the
least forgiving place to learn about it. 0b needs only a writer inserting at the frontier and a reader
running the application's hot query, both live for the duration of the conversion.

Both are provided. `bench/pilot_workload.sql` generates the workload for your table by reading the
catalog: it copies an existing row with the control column overridden, so every NOT NULL, foreign key
and check is satisfied by construction, and it dry-runs the statement before handing it to anything.
`bench/transmute_online.sh` then converts under that load and reports.

```bash
psql "$DSN" -f bench/pilot_workload.sql
psql "$DSN" -c "call pgpm_probe.install('public.events','created_at')"
bench/transmute_online.sh "$DSN" public.events created_at '1 month'
psql "$DSN" -c "drop schema pgpm_probe cascade"      # when finished
```

The probe refuses to draw a conclusion it has not earned: it checks that the workload was committing
writes before the conversion and again during it, and that it caught the validation scan in progress.
If the workload is not actually running it fails rather than reporting success, so a 0b run cannot
quietly degrade into a 0a run. `bench/README.md` records how it was verified against a mutation that
reintroduces the defect. The table **is** converted when it finishes, so run it on the clone.

### If the control column is a `uuid`, check this first

pgpm derives the forward frontier differently per control kind, and `uuid` (`uuidv7`) is the one case
where a stale clone matters. A `timestamptz` key grids against the clock, and an integer key cannot
fall behind where the next write goes, so neither is affected. For a `uuid` key the frontier is the
newest **stored value**, so on a clone that has received no writes it stays frozen wherever the data
ended while the clock moves on:

```sql
-- On the clone, before transmute. max(uuid) does not exist in PostgreSQL, hence ORDER BY ... LIMIT 1.
select now() - (select pgpm._uuid_to_ts(<control>) from <table> order by <control> desc limit 1)
         as gap_to_now;
```

If `gap_to_now` exceeds `obtain x step`, no partition covers the present and every new write is
rejected with a bare `no partition of relation ... found for row`. It does not recover on its own.
Choose `obtain x step` to comfortably exceed the clone's age, and remember an idle clone keeps ageing
while nothing advances its frontier.

### Retention on an idle clone is a ratchet

For time-like keys the retention boundary is `now() - retain`, measured against the present rather than
against the data's own timeline. On a clone whose newest row is already days old, the whole dataset
starts that much closer to being dropped and moves further every day, and on an idle clone nothing
arrives to replace what goes.

This matters most for the obvious rung-0a experiment, "prove that retention drops old partitions." On a
live table a short `retain` trims the tail. Here it can take far more than intended, and at the limit it
empties the table. Derive the `retain` value from the clone's actual data span rather than from what
production will eventually use, and branch or snapshot before testing retention so the arena can be
restored.

## 4. Stopping

Agree this before the install, not during the incident.

**Stop everything, now.** This is the kill switch, and it needs no maintainer:

```sql
select pgpm.unschedule();   -- removes every pgpm cron job
```

**Stop acting on one table**, leaving the rest scheduled:

```sql
select pgpm.pause('schema.table');
```

**What a stopped pgpm leaves behind**, stated precisely, because "nothing breaks" would be an
overstatement. Your table is a native PostgreSQL partitioned table and it keeps serving reads and
writes with pgpm gone: no trigger, no view, no function of ours sits in the query path. What stops is
the *minting of new partitions*, and with no DEFAULT partition an insert past the newest bound is
rejected. So the kill switch buys you exactly as much time as your forward headroom:

```sql
select parent, paused, n_partitions, newest_bound, retain_backlog from pgpm.status();
```

With `obtain => N` and a step of one month, `newest_bound` is roughly `N` months out. That is the
window to fix things in, and it is why `obtain` should be generous during a pilot.

**Reverse the conversion.** `pgpm.untransmute()` puts the table back, metadata-only and in
milliseconds, because the original table was only renamed and attached:

```sql
select pgpm.untransmute('schema.table');
```

It **refuses** once rows live outside the original monolith: after the write frontier crosses the
original bound, after a backdated insert lands in a newer partition, or once a regrain has begun. That
is a one-way door and it is documented as one. Before rung 3, untransmute is a live option. After it,
the fallback is point-in-time recovery, which is why rung 2 should land on a table where a PITR restore
is tolerable.

## 5. Health the customer can check without us

If assessing pgpm requires messaging the maintainer, it is not a pilot, it is a dependency on a person.
These are the two queries your on-call needs.

Per-table state, and the one to put on a dashboard:

```sql
select parent, paused, n_partitions, newest_bound,
       retain_backlog, retain_drop_failures, fks_suspended, fks_unvalidated, parent_missing
  from pgpm.status();
```

Healthy looks like: `paused` false, `newest_bound` comfortably ahead of now, and
`retain_backlog`, `retain_drop_failures`, `fks_suspended`, `fks_unvalidated` all zero, with
`parent_missing` false.

Anything pgpm declined or failed to do, most recent first:

```sql
select at, parent_table, action, lo, hi, rows
  from pgpm.log
 where action like 'fail%' or action like 'skip%'
 order by id desc limit 50;
```

Every non-success action is prefixed, never suffixed, so those two patterns catch all of them and
nothing else. `skip_*` means pgpm deliberately deferred (a lock it declined to wait for, an archive
gate not satisfied) and is often routine. `fail_*` means an operation did not complete and is worth a
message. The values in use are `fail_detach_reap`, `fail_restore_incoming_fk`, `fail_retain_crossing`,
`fail_retain_detach`, `fail_retain_drop`, `fail_validate_incoming_fk`, `skip_archive`, `skip_obtain`,
`skip_regrain`, `skip_restore_fk`, `skip_retain`, `skip_validate_fk` and `skip_write_block`.

Always include `select pgpm.version()` when reporting anything.

## 6. Support

- **Channel**: `[shared Slack channel]`. Not a personal DM, so it survives one person being away.
- **Normal bugs**: acknowledged within `[one business day]`.
- **Data-loss or availability class**: `[phone number]`, any hour. Say explicitly what counts.
- **Escalation**: `[named second person]`, who has `[read access to the repo / context on the pilot]`.
- **Gaps**: `[known vacation dates]`, and what happens during them.
- Fixes land in a tagged release, not on `main`. You install tags. See `RELEASING.md`.

## 7. What each side gets

Say this out loud at the start, while everyone is enthusiastic, rather than at the end when it has to
go through legal.

- **You get**: early access, direct access to the maintainer, and real influence on what gets built.
  Bugs you hit get fixed first.
- **The project gets**: bug reports, and permission to say publicly that this ran in production.
- **Naming and publication**: `[may we name you / write this up / use a logo, and who approves]`.
  Decide now, in writing, and honour a no without renegotiating.

## 8. Exit

At `[review date]`, one of three things is written down and shared:

1. **Success.** The metric moved. Agree what ongoing support looks like now that the pilot is over,
   because "pilot forever" is the default outcome nobody chose.
2. **Inconclusive.** Extend once, with a changed hypothesis, or stop.
3. **Stop.** Unschedule, uninstall (`pgpm_core/uninstall.sql` removes the manager and leaves your data
   partitioned and intact), and write down what was learned. This is a perfectly good outcome and
   should not be treated as a failure to be avoided.

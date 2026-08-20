# Security policy

## Reporting a vulnerability

Please report privately rather than in a public issue.

- Preferred: GitHub private vulnerability reporting, from this repository's **Security** tab,
  **Report a vulnerability**.
- If that is unavailable: email <david.ventimiglia@supabase.io> with `pg_partition_magician` in the
  subject.

Useful in a report: the PostgreSQL major, the output of `select pgpm.version()`, the call that triggers
it, and what an attacker gains. A reproduction against a scratch database is worth more than anything
else you can send.

What to expect: an acknowledgement within three business days, an assessment within ten, and credit in
the release notes unless you would rather not be named. This is a single-maintainer project, so please
read those as good-faith intent and not as a contractual SLA.

Please do not run vulnerability testing against a database you do not own.

## Supported versions

Before 1.0, only the most recent release receives fixes. There are no backports to earlier tags. A
fix ships in the next release, or immediately as a patch release when it is severe.

## Scope

In scope:

- Privilege escalation through any `pgpm.*` function: any path by which a caller performs an action
  their own grants would not permit.
- SQL injection through a value pgpm interpolates into dynamic SQL, including table, column, index,
  constraint, and role names.
- Loss, corruption, or exposure of committed rows in a managed table, including a partition made
  visible to a role that cannot see the parent.
- A lock, write-block trigger, or scheduled job that pgpm fails to release or unschedule, where the
  result is a denial of service disproportionate to the operation.

Out of scope:

- PostgreSQL itself, `pg_cron`, the host, and anything reachable only with an existing superuser.
- An operator holding privileges they should not hold. pgpm needs the rights to run DDL against the
  tables it manages, and it cannot be safer than the role it is called as.
- Documented one-way doors and documented refusals. `pgpm.untransmute()` declining once the frontier
  has passed the original bound is the design, not a defect.
- Resource use inherent to an operation, such as the disk a regrain's copy needs.

## Design properties relevant to a review

Stated so a reviewer can check them rather than infer them:

- **No `SECURITY DEFINER`.** pgpm installs none, so every function runs with the privileges of the
  caller and pgpm adds no privilege boundary of its own to be crossed.
- **No superuser requirement.** pg_cron needs a superuser to create the extension, which is a
  PostgreSQL constraint on `CREATE EXTENSION`; pgpm's own functions do not.
- **Identifiers are quoted in dynamic SQL.** pgpm builds DDL as text. Identifiers pass through
  `format(%I)` or `quote_ident()`, including role names recovered via `pg_get_userbyid()`.
- **Retention destroys data on purpose.** `retain` drops partitions and `retire` archives then drops
  them. A configuration that drops data sooner than intended is an operator error, not a
  vulnerability, but a case where pgpm drops a partition the configuration should have kept is very
  much one.

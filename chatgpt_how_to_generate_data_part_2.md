# Generating Large Volumes of Test Data Locally in PostgreSQL

# Part II: Advanced Techniques and Production-Like Workloads

## Introduction

Part I focused on the mechanics of generating large quantities of data efficiently inside PostgreSQL. However, many real-world testing scenarios require more than simply creating millions or billions of rows.

Production databases exhibit numerous characteristics that are difficult to reproduce with naïve synthetic datasets:

* Data skew.
* Hot spots.
* Large TOAST values.
* Table and index bloat.
* Partition imbalance.
* WAL pressure.
* Autovacuum activity.
* Referential integrity constraints.
* Mixed OLTP and analytical workloads.

This document surveys techniques for reproducing these characteristics for testing and benchmarking.

---

# 1. Generate Realistic Data Distributions

Uniform randomness is usually unrealistic.

Naïve:

```sql
(random() * 1000000)::int
```

Every value is equally likely.

Production systems often exhibit heavy skew.

Examples:

* 20% of customers generate 80% of traffic.
* Recent partitions receive most writes.
* Certain products become "hot."

---

## Zipfian Distributions

Many production workloads approximately follow Zipf's Law.

Examples:

* Social media users.
* Product popularity.
* Search terms.
* Tenant activity.

Approximation:

```sql
SELECT floor(power(random(), 3) * 1000000);
```

Increasing the exponent creates stronger skew.

---

## Time Skew

Real databases are rarely uniformly distributed over time.

Uniform:

```sql
now() - random() * interval '1 year'
```

More realistic:

```sql
now() - power(random(), 5) * interval '1 year'
```

Most rows become recent.

Useful for:

* Partition testing.
* BRIN indexes.
* HOT updates.
* Autovacuum behavior.

---

# 2. Generate TOAST Data

Many benchmarks ignore TOAST entirely.

Small rows:

```sql
CREATE TABLE t (
    id bigint,
    name text
);
```

Real applications often contain:

* JSON documents.
* User profiles.
* Logs.
* HTML.
* Markdown.

Example:

```sql
repeat(md5(random()::text), 500)
```

Produces large text values.

Or:

```sql
jsonb_build_object(
    'user', gs,
    'payload', repeat('x', 10000)
)
```

Useful for testing:

* TOAST tables.
* Compression.
* WAL volume.
* Vacuum performance.

---

# 3. Intentionally Create Bloat

Many production issues involve bloat.

Generate:

```sql
INSERT ...

UPDATE ...

UPDATE ...

DELETE ...
```

Repeated updates produce dead tuples.

Example:

```sql
UPDATE t
SET payload = md5(random()::text)
WHERE random() < 0.2;
```

Repeated cycles generate:

* Heap bloat.
* Index bloat.
* Free space fragmentation.

Useful for:

* Vacuum testing.
* Autovacuum tuning.
* REINDEX experiments.

---

# 4. Generate HOT and non-HOT Updates

HOT updates are critical to PostgreSQL performance.

HOT eligible:

```sql
UPDATE users
SET last_seen = now();
```

Non-HOT:

```sql
UPDATE users
SET email = md5(random()::text);
```

if email is indexed.

A realistic benchmark should include both.

---

# 5. Simulate Real Delete Patterns

Many synthetic datasets never delete rows.

Production systems do.

Patterns:

### Random deletes

```sql
DELETE
FROM t
WHERE random() < 0.01;
```

### Time-based deletes

```sql
DELETE
FROM events
WHERE ts < now() - interval '90 days';
```

### Tenant deletes

```sql
DELETE
FROM users
WHERE tenant_id = 42;
```

Different delete patterns stress PostgreSQL differently.

---

# 6. Generate Referential Integrity

Single-table benchmarks miss important behaviors.

Example:

Customers:

```text
1 million
```

Orders:

```text
100 million
```

Line items:

```text
500 million
```

Generate parents first:

```sql
customers
```

Then children:

```sql
customer_id =
(random()*1000000)::int
```

This exercises:

* Foreign keys.
* Join planning.
* Cascading deletes.
* Index maintenance.

---

# 7. Generate Partition Skew

Perfectly balanced partitions rarely occur.

Instead:

```text
January:
5 million

February:
7 million

March:
50 million

April:
80 million
```

Useful for:

* Planner behavior.
* Pruning.
* Vacuum scheduling.
* Maintenance operations.

---

# 8. Generate WAL Pressure

Sometimes the goal is WAL testing.

Strategies:

Large transactions:

```text
1 billion inserts
```

Many small transactions:

```text
100,000 commits
```

Large updates.

Large deletes.

Bulk COPY.

Measure:

* WAL generation.
* Checkpoints.
* Replication lag.

---

# 9. COPY FREEZE

A lesser-known optimization.

```sql
COPY table
FROM ...
FREEZE;
```

or equivalent loading strategies.

Benefits:

* Reduces future vacuum work.
* Marks tuples frozen immediately.

Useful for:

* Static historical partitions.
* Bulk imports.

Limitations apply.

---

# 10. Drop Indexes First

Instead of:

```text
Insert

Maintain indexes

Maintain constraints
```

Consider:

```text
Load data

Build indexes

Validate constraints
```

Often dramatically faster.

Workflow:

```text
CREATE TABLE

COPY

CREATE INDEX

ANALYZE
```

---

# 11. Disable Foreign Key Validation Temporarily

Sometimes bulk loading benefits from:

```text
NOT VALID
```

Then:

```sql
ALTER TABLE
VALIDATE CONSTRAINT;
```

This can reduce load time substantially.

---

# 12. Generate Analytical Workloads

Not every benchmark is OLTP.

Fact table:

```text
1 billion rows
```

Dimension tables:

```text
Thousands
```

Useful for:

* Hash joins.
* Parallel aggregation.
* Partition pruning.
* Bitmap scans.

---

# 13. Generate Multi-Tenant Workloads

Common SaaS pattern:

```text
100,000 tenants
```

Small tenants:

```text
10 rows
```

Large tenants:

```text
100 million rows
```

This creates realistic planner challenges.

---

# 14. Generate Lock Contention

Concurrency matters.

Session A:

```sql
BEGIN;

UPDATE ...
```

Session B:

```sql
UPDATE ...
```

Session C:

```sql
ALTER TABLE ...
```

Useful for:

* Deadlock testing.
* Lock queues.
* Timeout behavior.

---

# 15. Generate Autovacuum Workloads

Autovacuum rarely gets enough attention.

Pattern:

```text
Insert

Update

Delete

Repeat
```

Observe:

* Dead tuples.
* Vacuum frequency.
* Freeze age.
* Visibility map growth.

---

# 16. Generate Replication Workloads

Logical replication:

Large transactions.

Many tiny transactions.

DDL changes.

Large TOAST values.

Physical replication:

Checkpoint storms.

Bulk loads.

Large WAL bursts.

---

# 17. Generate Catalog Growth

Large systems often have:

Thousands of partitions.

Thousands of indexes.

Many schemas.

Many temporary tables.

This stresses:

* System catalogs.
* Planning time.
* DDL performance.

---

# 18. Simulate Checkpoint Pressure

Generate sustained writes exceeding checkpoint completion rates.

Observe:

* Checkpoint duration.
* Write amplification.
* Buffer eviction.
* Backend fsync activity.

This is particularly useful when evaluating storage systems.

---

# 19. Build Production-Like JSON

Instead of:

```json
{"x":1}
```

Generate nested documents.

```json
{
  "customer": ...,
  "orders": [...],
  "preferences": ...,
  "metadata": ...
}
```

Useful for:

* GIN indexes.
* JSON path queries.
* TOAST.
* Compression.

---

# 20. Generate Production Pathologies

Sometimes the goal is not realism but deliberately creating problems.

Examples:

## Heap bloat

Repeated updates and deletes.

## Index bloat

Frequent updates of indexed columns.

## Transaction ID pressure

Long-running transactions.

## Replication lag

Huge transactions.

## Checkpoint storms

Sustained write bursts.

## Partition explosion

Thousands of child tables.

## TOAST explosion

Large JSON payloads.

## Catalog growth

Large numbers of objects.

---

# A PostgreSQL Chaos Engineering Mindset

Perhaps the most interesting application of synthetic data generation is not benchmarking but chaos engineering for PostgreSQL.

Rather than asking:

> Can my database handle one billion rows?

Ask:

> Can it handle one billion rows with:

* 80% hot-key skew?
* heavily bloated indexes?
* multi-gigabyte TOAST tables?
* active logical replication?
* ongoing autovacuum?
* concurrent DDL?
* partition maintenance?
* long-running analytical queries?
* a checkpoint in progress?

Many production incidents arise not because any single subsystem is under stress, but because several independent mechanisms interact in unexpected ways.

A sophisticated PostgreSQL test harness should therefore aim to synthesize not merely large datasets, but realistic and adversarial operating conditions. The goal is not simply to populate tables, but to create environments that faithfully reproduce the complex dynamics of production systems and expose pathological edge cases before they occur in the wild.

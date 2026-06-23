# Generating Large Volumes of Test Data Locally in PostgreSQL

## Introduction

When generating large datasets for testing, benchmarking, or experimentation, many PostgreSQL users reach for external tools such as `pgbench` or custom scripts running from a workstation. While these approaches are useful, they incur client-server round trips and network overhead.

An alternative strategy is to generate data entirely inside PostgreSQL. In many cases, this is substantially faster because the database engine itself performs the data generation and insertion operations.

This document surveys common techniques for local data generation and discusses their strengths, weaknesses, and ideal use cases.

---

# 1. `generate_series()`: The Primary Workhorse

The single most useful tool for synthetic data generation in PostgreSQL is `generate_series()`.

A simple example:

```sql
INSERT INTO users (id, created_at, email)
SELECT
    gs,
    now() - random() * interval '365 days',
    format('user%s@example.com', gs)
FROM generate_series(1, 10000000) gs;
```

Advantages:

* Pure SQL.
* Extremely fast.
* Naturally set-based.
* Easy to combine with random functions.
* Supported by PostgreSQL's planner and executor.

For larger fact tables:

```sql
INSERT INTO orders
SELECT
    gs,
    (random() * 1000000)::int,
    now() - random() * interval '1 year',
    random() * 1000
FROM generate_series(1, 50000000) gs;
```

For most synthetic workloads, this should be considered the default approach.

---

# 2. Cross Products of `generate_series()`

Very large datasets can be produced by taking Cartesian products.

Example:

```sql
SELECT *
FROM generate_series(1,10000) a
CROSS JOIN generate_series(1,10000) b;
```

Produces:

```
10,000 × 10,000 = 100 million rows
```

Three dimensions:

```
1,000 × 1,000 × 1,000 = 1 billion rows
```

Keys can be synthesized:

```sql
SELECT
    a * 100000 + b
FROM generate_series(1,10000) a,
     generate_series(1,10000) b;
```

This approach is useful for generating extremely large datasets without requiring enormous ranges in a single series.

---

# 3. Recursive CTEs

Recursive Common Table Expressions are well suited for hierarchical data.

Example:

```sql
WITH RECURSIVE tree AS (
    SELECT 1 AS id, NULL::int AS parent
UNION ALL
    SELECT
        id + 1,
        floor(id/2)::int
    FROM tree
    WHERE id < 1000000
)
INSERT INTO nodes
SELECT * FROM tree;
```

Typical use cases:

* Organizational hierarchies.
* Tree structures.
* Dependency graphs.
* Parent-child relationships.

While not generally the fastest option, recursive CTEs excel at generating structured datasets.

---

# 4. Table Multiplication

An efficient trick for creating enormous tables is repeated self-copying.

Seed the table:

```sql
INSERT INTO t
SELECT generate_series(1,1000);
```

Then repeatedly double it:

```sql
INSERT INTO t
SELECT id + (SELECT max(id) FROM t)
FROM t;
```

Growth pattern:

```
1,000
2,000
4,000
8,000
16,000
...
```

Twenty doublings exceed one billion rows.

Advantages:

* Fast bulk operations.
* Simple implementation.
* Minimal computation.

This is particularly useful when sheer row count matters more than data diversity.

---

# 5. PL/pgSQL Loops

Procedural generation is possible:

```sql
DO $$
BEGIN
    FOR i IN 1..1000000 LOOP
        INSERT INTO t
        VALUES (
            i,
            md5(random()::text),
            now()
        );
    END LOOP;
END $$;
```

However:

**Set-based SQL should generally be preferred.**

A statement like:

```sql
INSERT ...
SELECT ...
FROM generate_series(...);
```

will almost always outperform row-by-row procedural insertion.

PL/pgSQL loops become attractive only when generating highly correlated or stateful data.

---

# 6. Stored Procedures with Transaction Control

PostgreSQL 11 introduced stored procedures with transaction control.

Example:

```sql
CREATE PROCEDURE load_data()
LANGUAGE plpgsql
AS $$
BEGIN
    FOR i IN 1..100 LOOP
        INSERT ...
        COMMIT;
    END LOOP;
END;
$$;
```

Benefits:

* Batched commits.
* Reduced transaction size.
* WAL management.
* Checkpoint management.
* Improved operational control during massive loads.

This can be preferable to one enormous transaction.

---

# Random Data Generation

Common building blocks include:

```sql
random()

md5(random()::text)

gen_random_uuid()

uuidv7()

clock_timestamp()

format()

substr()

repeat()
```

Example:

```sql
SELECT
    gen_random_uuid(),
    md5(random()::text),
    floor(random()*1000),
    now() - random()*interval '30 days';
```

More sophisticated distributions can also be implemented:

* Gaussian.
* Power-law.
* Zipfian.
* Custom statistical models.

---

# UNLOGGED Tables

If crash recovery is unnecessary:

```sql
CREATE UNLOGGED TABLE t (...);
```

Advantages:

* Reduced WAL generation.
* Faster inserts.
* Lower storage overhead.

Ideal for:

* Benchmarking.
* Temporary test datasets.
* Development environments.

---

# COPY FROM PROGRAM

PostgreSQL can stream external program output directly into tables.

Examples:

```sql
COPY t
FROM PROGRAM 'python generate.py';
```

Or:

```sql
COPY t
FROM PROGRAM 'seq 1 10000000';
```

Advantages:

* Avoids repeated INSERT statements.
* Streams data efficiently.
* Integrates external generators with PostgreSQL.

---

# CREATE TABLE AS (CTAS)

Instead of:

```sql
CREATE TABLE t (...);

INSERT INTO t
SELECT ...
```

Use:

```sql
CREATE TABLE t AS
SELECT ...
FROM generate_series(...);
```

CTAS is highly optimized and often significantly faster.

Whenever indexes and constraints can be deferred, CTAS should be strongly considered.

---

# Partition-Aware Generation

Partitioned tables deserve special attention.

Data can be generated directly into partition ranges:

```sql
INSERT INTO events
SELECT
    gs,
    date '2025-01-01'
      + (gs % 365),
    ...
FROM generate_series(1,100000000) gs;
```

Alternatively, partitions can be loaded independently:

```sql
INSERT INTO events_2025_01
SELECT ...

INSERT INTO events_2025_02
SELECT ...
```

Advantages:

* Reduced routing overhead.
* Better control over partition populations.
* Simplified benchmarking.

---

# Useful "Abusive" Tricks

Sometimes existing tables can serve as row generators.

Examples:

```sql
CREATE TABLE t AS
SELECT *
FROM pg_class
CROSS JOIN pg_attribute
CROSS JOIN generate_series(1,1000);
```

Or:

```sql
INSERT INTO t
SELECT *
FROM pgbench_accounts;
```

These techniques can rapidly bootstrap large datasets.

---

# Performance Guidelines

In general, PostgreSQL performance improves as operations become more set-based.

Approximate ordering:

```
Fastest:

CTAS
+
generate_series()
+
UNLOGGED tables

↓

INSERT ... SELECT

↓

COPY FROM PROGRAM

↓

Stored procedures with batching

↓

PL/pgSQL row-by-row loops

↓

Client-driven INSERT workloads
```

Minimizing client-server communication is often the single largest optimization.

---

# Practical Recommendations

For most local benchmarking and testing:

1. Prefer `generate_series()`.

2. Use `CREATE TABLE AS` when possible.

3. Consider `UNLOGGED` tables if durability is unnecessary.

4. Generate partitioned datasets directly into target partitions.

5. Use stored procedures for very large batched workloads.

6. Reserve PL/pgSQL loops for genuinely procedural data generation.

---

# Final Observation

One of PostgreSQL's underappreciated strengths is that SQL itself can serve as a highly expressive data generation language.

A statement such as:

```sql
CREATE UNLOGGED TABLE events AS
SELECT
    gs AS id,
    now() - random() * interval '1 year' AS ts,
    (random() * 100000)::int AS customer_id,
    md5(gs::text) AS payload
FROM generate_series(1,100000000) AS gs;
```

can synthesize one hundred million reasonably realistic rows entirely inside PostgreSQL, with no client-side generation or network overhead.

For partition testing, WAL experiments, autovacuum studies, performance benchmarking, and general development, the combination of `generate_series()`, set-based SQL, `CREATE TABLE AS`, and optional `UNLOGGED` tables is often the highest-throughput approach available using only built-in PostgreSQL facilities.

# Online Migration of a Large PostgreSQL Table to a Partitioned Table

## Background

We explored the problem of partitioning a very large PostgreSQL
`messages` table in a multi-tenant application. The table naturally has
two important dimensions:

-   `tenant_id`
-   `created_at` (or another timestamp)

The initial discussion considered composite partitioning strategies and
later evolved into the practical problem of converting an existing, very
large, unpartitioned table into a partitioned one with essentially no
downtime.

------------------------------------------------------------------------

# Part I: Partitioning Strategy

Two obvious composite schemes were considered.

## Range -\> List

    messages
    ├── month1
    │   ├── tenantA
    │   ├── tenantB
    │   └── ...
    ├── month2
    │   └── ...

Advantages:

-   Natural retention management.
-   Easy archival.
-   Efficient time-based analytics.
-   Operational lifecycle follows the partition hierarchy.

Disadvantages:

-   Tenant-specific queries may traverse multiple time partitions.

## List -\> Range

    messages
    ├── tenantA
    │   ├── month1
    │   ├── month2
    │   └── ...
    ├── tenantB
    └── ...

Advantages:

-   Excellent tenant locality.
-   Tenant-qualified queries prune aggressively.

Disadvantages:

-   Retention operations become complicated.
-   Large tenant populations can lead to operational complexity.
-   Dynamic tenant creation requires partition management.

## Initial Conclusion

Given limited information, a time-first approach was preferred:

-   RANGE(created_at)
-   optionally LIST(tenant_id)

or perhaps simply:

-   RANGE(created_at)

combined with an index such as:

    (tenant_id, created_at DESC)

The heuristic developed was:

> Partition primarily for operational lifecycle and let indexes solve
> lookup problems.

------------------------------------------------------------------------

# Part II: Online Conversion Strategies

The discussion then shifted toward converting an existing table.

Offline approaches were acknowledged but excluded because the target use
case requires continuous availability.

Several online patterns were identified.

## 1. Shadow Table

Create a new partitioned table.

Bulk copy data.

Pause writes briefly.

Synchronize the delta.

Rename tables.

## 2. Trigger-Based Dual Writes

Maintain old and new structures simultaneously.

Triggers replicate INSERT/UPDATE/DELETE activity.

Backfill historical data.

Eventually cut over.

Pros:

-   Near-zero downtime.

Cons:

-   Trigger complexity.
-   Additional write overhead.

## 3. Logical Replication

Use PostgreSQL logical replication to synchronize old and new
structures.

Pros:

-   Cleaner than triggers.

Cons:

-   Replica identity requirements.
-   Operational complexity.

## 4. Application-Level Dual Writes

The application writes to both structures until migration completes.

Common in very large systems but requires application changes.

------------------------------------------------------------------------

# Part III: Default Partition Migration

A different idea was proposed.

Rather than maintaining two copies of the data, create a partitioned
parent and arrange for the existing table to become the DEFAULT
partition.

Conceptually:

    partitioned_messages
    └── existing_table (DEFAULT)

Initially:

-   No data moves.
-   Existing rows remain in place.

Future:

-   Create proper partitions.
-   New writes automatically route correctly.
-   Historical data gradually migrates from DEFAULT into proper
    partitions.

Eventually:

-   DEFAULT becomes empty.
-   DEFAULT is removed.

This pattern was recognized as distinct from traditional shadow-copy
methods.

Key advantages:

-   Single authoritative copy of each row.
-   No trigger synchronization.
-   No replication lag.
-   Migration proceeds incrementally.

------------------------------------------------------------------------

# Part IV: Practical PostgreSQL Considerations

Several implementation details were discussed.

## DDL Gymnastics

The approach assumes careful table renaming and attachment operations.

The exact choreography must preserve application transparency.

## Partition Attachment

Partition constraints matter.

PostgreSQL validates attached partitions unless matching CHECK
constraints already prove correctness.

Planning these constraints carefully can reduce locking and validation
cost.

## Hot Data Benefits First

Because future inserts immediately land in proper partitions, the
hottest portion of the workload benefits almost immediately.

Historical data can migrate later.

------------------------------------------------------------------------

# Part V: Backfill Strategy

Attention turned toward backfilling data from DEFAULT into proper
partitions.

A crucial observation emerged:

PostgreSQL has no metadata-only row move.

Migration necessarily involves:

-   INSERT
-   DELETE

or equivalent operations.

Deleting rows creates dead tuples.

------------------------------------------------------------------------

# Part VI: Bloat and Vacuum

A major concern is heap and index bloat.

Deleting migrated rows leaves dead tuples behind.

VACUUM:

-   reclaims space for reuse,
-   does not immediately shrink the table,
-   does not necessarily compact indexes.

Therefore:

Large bulk deletes are undesirable.

## Microbatching

Preferred approach:

-   small transactions,
-   limited WAL generation,
-   manageable replication impact,
-   reduced lock durations,
-   sustainable autovacuum behavior.

Examples might involve moving thousands rather than millions of rows per
batch.

## Time-Oriented Drain

Rather than arbitrary batches, contiguous time ranges are attractive.

For example:

-   create recent partition,
-   migrate recent data,
-   continue progressively backward through history.

This concentrates effort where partition pruning provides the greatest
benefit.

------------------------------------------------------------------------

# Part VII: Autovacuum Strategy

The migration should be viewed as a controlled maintenance workload.

Custom storage parameters may be appropriate for the DEFAULT partition.

Potential tuning targets:

-   autovacuum_vacuum_scale_factor
-   autovacuum_analyze_scale_factor
-   vacuum thresholds
-   cost limits

The objective is not eliminating dead tuples.

The objective is keeping cleanup capacity ahead of dead tuple
production.

------------------------------------------------------------------------

# Part VIII: Index Bloat

Heap bloat is only part of the story.

Large delete operations also affect indexes.

VACUUM removes dead entries but may not compact structures.

Long-running migrations may eventually justify:

    REINDEX CONCURRENTLY

for heavily modified indexes.

------------------------------------------------------------------------

# Part IX: Observability

One particularly attractive aspect of the DEFAULT-partition strategy is
that the migration naturally exposes progress metrics.

Potential metrics:

-   rows remaining in DEFAULT,
-   bytes remaining,
-   oldest timestamp remaining,
-   dead tuples,
-   autovacuum activity,
-   index bloat,
-   WAL generation,
-   replication lag.

The migration process becomes controllable.

If:

-   replication falls behind,
-   autovacuum cannot keep pace,
-   production load spikes,

the migration can simply slow down or pause.

------------------------------------------------------------------------

# Final Engineering Conclusion

A key conclusion emerged.

Traditional online migrations typically solve a synchronization problem.

The DEFAULT-partition approach instead uses PostgreSQL's own
partitioning machinery as the migration mechanism.

For append-heavy workloads such as:

-   messages,
-   events,
-   logs,
-   telemetry,

this is particularly elegant.

The most important storage insight was:

> The goal is not to avoid generating dead tuples.

Instead:

> Pace the migration so that dead tuple production remains below the
> system's sustainable cleanup capacity.

Under that model, the migration becomes another long-running,
well-behaved background maintenance process rather than a disruptive,
high-risk data movement event.

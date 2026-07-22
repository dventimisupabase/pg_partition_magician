#!/usr/bin/env python3
"""Verify pq.to_parquet_range() against two independent Parquet readers.

Companion to verify.py, for the cross-partition range-query variant (the first rung of
the chunked, cross-partition Parquet archival design: archive-chunked-parquet-design.md).
Same verification shape as verify.py (pyarrow + DuckDB agreeing on value equality, not just
"it opened"), but every table here is a real range-PARTITIONED parent with several children,
because the property under test -- ordering by (control column, real key) instead of ctid --
only matters once ctid stops being a valid tiebreak (it is not comparable across more than
one child's heap).

Usage:
  ./.venv/bin/python verify_range.py [dsn]

Defaults to the docker-compose pg17 service (localhost:5517).
"""
import datetime
import os
import sys
import tempfile

import duckdb
import psycopg2
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
DSN = sys.argv[1] if len(sys.argv) > 1 else "postgresql://postgres:postgres@localhost:5517/postgres"

FAILURES = []


def run(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        if cur.description is not None:
            return cur.fetchall()
        return None


def to_parquet_range_bytes(conn, parent, control, lo, hi):
    rows = run(conn, "select pq.to_parquet_range(%s::regclass, %s, %s, %s)", (parent, control, lo, hi))
    return bytes(rows[0][0])


def read_with_both_readers(raw):
    with tempfile.NamedTemporaryFile(suffix=".parquet", delete=False) as f:
        f.write(raw)
        path = f.name
    try:
        arrow_rows = pq.read_table(path).to_pylist()
        rel = duckdb.sql(f"select * from '{path}'")
        cols = [d[0] for d in rel.description]
        duck_rows = [dict(zip(cols, row)) for row in rel.fetchall()]
        return arrow_rows, duck_rows
    finally:
        os.unlink(path)


def _norm(v):
    # DuckDB's Parquet reader returns a naive datetime for a TIMESTAMP_MICROS column (no
    # timezone concept in the Parquet type itself); psycopg2 and pyarrow both give back a
    # tz-aware one for what postgres sent as timestamptz. Same value, so treat a naive
    # datetime as UTC before comparing rather than failing on a tzinfo difference (see
    # verify.py's test_timestamptz, which hits the identical divergence).
    if isinstance(v, datetime.datetime) and v.tzinfo is None:
        return v.replace(tzinfo=datetime.timezone.utc)
    return v


def check(name, expected, arrow_rows, duck_rows):
    ok = True
    if len(arrow_rows) != len(expected):
        FAILURES.append(f"{name}: pyarrow row count {len(arrow_rows)} != expected {len(expected)}")
        ok = False
    if len(duck_rows) != len(expected):
        FAILURES.append(f"{name}: duckdb row count {len(duck_rows)} != expected {len(expected)}")
        ok = False
    for i, exp in enumerate(expected):
        if i >= len(arrow_rows) or i >= len(duck_rows):
            break
        a = arrow_rows[i]
        d = duck_rows[i]
        for col, val in exp.items():
            av = _norm(a.get(col))
            dv = _norm(d.get(col))
            val = _norm(val)
            if av != val:
                FAILURES.append(f"{name}: row {i} col {col}: pyarrow={av!r} expected={val!r}")
                ok = False
            if dv != val:
                FAILURES.append(f"{name}: row {i} col {col}: duckdb={dv!r} expected={val!r}")
                ok = False
    print(f"{'PASS' if ok else 'FAIL'}: {name} ({len(expected)} rows)")
    return ok


def expected_rows(conn, parent, control, lo, hi, order_cols, select_cols):
    rows = run(
        conn,
        f"select {', '.join(select_cols)} from {parent} "
        f"where {control} >= %s and {control} < %s order by {', '.join(order_cols)}",
        (lo, hi),
    )
    return [dict(zip(select_cols, r)) for r in rows]


# ---------------------------------------------------------------------------
# Fixture: a range-partitioned events table, PK (ts, id) -- Postgres itself requires any
# unique constraint on a partitioned table to include the partitioning column, so ts is
# always part of the key here; id is the genuine tiebreaker among rows sharing a ts.
# ---------------------------------------------------------------------------

def make_events_fixture(conn):
    run(conn, "drop table if exists t_range_events")
    run(
        conn,
        """
        create table t_range_events (
          id  int4 not null,
          ts  timestamptz not null,
          val text not null,
          primary key (ts, id)
        ) partition by range (ts)
        """,
    )
    run(conn, "create table t_range_events_p1 partition of t_range_events "
              "for values from ('2026-01-01') to ('2026-02-01')")
    run(conn, "create table t_range_events_p2 partition of t_range_events "
              "for values from ('2026-02-01') to ('2026-03-01')")
    run(conn, "create table t_range_events_p3 partition of t_range_events "
              "for values from ('2026-03-01') to ('2026-04-01')")
    rows = [
        (1, "2026-01-05 00:00:00+00", "a"),
        (2, "2026-01-15 00:00:00+00", "b"),
        # five rows tied on the same ts, inserted with ids scrambled so insertion order
        # cannot be mistaken for the correct output order -- only "order by ts, id" is.
        (12, "2026-01-20 12:00:00+00", "tie-e"),
        (10, "2026-01-20 12:00:00+00", "tie-c"),
        (11, "2026-01-20 12:00:00+00", "tie-d"),
        (8, "2026-01-20 12:00:00+00", "tie-a"),
        (9, "2026-01-20 12:00:00+00", "tie-b"),
        (3, "2026-01-31 23:59:59+00", "c"),
        # exact partition boundary: this row belongs to p2, not p1.
        (4, "2026-02-01 00:00:00+00", "boundary-p2"),
        (5, "2026-02-10 00:00:00+00", "d"),
        (6, "2026-02-15 00:00:00+00", "e"),
        (7, "2026-03-15 00:00:00+00", "f"),
    ]
    for r in rows:
        run(conn, "insert into t_range_events (id, ts, val) values (%s, %s, %s)", r)
    conn.commit()


def test_range_two_children(conn):
    make_events_fixture(conn)
    raw = to_parquet_range_bytes(conn, "t_range_events", "ts", "2026-01-01", "2026-03-01")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = expected_rows(conn, "t_range_events", "ts", "2026-01-01", "2026-03-01",
                              ["ts", "id"], ["id", "ts", "val"])
    check("range spans p1+p2 (two children)", expected, arrow_rows, duck_rows)


def test_range_three_children(conn):
    make_events_fixture(conn)
    raw = to_parquet_range_bytes(conn, "t_range_events", "ts", "2026-01-01", "2026-04-01")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = expected_rows(conn, "t_range_events", "ts", "2026-01-01", "2026-04-01",
                              ["ts", "id"], ["id", "ts", "val"])
    check("range spans p1+p2+p3 (three children)", expected, arrow_rows, duck_rows)


def test_range_partial_single_partition(conn):
    make_events_fixture(conn)
    raw = to_parquet_range_bytes(conn, "t_range_events", "ts", "2026-02-05", "2026-02-20")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = expected_rows(conn, "t_range_events", "ts", "2026-02-05", "2026-02-20",
                              ["ts", "id"], ["id", "ts", "val"])
    check("sub-range entirely inside one child (p2)", expected, arrow_rows, duck_rows)


def test_range_nonunique_control_tiebreak(conn):
    make_events_fixture(conn)
    raw = to_parquet_range_bytes(conn, "t_range_events", "ts", "2026-01-20 12:00:00+00", "2026-01-20 12:00:01+00")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = expected_rows(conn, "t_range_events", "ts", "2026-01-20 12:00:00+00", "2026-01-20 12:00:01+00",
                              ["ts", "id"], ["id", "ts", "val"])
    ok = check("5 rows tied on ts, ordered by (ts, id) not insertion order", expected, arrow_rows, duck_rows)
    if ok:
        ids = [r["id"] for r in arrow_rows]
        if ids != sorted(ids):
            FAILURES.append(f"tiebreak ordering: pyarrow ids {ids} not sorted by id")
            print("FAIL: tiebreak ordering strictly by id among ties")
        else:
            print("PASS: tiebreak ordering strictly by id among ties")


def test_range_exclusive_hi_boundary(conn):
    make_events_fixture(conn)
    # id=3 sits at 2026-01-31 23:59:59+00 (included, < hi); id=4 sits exactly at
    # hi=2026-02-01 00:00:00+00 (excluded: half-open [lo, hi)), and also happens to be the
    # row that crosses the p1/p2 partition boundary -- so this simultaneously checks the
    # exclusive-hi contract and that a partition boundary is not mistaken for a data boundary.
    raw = to_parquet_range_bytes(conn, "t_range_events", "ts", "2026-01-25", "2026-02-01")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = expected_rows(conn, "t_range_events", "ts", "2026-01-25", "2026-02-01",
                              ["ts", "id"], ["id", "ts", "val"])
    ok = check("exclusive hi at exact partition+data boundary", expected, arrow_rows, duck_rows)
    ids = [r["id"] for r in arrow_rows]
    if ok and (3 not in ids or 4 in ids):
        FAILURES.append(f"exclusive hi: expected id 3 included and id 4 excluded, got ids {ids}")
        print("FAIL: exclusive hi boundary correctness")
    elif ok:
        print("PASS: exclusive hi boundary correctness (id 3 in, id 4 out)")


def test_range_empty_result(conn):
    make_events_fixture(conn)
    raw = to_parquet_range_bytes(conn, "t_range_events", "ts", "2026-05-01", "2026-06-01")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = expected_rows(conn, "t_range_events", "ts", "2026-05-01", "2026-06-01",
                              ["ts", "id"], ["id", "ts", "val"])
    check("empty range (0 rows), still a valid Parquet file", expected, arrow_rows, duck_rows)


def test_range_composite_key_two_cols(conn):
    # A wider composite key than the (ts, id) fixture: (ts, region, id), tiebreak needs to
    # walk all key columns in index order, not just the first.
    run(conn, "drop table if exists t_range_composite")
    run(
        conn,
        """
        create table t_range_composite (
          region text not null,
          id     int4 not null,
          ts     timestamptz not null,
          amount float8 not null,
          primary key (ts, region, id)
        ) partition by range (ts)
        """,
    )
    run(conn, "create table t_range_composite_p1 partition of t_range_composite "
              "for values from ('2026-01-01') to ('2026-02-01')")
    run(conn, "create table t_range_composite_p2 partition of t_range_composite "
              "for values from ('2026-02-01') to ('2026-03-01')")
    rows = [
        ("us", 5, "2026-01-10 00:00:00+00", 1.0),
        ("eu", 2, "2026-01-10 00:00:00+00", 2.0),
        ("us", 1, "2026-01-10 00:00:00+00", 3.0),
        ("eu", 9, "2026-01-10 00:00:00+00", 4.0),
        ("ap", 3, "2026-02-15 00:00:00+00", 5.0),
    ]
    for r in rows:
        run(conn, "insert into t_range_composite (region, id, ts, amount) values (%s, %s, %s, %s)", r)
    conn.commit()
    raw = to_parquet_range_bytes(conn, "t_range_composite", "ts", "2026-01-01", "2026-03-01")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = expected_rows(conn, "t_range_composite", "ts", "2026-01-01", "2026-03-01",
                              ["ts", "region", "id"], ["region", "id", "ts", "amount"])
    check("three-column composite key (ts, region, id)", expected, arrow_rows, duck_rows)


def test_range_unique_constraint_fallback(conn):
    # No PRIMARY KEY, but a real UNIQUE CONSTRAINT -- pq._key_columns must fall back to it,
    # mirroring pgpm.regrain_step's v_keyidx preference order (PK, else a constraint-backed
    # unique index).
    run(conn, "drop table if exists t_range_unique_constraint")
    run(
        conn,
        """
        create table t_range_unique_constraint (
          id int4 not null,
          ts timestamptz not null,
          val text not null,
          constraint t_range_unique_constraint_uq unique (ts, id)
        ) partition by range (ts)
        """,
    )
    run(conn, "create table t_range_unique_constraint_p1 partition of t_range_unique_constraint "
              "for values from ('2026-01-01') to ('2026-02-01')")
    run(conn, "create table t_range_unique_constraint_p2 partition of t_range_unique_constraint "
              "for values from ('2026-02-01') to ('2026-03-01')")
    for r in [(2, "2026-01-10 00:00:00+00", "a"), (1, "2026-01-10 00:00:00+00", "b"),
              (3, "2026-02-05 00:00:00+00", "c")]:
        run(conn, "insert into t_range_unique_constraint (id, ts, val) values (%s, %s, %s)", r)
    conn.commit()
    raw = to_parquet_range_bytes(conn, "t_range_unique_constraint", "ts", "2026-01-01", "2026-03-01")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = expected_rows(conn, "t_range_unique_constraint", "ts", "2026-01-01", "2026-03-01",
                              ["ts", "id"], ["id", "ts", "val"])
    check("UNIQUE CONSTRAINT fallback (no primary key)", expected, arrow_rows, duck_rows)


def test_range_bare_unique_index_refused(conn):
    # A bare `create unique index`, never promoted to a constraint, must NOT be picked up --
    # pg_constraint has no row for it, exactly like pgpm.regrain_step's own discovery query.
    run(conn, "drop table if exists t_range_bare_index")
    run(
        conn,
        """
        create table t_range_bare_index (
          id int4 not null,
          ts timestamptz not null,
          val text not null
        ) partition by range (ts)
        """,
    )
    run(conn, "create table t_range_bare_index_p1 partition of t_range_bare_index "
              "for values from ('2026-01-01') to ('2026-02-01')")
    run(conn, "create unique index t_range_bare_index_uq_idx on t_range_bare_index (ts, id)")
    run(conn, "insert into t_range_bare_index (id, ts, val) values (1, '2026-01-10', 'a')")
    conn.commit()
    try:
        to_parquet_range_bytes(conn, "t_range_bare_index", "ts", "2026-01-01", "2026-02-01")
        FAILURES.append("bare unique index: expected refusal, got a result")
        print("FAIL: bare unique index (unbacked by a constraint) correctly refused")
    except psycopg2.Error as e:
        conn.rollback()
        if "no primary key or predicate/expression-free unique constraint" in str(e):
            print("PASS: bare unique index (unbacked by a constraint) correctly refused")
        else:
            FAILURES.append(f"bare unique index: wrong error: {e}")
            print("FAIL: bare unique index (unbacked by a constraint) correctly refused")


def test_range_keyless_refused(conn):
    run(conn, "drop table if exists t_range_keyless")
    run(
        conn,
        """
        create table t_range_keyless (
          ts  timestamptz not null,
          val text not null
        ) partition by range (ts)
        """,
    )
    run(conn, "create table t_range_keyless_p1 partition of t_range_keyless "
              "for values from ('2026-01-01') to ('2026-02-01')")
    run(conn, "insert into t_range_keyless (ts, val) values ('2026-01-10', 'a')")
    conn.commit()
    try:
        to_parquet_range_bytes(conn, "t_range_keyless", "ts", "2026-01-01", "2026-02-01")
        FAILURES.append("keyless table: expected refusal, got a result")
        print("FAIL: genuinely keyless table correctly refused")
    except psycopg2.Error as e:
        conn.rollback()
        if "no primary key or predicate/expression-free unique constraint" in str(e):
            print("PASS: genuinely keyless table correctly refused")
        else:
            FAILURES.append(f"keyless table: wrong error: {e}")
            print("FAIL: genuinely keyless table correctly refused")


def test_range_pruning_skips_untouched_partition(conn):
    # Not a correctness assertion on rows (covered above) -- confirms the design's claim that
    # this "relies on Postgres's own partition pruning" is actually true, not just assumed:
    # a range confined to p1 should never touch p2/p3 in the plan.
    make_events_fixture(conn)
    plan = run(conn, "explain (format text) select * from t_range_events "
                      "where ts >= '2026-01-01' and ts < '2026-02-01'")
    plan_text = "\n".join(row[0] for row in plan)
    ok = "t_range_events_p1" in plan_text and "t_range_events_p2" not in plan_text and "t_range_events_p3" not in plan_text
    print(f"{'PASS' if ok else 'FAIL'}: partition pruning confirmed via EXPLAIN (p2/p3 excluded)")
    if not ok:
        FAILURES.append(f"partition pruning: unexpected plan:\n{plan_text}")


def main():
    conn = psycopg2.connect(DSN)
    conn.autocommit = False
    run(conn, open(os.path.join(HERE, "parquet_writer.sql")).read())
    conn.commit()

    tests = [
        test_range_two_children,
        test_range_three_children,
        test_range_partial_single_partition,
        test_range_nonunique_control_tiebreak,
        test_range_exclusive_hi_boundary,
        test_range_empty_result,
        test_range_composite_key_two_cols,
        test_range_unique_constraint_fallback,
        test_range_bare_unique_index_refused,
        test_range_keyless_refused,
        test_range_pruning_skips_untouched_partition,
    ]
    for t in tests:
        try:
            t(conn)
        except Exception as e:
            FAILURES.append(f"{t.__name__}: raised {type(e).__name__}: {e}")
            print(f"FAIL: {t.__name__} raised {type(e).__name__}: {e}")
            conn.rollback()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All tests passed.")


if __name__ == "__main__":
    main()

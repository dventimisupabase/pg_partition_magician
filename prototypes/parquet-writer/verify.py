#!/usr/bin/env python3
"""Verify pq.to_parquet() output against two independent Parquet readers.

Not testing "in Postgres": pq.to_parquet() only has to produce bytes; every
assertion here runs outside the database, against pyarrow (Arrow's C++ reader)
and DuckDB (its own from-scratch reader). Agreement between two independent
implementations is the point, not just "it opened".

Usage:
  ./.venv/bin/python verify.py [dsn]

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


def to_parquet_bytes(conn, table):
    rows = run(conn, f"select pq.to_parquet('{table}'::regclass)")
    return bytes(rows[0][0])


def read_with_both_readers(raw):
    with tempfile.NamedTemporaryFile(suffix=".parquet", delete=False) as f:
        f.write(raw)
        path = f.name
    try:
        arrow_rows = pq.read_table(path).to_pylist()
        duck_rows = duckdb.sql(f"select * from '{path}'").fetchdf().to_dict("records")
        return arrow_rows, duck_rows
    finally:
        os.unlink(path)


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
            av = a.get(col)
            dv = d.get(col)
            if av != val:
                FAILURES.append(f"{name}: row {i} col {col}: pyarrow={av!r} expected={val!r}")
                ok = False
            if dv != val:
                FAILURES.append(f"{name}: row {i} col {col}: duckdb={dv!r} expected={val!r}")
                ok = False
    print(f"{'PASS' if ok else 'FAIL'}: {name} ({len(expected)} rows)")
    return ok


def fetch_expected(conn, table, cols):
    rows = run(conn, f"select {', '.join(cols)} from {table} order by ctid")
    return [dict(zip(cols, r)) for r in rows]


def make_table(conn, name, ddl, rows_sql):
    run(conn, f"drop table if exists {name}")
    run(conn, f"create table {name} ({ddl})")
    if rows_sql:
        run(conn, f"insert into {name} values {rows_sql}")
    conn.commit()


def test_int32_basic(conn):
    make_table(conn, "t_int32", "n int4 not null",
               "(0), (1), (-1), (2147483647), (-2147483648), (42)")
    raw = to_parquet_bytes(conn, "t_int32")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_int32", ["n"])
    check("int32 basic + boundaries", expected, arrow_rows, duck_rows)


def test_int64_boundaries(conn):
    make_table(conn, "t_int64", "n int8 not null",
               "(0), (1), (-1), (9223372036854775807), (-9223372036854775808)")
    raw = to_parquet_bytes(conn, "t_int64")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_int64", ["n"])
    check("int64 boundaries", expected, arrow_rows, duck_rows)


def test_float8(conn):
    make_table(conn, "t_f8", "x float8 not null",
               "(0.0), (1.5), (-1.5), ('Infinity'), ('-Infinity'), (3.14159265358979)")
    raw = to_parquet_bytes(conn, "t_f8")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_f8", ["x"])
    check("float8 incl infinities", expected, arrow_rows, duck_rows)


def test_bool(conn):
    make_table(conn, "t_bool", "b boolean not null",
               "(true), (false), (true), (true), (false), (false), (true), (false), (true)")
    raw = to_parquet_bytes(conn, "t_bool")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_bool", ["b"])
    check("bool bit-packing across a byte boundary (9 rows)", expected, arrow_rows, duck_rows)


def test_text(conn):
    make_table(conn, "t_text", "s text not null", None)
    run(conn, "insert into t_text (s) values (%s)", ("",))
    run(conn, "insert into t_text (s) values (%s)", ("hello",))
    run(conn, "insert into t_text (s) values (%s)", ("unicode: héllo wörld 日本語 😀",))
    run(conn, "insert into t_text (s) values (%s)", ("a" * 500,))
    conn.commit()
    raw = to_parquet_bytes(conn, "t_text")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_text", ["s"])
    check("text: empty/unicode/long", expected, arrow_rows, duck_rows)


def test_timestamptz(conn):
    make_table(conn, "t_ts", "ts timestamptz not null", None)
    for v in [
        "1970-01-01 00:00:00+00",
        "2026-07-21 12:34:56.789123+00",
        "1999-12-31 23:59:59+00",
        "2000-01-01 00:00:00+00",
        "1900-01-01 00:00:00+00",
    ]:
        run(conn, "insert into t_ts (ts) values (%s)", (v,))
    conn.commit()
    raw = to_parquet_bytes(conn, "t_ts")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected_raw = run(conn, "select ts from t_ts order by ctid")
    expected = [{"ts": r[0]} for r in expected_raw]
    ok = True
    for i, exp in enumerate(expected):
        exp_ts = exp["ts"]
        a_ts = arrow_rows[i]["ts"]
        d_ts = duck_rows[i]["ts"]
        if not isinstance(a_ts, datetime.datetime):
            FAILURES.append(f"timestamptz: row {i} pyarrow type {type(a_ts)}")
            ok = False
            continue
        a_ts_utc = a_ts.replace(tzinfo=datetime.timezone.utc) if a_ts.tzinfo is None else a_ts
        exp_utc = exp_ts.astimezone(datetime.timezone.utc)
        if a_ts_utc != exp_utc:
            FAILURES.append(f"timestamptz: row {i} pyarrow={a_ts_utc} expected={exp_utc}")
            ok = False
        d_ts_utc = d_ts if d_ts.tzinfo else d_ts.replace(tzinfo=datetime.timezone.utc)
        if d_ts_utc != exp_utc:
            FAILURES.append(f"timestamptz: row {i} duckdb={d_ts_utc} expected={exp_utc}")
            ok = False
    print(f"{'PASS' if ok else 'FAIL'}: timestamptz epoch conversion ({len(expected)} rows)")


def test_multi_column(conn):
    make_table(conn, "t_multi",
               "id int4 not null, amount float8 not null, active boolean not null, label text not null",
               None)
    run(conn, "insert into t_multi (id, amount, active, label) values "
              "(1, 10.5, true, 'alpha'), (2, -3.25, false, 'beta'), (3, 0, true, '')")
    conn.commit()
    raw = to_parquet_bytes(conn, "t_multi")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_multi", ["id", "amount", "active", "label"])
    check("multi-column mixed types", expected, arrow_rows, duck_rows)


def test_empty_table(conn):
    make_table(conn, "t_empty", "n int4 not null", None)
    raw = to_parquet_bytes(conn, "t_empty")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_empty", ["n"])
    check("empty table (0 rows)", expected, arrow_rows, duck_rows)


def test_single_row(conn):
    make_table(conn, "t_single", "n int4 not null", "(7)")
    raw = to_parquet_bytes(conn, "t_single")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_single", ["n"])
    check("single row", expected, arrow_rows, duck_rows)


def test_many_columns_long_form_header(conn):
    # Exercises the Thrift compact-protocol "long form" field header path
    # (field-id delta > 15), which none of the other tests trigger: 20
    # columns pushes ColumnMetaData/RowGroup field-id deltas past 15 well
    # before that, but the real trigger here is num_children on the schema
    # root and the width of path_in_schema/encodings lists (>14 forces the
    # long-form LIST header too).
    cols = [f"c{i} int4 not null" for i in range(20)]
    make_table(conn, "t_wide", ", ".join(cols), None)
    vals = ", ".join(str(i) for i in range(20))
    run(conn, f"insert into t_wide values ({vals})")
    conn.commit()
    raw = to_parquet_bytes(conn, "t_wide")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_wide", [f"c{i}" for i in range(20)])
    check("20 columns (long-form list header path)", expected, arrow_rows, duck_rows)


def test_quoted_identifiers(conn):
    run(conn, 'drop table if exists "Mixed_Case"')
    run(conn, 'create table "Mixed_Case" ("Group" int4 not null, "order" text not null)')
    run(conn, 'insert into "Mixed_Case" ("Group", "order") values (%s, %s)', (1, "a"))
    run(conn, 'insert into "Mixed_Case" ("Group", "order") values (%s, %s)', (2, "b"))
    conn.commit()
    raw = to_parquet_bytes(conn, '"Mixed_Case"')
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected_raw = run(conn, 'select "Group", "order" from "Mixed_Case" order by ctid')
    expected = [{"Group": r[0], "order": r[1]} for r in expected_raw]
    check("quoted mixed-case / reserved-word identifiers", expected, arrow_rows, duck_rows)


def test_large_row_count(conn):
    # 500 rows forces num_values / page-size fields in the footer metadata
    # past the 1-byte varint boundary (zigzag(n) > 127 once n > 63) -- nothing
    # above this exercises that path since every other test stays under 64 rows.
    make_table(conn, "t_large", "n int4 not null", None)
    run(conn, "insert into t_large select g from generate_series(-250, 249) g")
    conn.commit()
    raw = to_parquet_bytes(conn, "t_large")
    arrow_rows, duck_rows = read_with_both_readers(raw)
    expected = fetch_expected(conn, "t_large", ["n"])
    check("500 rows (multi-byte varint metadata fields)", expected, arrow_rows, duck_rows)


def test_nullable_column_refused(conn):
    make_table(conn, "t_nullable", "n int4", None)
    try:
        to_parquet_bytes(conn, "t_nullable")
        FAILURES.append("nullable column: expected an exception, got none")
        print("FAIL: nullable column correctly refused")
    except psycopg2.Error as e:
        conn.rollback()
        if "NOT NULL" in str(e) or "nullable" in str(e):
            print("PASS: nullable column correctly refused")
        else:
            FAILURES.append(f"nullable column: wrong error: {e}")
            print("FAIL: nullable column correctly refused")


def main():
    conn = psycopg2.connect(DSN)
    conn.autocommit = False
    run(conn, open(os.path.join(HERE, "parquet_writer.sql")).read())
    conn.commit()

    tests = [
        test_int32_basic,
        test_int64_boundaries,
        test_float8,
        test_bool,
        test_text,
        test_timestamptz,
        test_multi_column,
        test_empty_table,
        test_single_row,
        test_many_columns_long_form_header,
        test_quoted_identifiers,
        test_large_row_count,
        test_nullable_column_refused,
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

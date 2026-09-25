-- archive._pq_plain_decimal's byte loop (issue #461).
--
-- Parquet DECIMAL is the unscaled integer as big-endian two's complement in a fixed byte width, and
-- the encoder walks that integer a byte at a time from the least significant end. It used to step
-- with `trunc(v_unsigned / 256)`. PostgreSQL's numeric `/` is not exact: it picks a result scale of
-- roughly 16 significant digits minus the integer digits and ROUNDS to it, so once the running
-- quotient has 17 or more integer digits it is rounded to an integer before trunc() sees it, and the
-- carry lands in every higher byte. Every negative value at width 8 or more gets there through the
-- `2^(8n) + value` two's-complement step (2^64 has 20 digits), and positives get there from 19
-- digits. numeric(17,s) is the narrowest column shape with an 8-byte width, so numeric(19,4), the
-- money shape, is inside it: -1.5 read back as 5.0536 and -0.0001 as 0.0255 from both pyarrow and
-- DuckDB. div()/mod() are exact at any magnitude, which is what pgpm._radix_encode already uses for
-- the same reason.
--
-- The reference bytes below were derived OUTSIDE PostgreSQL, so nothing here shares an operator with
-- the code under test:
--
--   for v in (-1, -12345, -15000, 9999999999999999999, -9999999999999999999):
--     for w in range(1, 17):
--       try: print(v, w, v.to_bytes(w, 'big', signed=True).hex())
--       except OverflowError: pass    # v does not fit in w bytes: no row, nothing to assert
--
-- Each negative below is paired with its witness. The first assertion shows the rounding is present
-- in this server at exactly the magnitude the encoder reaches at width 8 (so "the bytes are right"
-- is not "the hazard went away"), and the reference table is required to carry -1 at width 8, the
-- smallest width the old loop got wrong: widths 1..7 passed before the fix and would pass again
-- against it.
select plan(72);

-- ---------------------------------------------------------------------------
-- Witnesses: the hazard, and the column shapes that reach it
-- ---------------------------------------------------------------------------

select ok(
  trunc((2::numeric ^ 64 - 1) / 256) = 2::numeric ^ 56,
  'witness: numeric / rounds (2^64 - 1) / 256 up to 2^56 before trunc() runs, so a byte loop stepping with it cannot be exact at width 8');

select is(archive._pq_decimal_byte_width(16), 7,
  'numeric(16,s) encodes in 7 bytes, the widest width whose two''s complement step stays under 17 digits');

select is(archive._pq_decimal_byte_width(17), 8,
  'numeric(17,s) encodes in 8 bytes, the narrowest column shape whose two''s complement step reaches 2^64');

select is(archive._pq_decimal_byte_width(19), 9,
  'numeric(19,s), the money shape, encodes in 9 bytes');

create temp table ref461 (v numeric not null, w int4 not null, hex text not null, primary key (v, w));
insert into ref461 (v, w, hex) values
  (-1,  1, 'ff'),
  (-1,  2, 'ffff'),
  (-1,  3, 'ffffff'),
  (-1,  4, 'ffffffff'),
  (-1,  5, 'ffffffffff'),
  (-1,  6, 'ffffffffffff'),
  (-1,  7, 'ffffffffffffff'),
  (-1,  8, 'ffffffffffffffff'),
  (-1,  9, 'ffffffffffffffffff'),
  (-1, 10, 'ffffffffffffffffffff'),
  (-1, 11, 'ffffffffffffffffffffff'),
  (-1, 12, 'ffffffffffffffffffffffff'),
  (-1, 13, 'ffffffffffffffffffffffffff'),
  (-1, 14, 'ffffffffffffffffffffffffffff'),
  (-1, 15, 'ffffffffffffffffffffffffffffff'),
  (-1, 16, 'ffffffffffffffffffffffffffffffff'),
  (-12345,  2, 'cfc7'),
  (-12345,  3, 'ffcfc7'),
  (-12345,  4, 'ffffcfc7'),
  (-12345,  5, 'ffffffcfc7'),
  (-12345,  6, 'ffffffffcfc7'),
  (-12345,  7, 'ffffffffffcfc7'),
  (-12345,  8, 'ffffffffffffcfc7'),
  (-12345,  9, 'ffffffffffffffcfc7'),
  (-12345, 10, 'ffffffffffffffffcfc7'),
  (-12345, 11, 'ffffffffffffffffffcfc7'),
  (-12345, 12, 'ffffffffffffffffffffcfc7'),
  (-12345, 13, 'ffffffffffffffffffffffcfc7'),
  (-12345, 14, 'ffffffffffffffffffffffffcfc7'),
  (-12345, 15, 'ffffffffffffffffffffffffffcfc7'),
  (-12345, 16, 'ffffffffffffffffffffffffffffcfc7'),
  (-15000,  2, 'c568'),
  (-15000,  3, 'ffc568'),
  (-15000,  4, 'ffffc568'),
  (-15000,  5, 'ffffffc568'),
  (-15000,  6, 'ffffffffc568'),
  (-15000,  7, 'ffffffffffc568'),
  (-15000,  8, 'ffffffffffffc568'),
  (-15000,  9, 'ffffffffffffffc568'),
  (-15000, 10, 'ffffffffffffffffc568'),
  (-15000, 11, 'ffffffffffffffffffc568'),
  (-15000, 12, 'ffffffffffffffffffffc568'),
  (-15000, 13, 'ffffffffffffffffffffffc568'),
  (-15000, 14, 'ffffffffffffffffffffffffc568'),
  (-15000, 15, 'ffffffffffffffffffffffffffc568'),
  (-15000, 16, 'ffffffffffffffffffffffffffffc568'),
  (9999999999999999999,  9, '008ac7230489e7ffff'),
  (9999999999999999999, 10, '00008ac7230489e7ffff'),
  (9999999999999999999, 11, '0000008ac7230489e7ffff'),
  (9999999999999999999, 12, '000000008ac7230489e7ffff'),
  (9999999999999999999, 13, '00000000008ac7230489e7ffff'),
  (9999999999999999999, 14, '0000000000008ac7230489e7ffff'),
  (9999999999999999999, 15, '000000000000008ac7230489e7ffff'),
  (9999999999999999999, 16, '00000000000000008ac7230489e7ffff'),
  (-9999999999999999999,  9, 'ff7538dcfb76180001'),
  (-9999999999999999999, 10, 'ffff7538dcfb76180001'),
  (-9999999999999999999, 11, 'ffffff7538dcfb76180001'),
  (-9999999999999999999, 12, 'ffffffff7538dcfb76180001'),
  (-9999999999999999999, 13, 'ffffffffff7538dcfb76180001'),
  (-9999999999999999999, 14, 'ffffffffffff7538dcfb76180001'),
  (-9999999999999999999, 15, 'ffffffffffffff7538dcfb76180001'),
  (-9999999999999999999, 16, 'ffffffffffffffff7538dcfb76180001');

select is(
  (select hex from ref461 where v = -1 and w = 8),
  'ffffffffffffffff',
  'witness: the reference table carries -1 at width 8, the smallest width the old loop got wrong');

-- ---------------------------------------------------------------------------
-- The encoder's bytes equal the reference at every (value, width) the value fits: 62 rows
-- ---------------------------------------------------------------------------

select is(
  encode(archive._pq_plain_decimal(v, 0, w), 'hex'),
  hex,
  format('_pq_plain_decimal(%s, 0, %s) is %s', v, w, hex))
  from ref461
 order by v, w;

-- ---------------------------------------------------------------------------
-- The column shapes from the report, scaled the way the column path scales them
-- ---------------------------------------------------------------------------

select is(encode(archive._pq_plain_decimal(-1.5, 4, 9), 'hex'), 'ffffffffffffffc568',
  'numeric(19,4): -1.5 is -15000 unscaled, in 9 bytes');

select is(encode(archive._pq_plain_decimal(-0.0001, 4, 9), 'hex'), 'ffffffffffffffffff',
  'numeric(19,4): -0.0001 is -1 unscaled, in 9 bytes');

select is(encode(archive._pq_plain_decimal(999999999999999.9999, 4, 9), 'hex'), '008ac7230489e7ffff',
  'numeric(19,4): the column maximum is 9999999999999999999 unscaled, 19 digits, in 9 bytes');

select is(encode(archive._pq_plain_decimal(-0.01, 2, 8), 'hex'), 'ffffffffffffffff',
  'numeric(17,2): -0.01 is -1 unscaled, in 8 bytes');

-- The column path hands the encoder the scale and the width the declared type requires. Three rows,
-- two negative and one positive, all with distinct bytes, so a value landing in the wrong slot or a
-- row dropping out cannot produce the expected payload by accident.
create table public.money461 (id int4 primary key, amt numeric(19,4) not null);
insert into public.money461 (id, amt) values (1, -1.5), (2, -0.0001), (3, 999999999999999.9999);

select is(
  encode(archive._pq_encode_column_data(
    p_schema => 'public', p_table => 'money461', p_col => 'amt', p_pgtype => 'numeric',
    p_nullable => false, p_order_by => array['id']::name[],
    p_decimal_scale => 4, p_decimal_bytes => archive._pq_decimal_byte_width(19)), 'hex'),
  'ffffffffffffffc568' || 'ffffffffffffffffff' || '008ac7230489e7ffff',
  'a numeric(19,4) column of {-1.5, -0.0001, 999999999999999.9999} encodes to exactly those three 9-byte values, in id order');

select * from finish();

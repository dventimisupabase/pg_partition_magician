-- Minimal-viable Parquet writer, hand-rolled in PL/pgSQL with zero extension
-- dependencies (no pg_parquet / pg_duckdb / pg_lake / pg_mooncake).
--
-- Prototype for https://github.com/dventimisupabase/pg_partition_magician/issues/199.
-- NOT shipped code, not wired into pgpm_core. Scope, deliberately narrow:
--   - one row group, one uncompressed PLAIN-encoded data page per column
--   - NOT NULL columns only (no definition levels)
--   - types: int4, int8, float8, bool, text, timestamp[tz]
-- Field IDs and enum values below are taken directly from the canonical
-- apache/parquet-format parquet.thrift, not from memory.

create schema if not exists pq;

-- ---------------------------------------------------------------------------
-- Byte-level primitives
-- ---------------------------------------------------------------------------

create or replace function pq._byte(b int4) returns bytea
language sql immutable as $$
  select set_byte('\x00'::bytea, 0, b);
$$;

create or replace function pq._reverse_bytes(b bytea) returns bytea
language plpgsql immutable as $$
declare
  n int4 := length(b);
  buf bytea := b;
  i int4;
begin
  for i in 0..n-1 loop
    buf := set_byte(buf, i, get_byte(b, n-1-i));
  end loop;
  return buf;
end;
$$;

-- unsigned LEB128 varint; only ever called with non-negative magnitudes in
-- this writer (zigzag output, or a raw non-negative count/length).
create or replace function pq._varint(v bigint) returns bytea
language plpgsql immutable as $$
declare
  n bigint := v;
  buf bytea := ''::bytea;
  b int4;
begin
  if n < 0 then
    raise exception 'pq._varint: negative value % not supported', v;
  end if;
  loop
    b := (n & 127)::int4;
    n := n >> 7;
    if n <> 0 then
      buf := buf || pq._byte(b | 128);
    else
      buf := buf || pq._byte(b);
      exit;
    end if;
  end loop;
  return buf;
end;
$$;

create or replace function pq._zigzag(v bigint) returns bigint
language sql immutable as $$
  select case when v >= 0 then v * 2 else (0 - v) * 2 - 1 end;
$$;

-- ---------------------------------------------------------------------------
-- Thrift compact protocol: field headers, typed field writers, lists, structs
-- ---------------------------------------------------------------------------
-- Compact types used here: BOOLEAN_TRUE/FALSE unused (no bool fields in the
-- subset of the spec this writer touches); I32=5 I64=6 BINARY=8 LIST=9 STRUCT=12.

create or replace function pq._field_hdr(p_last_id int4, p_field_id int4, p_ctype int4) returns bytea
language plpgsql immutable as $$
declare
  delta int4 := p_field_id - p_last_id;
begin
  if delta between 1 and 15 then
    return pq._byte((delta << 4) | p_ctype);
  else
    return pq._byte(p_ctype) || pq._varint(pq._zigzag(p_field_id::bigint));
  end if;
end;
$$;

create or replace function pq._stop() returns bytea
language sql immutable as $$
  select pq._byte(0);
$$;

create or replace function pq._write_i32(p_last_id int4, p_field_id int4, p_val int4) returns bytea
language sql immutable as $$
  select pq._field_hdr(p_last_id, p_field_id, 5) || pq._varint(pq._zigzag(p_val::bigint));
$$;

create or replace function pq._write_i64(p_last_id int4, p_field_id int4, p_val int8) returns bytea
language sql immutable as $$
  select pq._field_hdr(p_last_id, p_field_id, 6) || pq._varint(pq._zigzag(p_val));
$$;

create or replace function pq._write_binary(p_last_id int4, p_field_id int4, p_val bytea) returns bytea
language sql immutable as $$
  select pq._field_hdr(p_last_id, p_field_id, 8) || pq._varint(length(p_val)::bigint) || p_val;
$$;

create or replace function pq._write_struct(p_last_id int4, p_field_id int4, p_val bytea) returns bytea
language sql immutable as $$
  select pq._field_hdr(p_last_id, p_field_id, 12) || p_val;
$$;

create or replace function pq._list_hdr(p_count int4, p_elem_ctype int4) returns bytea
language plpgsql immutable as $$
begin
  if p_count <= 14 then
    return pq._byte((p_count << 4) | p_elem_ctype);
  else
    return pq._byte((15 << 4) | p_elem_ctype) || pq._varint(p_count::bigint);
  end if;
end;
$$;

create or replace function pq._write_list_struct(p_last_id int4, p_field_id int4, p_elems bytea[]) returns bytea
language sql immutable as $$
  select pq._field_hdr(p_last_id, p_field_id, 9)
      || pq._list_hdr(coalesce(array_length(p_elems,1),0), 12)
      || coalesce((select string_agg(e, ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

create or replace function pq._write_list_i32(p_last_id int4, p_field_id int4, p_elems int4[]) returns bytea
language sql immutable as $$
  select pq._field_hdr(p_last_id, p_field_id, 9)
      || pq._list_hdr(coalesce(array_length(p_elems,1),0), 5)
      || coalesce((select string_agg(pq._varint(pq._zigzag(e::bigint)), ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

create or replace function pq._write_list_binary(p_last_id int4, p_field_id int4, p_elems bytea[]) returns bytea
language sql immutable as $$
  select pq._field_hdr(p_last_id, p_field_id, 9)
      || pq._list_hdr(coalesce(array_length(p_elems,1),0), 8)
      || coalesce((select string_agg(pq._varint(length(e)::bigint) || e, ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

-- ---------------------------------------------------------------------------
-- PLAIN encoding (Type physical values; see Encoding.PLAIN doc in the spec)
-- ---------------------------------------------------------------------------

create or replace function pq._plain_int32(v int4) returns bytea
language sql immutable as $$
  select pq._reverse_bytes(int4send(v));
$$;

create or replace function pq._plain_int64(v int8) returns bytea
language sql immutable as $$
  select pq._reverse_bytes(int8send(v));
$$;

create or replace function pq._plain_double(v float8) returns bytea
language sql immutable as $$
  select pq._reverse_bytes(float8send(v));
$$;

create or replace function pq._plain_bytearray(v bytea) returns bytea
language sql immutable as $$
  select pq._reverse_bytes(int4send(length(v))) || v;
$$;

create or replace function pq._plain_text(v text) returns bytea
language sql immutable as $$
  select pq._plain_bytearray(convert_to(v, 'UTF8'));
$$;

create or replace function pq._plain_boolean_array(vals boolean[]) returns bytea
language plpgsql immutable as $$
declare
  n int4 := coalesce(array_length(vals,1),0);
  nbytes int4 := ceil(n/8.0)::int4;
  buf bytea;
  i int4; byte_idx int4; bit_idx int4;
begin
  if n = 0 then
    return ''::bytea;
  end if;
  buf := decode(repeat('00', nbytes), 'hex');
  for i in 1..n loop
    byte_idx := (i-1) / 8;
    bit_idx  := (i-1) % 8;
    if vals[i] then
      buf := set_byte(buf, byte_idx, get_byte(buf, byte_idx) | (1 << bit_idx));
    end if;
  end loop;
  return buf;
end;
$$;

-- ---------------------------------------------------------------------------
-- Struct builders (SchemaElement / DataPageHeader / PageHeader /
-- ColumnMetaData / ColumnChunk / RowGroup / FileMetaData)
-- ---------------------------------------------------------------------------

create or replace function pq._build_schema_root(p_num_children int4) returns bytea
language sql immutable as $$
  select pq._write_binary(0, 4, convert_to('root', 'UTF8'))
      || pq._write_i32(4, 5, p_num_children)
      || pq._stop();
$$;

-- p_converted: parquet ConvertedType code, or -1 for "none"
create or replace function pq._build_schema_leaf(p_name text, p_ptype int4, p_converted int4) returns bytea
language plpgsql immutable as $$
declare
  buf bytea;
begin
  buf := pq._write_i32(0, 1, p_ptype);                                     -- type
  buf := buf || pq._write_i32(1, 3, 0);                                    -- repetition_type = REQUIRED
  buf := buf || pq._write_binary(3, 4, convert_to(p_name, 'UTF8'));        -- name
  if p_converted >= 0 then
    buf := buf || pq._write_i32(4, 6, p_converted);                       -- converted_type
  end if;
  buf := buf || pq._stop();
  return buf;
end;
$$;

create or replace function pq._build_data_page_header(p_num_values int4) returns bytea
language sql immutable as $$
  select pq._write_i32(0, 1, p_num_values)      -- num_values
      || pq._write_i32(1, 2, 0)                 -- encoding = PLAIN
      || pq._write_i32(2, 3, 3)                  -- definition_level_encoding = RLE
      || pq._write_i32(3, 4, 3)                  -- repetition_level_encoding = RLE
      || pq._stop();
$$;

create or replace function pq._build_page_header(p_num_values int4, p_data_len int4) returns bytea
language plpgsql immutable as $$
declare
  dph bytea := pq._build_data_page_header(p_num_values);
  buf bytea;
begin
  buf := pq._write_i32(0, 1, 0);                    -- type = DATA_PAGE
  buf := buf || pq._write_i32(1, 2, p_data_len);     -- uncompressed_page_size
  buf := buf || pq._write_i32(2, 3, p_data_len);     -- compressed_page_size (codec = UNCOMPRESSED)
  buf := buf || pq._write_struct(3, 5, dph);         -- data_page_header
  buf := buf || pq._stop();
  return buf;
end;
$$;

create or replace function pq._build_column_metadata(
    p_ptype int4, p_colname text, p_num_values bigint,
    p_total_uncompressed bigint, p_data_page_offset bigint
) returns bytea
language plpgsql immutable as $$
declare
  buf bytea;
begin
  buf := pq._write_i32(0, 1, p_ptype);                                              -- type
  buf := buf || pq._write_list_i32(1, 2, array[0]);                                 -- encodings = [PLAIN]
  buf := buf || pq._write_list_binary(2, 3, array[convert_to(p_colname,'UTF8')]);   -- path_in_schema
  buf := buf || pq._write_i32(3, 4, 0);                                            -- codec = UNCOMPRESSED
  buf := buf || pq._write_i64(4, 5, p_num_values);                                  -- num_values
  buf := buf || pq._write_i64(5, 6, p_total_uncompressed);                          -- total_uncompressed_size
  buf := buf || pq._write_i64(6, 7, p_total_uncompressed);                          -- total_compressed_size
  buf := buf || pq._write_i64(7, 9, p_data_page_offset);                            -- data_page_offset
  buf := buf || pq._stop();
  return buf;
end;
$$;

create or replace function pq._build_column_chunk(p_metadata bytea) returns bytea
language sql immutable as $$
  select pq._write_i64(0, 2, 0)              -- file_offset (deprecated, 0)
      || pq._write_struct(2, 3, p_metadata)  -- meta_data
      || pq._stop();
$$;

create or replace function pq._build_row_group(p_chunks bytea[], p_total_bytes bigint, p_num_rows bigint) returns bytea
language sql immutable as $$
  select pq._write_list_struct(0, 1, p_chunks)      -- columns
      || pq._write_i64(1, 2, p_total_bytes)         -- total_byte_size
      || pq._write_i64(2, 3, p_num_rows)            -- num_rows
      || pq._stop();
$$;

create or replace function pq._build_file_metadata(p_schema bytea[], p_num_rows bigint, p_row_groups bytea[]) returns bytea
language sql immutable as $$
  select pq._write_i32(0, 1, 1)                                                       -- version
      || pq._write_list_struct(1, 2, p_schema)                                        -- schema
      || pq._write_i64(2, 3, p_num_rows)                                               -- num_rows
      || pq._write_list_struct(3, 4, p_row_groups)                                     -- row_groups
      || pq._write_binary(4, 6, convert_to('pg_partition_magician parquet prototype', 'UTF8')) -- created_by
      || pq._stop();
$$;

-- ---------------------------------------------------------------------------
-- Column data extraction (server-side aggregation, ctid-ordered so every
-- column's array lines up on the same row order)
-- ---------------------------------------------------------------------------

create or replace function pq._encode_column_data(p_from_sql text, p_col text, p_pgtype text) returns bytea
language plpgsql as $$
declare
  payload bytea := ''::bytea;
  arr_i4 int4[]; arr_i8 int8[]; arr_f8 float8[]; arr_bool boolean[]; arr_text text[]; arr_ts timestamptz[];
  i int4; n int4;
begin
  if p_pgtype = 'int4' then
    execute format('select array_agg(%I::int4 order by ctid) from %s', p_col, p_from_sql) into arr_i4;
    n := coalesce(array_length(arr_i4,1),0);
    for i in 1..n loop payload := payload || pq._plain_int32(arr_i4[i]); end loop;
  elsif p_pgtype = 'int8' then
    execute format('select array_agg(%I::int8 order by ctid) from %s', p_col, p_from_sql) into arr_i8;
    n := coalesce(array_length(arr_i8,1),0);
    for i in 1..n loop payload := payload || pq._plain_int64(arr_i8[i]); end loop;
  elsif p_pgtype = 'float8' then
    execute format('select array_agg(%I::float8 order by ctid) from %s', p_col, p_from_sql) into arr_f8;
    n := coalesce(array_length(arr_f8,1),0);
    for i in 1..n loop payload := payload || pq._plain_double(arr_f8[i]); end loop;
  elsif p_pgtype = 'bool' then
    execute format('select array_agg(%I::boolean order by ctid) from %s', p_col, p_from_sql) into arr_bool;
    payload := pq._plain_boolean_array(arr_bool);
  elsif p_pgtype = 'text' then
    execute format('select array_agg(%I::text order by ctid) from %s', p_col, p_from_sql) into arr_text;
    n := coalesce(array_length(arr_text,1),0);
    for i in 1..n loop payload := payload || pq._plain_text(arr_text[i]); end loop;
  elsif p_pgtype in ('timestamptz','timestamp') then
    execute format('select array_agg(%I::timestamptz order by ctid) from %s', p_col, p_from_sql) into arr_ts;
    n := coalesce(array_length(arr_ts,1),0);
    for i in 1..n loop
      payload := payload || pq._plain_int64(round(extract(epoch from arr_ts[i]) * 1000000)::int8);
    end loop;
  else
    raise exception 'pq._encode_column_data: unsupported column type % for column %', p_pgtype, p_col;
  end if;
  return payload;
end;
$$;

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

create or replace function pq.to_parquet(p_relation regclass) returns bytea
language plpgsql as $$
declare
  v_schema name; v_table name; v_from_sql text;
  v_col record;
  v_col_names text[] := '{}';
  v_col_pgtypes text[] := '{}';
  v_col_ptypes int4[] := '{}';
  v_col_converted int4[] := '{}';
  v_ncols int4;
  v_num_rows bigint;
  v_magic bytea := convert_to('PAR1', 'UTF8');
  v_body bytea;
  v_data bytea; v_page_header bytea; v_page_offset bigint;
  v_column_chunks bytea[] := '{}';
  v_schema_elements bytea[] := '{}';
  v_total_uncompressed bigint;
  v_row_group bytea;
  v_schema_list bytea[];
  v_footer bytea;
  i int4;
begin
  select n.nspname, c.relname into v_schema, v_table
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.oid = p_relation;
  v_from_sql := format('%I.%I', v_schema, v_table);

  for v_col in
    select a.attname, a.attnotnull, t.typname
    from pg_attribute a join pg_type t on t.oid = a.atttypid
    where a.attrelid = p_relation and a.attnum > 0 and not a.attisdropped
    order by a.attnum
  loop
    if not v_col.attnotnull then
      raise exception 'pq.to_parquet: column % is nullable; this prototype only supports NOT NULL columns', v_col.attname;
    end if;

    v_col_names := v_col_names || v_col.attname;

    case v_col.typname
      when 'int4'        then v_col_pgtypes := v_col_pgtypes || 'int4'::text;        v_col_ptypes := v_col_ptypes || 1; v_col_converted := v_col_converted || -1;
      when 'int8'        then v_col_pgtypes := v_col_pgtypes || 'int8'::text;        v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || -1;
      when 'float8'      then v_col_pgtypes := v_col_pgtypes || 'float8'::text;      v_col_ptypes := v_col_ptypes || 5; v_col_converted := v_col_converted || -1;
      when 'bool'        then v_col_pgtypes := v_col_pgtypes || 'bool'::text;        v_col_ptypes := v_col_ptypes || 0; v_col_converted := v_col_converted || -1;
      when 'text'        then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 0;
      when 'timestamptz' then v_col_pgtypes := v_col_pgtypes || 'timestamptz'::text; v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
      when 'timestamp'   then v_col_pgtypes := v_col_pgtypes || 'timestamp'::text;   v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
      else raise exception 'pq.to_parquet: unsupported column type % for column %', v_col.typname, v_col.attname;
    end case;
  end loop;

  v_ncols := array_length(v_col_names, 1);
  if v_ncols is null then
    raise exception 'pq.to_parquet: relation % has no supported columns', p_relation;
  end if;

  execute format('select count(*) from %s', v_from_sql) into v_num_rows;

  v_body := v_magic;
  for i in 1..v_ncols loop
    v_data := pq._encode_column_data(v_from_sql, v_col_names[i], v_col_pgtypes[i]);
    v_page_header := pq._build_page_header(v_num_rows::int4, length(v_data));
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_data;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || pq._build_column_chunk(
        pq._build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset));
    v_schema_elements := v_schema_elements || pq._build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i]);
  end loop;

  v_row_group := pq._build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(pq._build_schema_root(v_ncols), v_schema_elements);
  v_footer := pq._build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  return v_body || v_footer || pq._reverse_bytes(int4send(length(v_footer))) || v_magic;
end;
$$;

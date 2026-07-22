-- Minimal-viable Parquet writer, hand-rolled in PL/pgSQL with zero extension
-- dependencies (no pg_parquet / pg_duckdb / pg_lake / pg_mooncake).
--
-- Prototype for https://github.com/dventimisupabase/pg_partition_magician/issues/199.
-- NOT shipped code, not wired into pgpm_core. Scope, deliberately narrow:
--   - one row group, one uncompressed PLAIN-encoded data page per column
--   - nullable columns supported (OPTIONAL, single-level definition levels);
--     no repeated fields, no nested schemas
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

-- Definition levels for an OPTIONAL (nullable) column: a flat, non-nested schema has
-- max_definition_level = 1, so this is a bitmap (1 = present, 0 = null) encoded with the
-- RLE/bit-packed-hybrid encoding, one single bit-packed run covering the whole page,
-- 4-byte-length-prefixed (Data page v1 always prepends the length for levels, per the
-- Encodings.md table). IMPORTANT: the header's varint is a PLAIN unsigned ULEB128
-- (Encodings.md point 2), NOT the Thrift zigzag varint used everywhere else in this file --
-- these are two unrelated encodings that just happen to share the word "varint". At
-- bit_width=1 the "different packing order" the spec calls out collapses to the same
-- LSB-first-per-byte packing pq._plain_boolean_array already uses, so this reuses that shape.
create or replace function pq._definition_levels(is_present boolean[]) returns bytea
language plpgsql immutable as $$
declare
  n int4 := coalesce(array_length(is_present,1),0);
  nbytes int4;
  packed bytea;
  i int4; byte_idx int4; bit_idx int4;
  header bytea;
  encoded_data bytea;
begin
  if n = 0 then
    return pq._reverse_bytes(int4send(0));   -- valid empty hybrid stream: zero-length encoded-data
  end if;
  nbytes := ceil(n/8.0)::int4;
  packed := decode(repeat('00', nbytes), 'hex');
  for i in 1..n loop
    byte_idx := (i-1) / 8;
    bit_idx  := (i-1) % 8;
    if is_present[i] then
      packed := set_byte(packed, byte_idx, get_byte(packed, byte_idx) | (1 << bit_idx));
    end if;
  end loop;
  -- bit-packed-header := varint-encode(<bit-pack-scaled-run-len> << 1 | 1); scaled-run-len is
  -- (bit-packed-run-len)/8, and since every byte here packs exactly 8 values, that's just nbytes.
  header := pq._varint(((nbytes::bigint) << 1) | 1);
  encoded_data := header || packed;
  return pq._reverse_bytes(int4send(length(encoded_data))) || encoded_data;
end;
$$;

-- ---------------------------------------------------------------------------
-- GZIP compression: a from-scratch DEFLATE (RFC 1951) encoder plus a CRC-32
-- (RFC 1952) trailer, zero extension dependencies. Real LZ77 matching (not
-- just Huffman-coded literals): a rolling 3-byte hash per position, a SQL
-- self-join capped via LATERAL...LIMIT 1 to find the nearest candidate within
-- a 32KB window (an unbounded search degrades badly on exactly the
-- highly-repetitive input compression matters most for), and a binary-search
-- match-length extension via substr equality (O(log match_length) native
-- comparisons instead of a byte-by-byte extend loop). The parse itself is
-- lazy -- driven by the greedy walk, so a position consumed by a preceding
-- match is never looked up at all, not merely computed and discarded.
--
-- Fixed Huffman only (DEFLATE block type 1): the code lengths are spec-
-- mandated constants (RFC 1951 3.2.6), so there is no tree-from-frequencies
-- step. Two PostgreSQL/PL-pgSQL performance traps, found by benchmarking
-- against real table-sourced data rather than assumed: (1) a per-bit
-- insertion loop is far slower than merging a whole code into a wide
-- accumulator via one shift+OR (bit-reversing a Huffman code once per TOKEN,
-- not once per output BIT, since codes are written MSB-first on the wire but
-- the byte stream itself packs LSB-first -- an inversion easy to get
-- backwards); (2) calling small helper functions (length/distance code
-- lookup) via the OUT-parameter "select ... from f(...)" convention costs
-- more per call than the arithmetic they wrap once called millions of times,
-- so those lookups are inlined as plain CASE expressions in the hot loop
-- instead of factored out.
-- ---------------------------------------------------------------------------

-- CRC-32/ISO-HDLC (the checksum RFC 1952's gzip trailer requires), table-driven.
create or replace function pq._crc32_table() returns bigint[]
language plpgsql immutable as $$
declare
  tbl bigint[] := array_fill(0::bigint, array[256]);
  c bigint; i int4; j int4;
begin
  for i in 0..255 loop
    c := i;
    for j in 0..7 loop
      if (c & 1) = 1 then c := (c >> 1) # 3988292384;   -- 0xEDB88320
      else c := c >> 1;
      end if;
    end loop;
    tbl[i+1] := c;
  end loop;
  return tbl;
end;
$$;

-- `data` is forced into a fresh, plain (non-TOASTed) copy before the per-byte loop: calling
-- get_byte() repeatedly on a bytea sourced from a real table column is ~1000x slower than the
-- identical loop over a freshly-built local variable (measured: 49s vs 58ms for the same 1MB
-- input) -- PostgreSQL does not cache the detoasted form across calls the way one might expect.
create or replace function pq._crc32(data bytea) returns bigint
language plpgsql as $$
declare
  tbl bigint[] := pq._crc32_table();
  crc bigint := 4294967295;
  v_data bytea := data || ''::bytea;
  n int4 := length(v_data);
  i int4;
begin
  for i in 0..n-1 loop
    crc := tbl[(((crc # get_byte(v_data,i)) & 255) + 1)] # (crc >> 8);
  end loop;
  return crc # 4294967295;
end;
$$;

-- one row per position 0..length(data)-3: a 3-byte rolling "hash" (the exact 3-byte value
-- itself, so no collisions -- cheap enough at this alphabet size and simpler than a lossy hash)
create or replace function pq._lz_pos_hashes(data bytea) returns table(pos int4, h int4)
language sql immutable as $$
  select i, (get_byte(data,i)<<16) | (get_byte(data,i+1)<<8) | get_byte(data,i+2)
  from generate_series(0, length(data)-3) i;
$$;

-- longest k in [0, max_len] with substr(data,a+1,k) = substr(data,b+1,k): a binary search over
-- native substr-equality comparisons (each a C-level memcmp regardless of k), not a byte-by-byte
-- extend loop -- O(log max_len) comparisons instead of O(max_len).
create or replace function pq._lz_match_len(data bytea, a int4, b int4, max_len int4) returns int4
language plpgsql immutable as $$
declare
  lo int4 := 0; hi int4 := max_len; mid int4;
begin
  while lo < hi loop
    mid := (lo + hi + 1) / 2;
    if substr(data, a+1, mid) = substr(data, b+1, mid) then lo := mid; else hi := mid - 1; end if;
  end loop;
  return lo;
end;
$$;

-- reverse the low `nbits` bits of `value`: needed once per Huffman-code insert (bounded at 9
-- bits here), not once per output bit -- see pq._deflate_encode.
create or replace function pq._bit_reverse(value int4, nbits int4) returns int4
language plpgsql immutable as $$
declare rev int4 := 0; i int4;
begin
  for i in 0..nbits-1 loop
    rev := rev | (((value >> i) & 1) << (nbits - 1 - i));
  end loop;
  return rev;
end;
$$;

-- DEFLATE-encode `payload` as one final, fixed-Huffman block (RFC 1951 3.2.3/3.2.6). Builds its
-- own scratch hash table per call (one call per column page; matching never crosses column
-- boundaries) -- a hardcoded table name, not a regclass/text parameter passed through EXECUTE:
-- dynamic SQL measured ~2.5x slower per lookup than a plain statement referencing a fixed name,
-- for exactly the reason invoking any function has overhead -- EXECUTE just adds more of it.
create or replace function pq._deflate_encode(payload bytea) returns bytea
language plpgsql as $$
declare
  n int4 := length(payload);
  v_pos int4 := 0;
  v_hash int4; v_candidate int4; v_mlen int4;
  v_acc int4 := 0; v_acc_n int4 := 0; v_bytes int4[] := '{}';
  v_code int4; v_nbits int4; v_rev int4;
  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;
  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;
  v_dist int4; v_len int4; v_sym int4;
begin
  drop table if exists pq_deflate_hash_scratch;
  create temp table pq_deflate_hash_scratch as select * from pq._lz_pos_hashes(payload);
  create index on pq_deflate_hash_scratch (h, pos);

  -- block header: BFINAL=1, BTYPE=01 (fixed Huffman) -- raw, LSB-of-value-first (the OPPOSITE
  -- convention from Huffman codes, which are MSB-of-the-code-first; RFC 1951 3.1.1 splits these
  -- two conventions and it is easy to invert one for the other by accident).
  v_acc := v_acc | (3 << v_acc_n); v_acc_n := v_acc_n + 3;
  while v_acc_n >= 8 loop
    v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
  end loop;

  while v_pos < n loop
    v_candidate := null;
    if v_pos <= n - 3 then
      v_hash := (get_byte(payload,v_pos)<<16) | (get_byte(payload,v_pos+1)<<8) | get_byte(payload,v_pos+2);
      select pos into v_candidate from pq_deflate_hash_scratch
       where h = v_hash and pos < v_pos and v_pos - pos <= 32768
       order by pos desc limit 1;
    end if;
    if v_candidate is not null then
      v_mlen := pq._lz_match_len(payload, v_pos, v_candidate, least(258, n - v_pos));
    else
      v_mlen := 0;
    end if;

    if v_mlen >= 3 then
      v_dist := v_pos - v_candidate;
      v_len := v_mlen;

      -- length code (RFC 1951 3.2.5), inlined rather than a separate lookup function -- see the
      -- section header note on OUT-parameter call overhead.
      case
        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;
        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;
        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;
        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;
        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;
        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;
        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;
      end case;

      -- distance code (RFC 1951 3.2.5), inlined
      case
        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;
        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;
        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;
        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;
        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;
        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;
        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;
        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;
        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;
        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;
        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;
        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;
        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;
        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;
      end case;

      -- length code's literal/length Huffman code (RFC 1951 3.2.6), inlined
      v_sym := v_lcode;
      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;
      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;
      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;
      else v_code := 192+(v_sym-280); v_nbits := 8;
      end if;
      v_rev := pq._bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop
        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
      end loop;

      if v_lextra_bits > 0 then
        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;
        while v_acc_n >= 8 loop
          v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
        end loop;
      end if;

      -- distance code: fixed 5-bit Huffman, identity-mapped (RFC 1951 3.2.6)
      v_rev := pq._bit_reverse(v_dcode, 5);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 5;
      while v_acc_n >= 8 loop
        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
      end loop;

      if v_dextra_bits > 0 then
        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;
        while v_acc_n >= 8 loop
          v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
        end loop;
      end if;

      v_pos := v_pos + v_mlen;
    else
      v_sym := get_byte(payload, v_pos);
      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;
      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;
      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;
      else v_code := 192+(v_sym-280); v_nbits := 8;
      end if;
      v_rev := pq._bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop
        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
      end loop;
      v_pos := v_pos + 1;
    end if;
  end loop;

  -- end-of-block (symbol 256): 7-bit code, value 0
  v_rev := pq._bit_reverse(0, 7);
  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 7;
  while v_acc_n >= 8 loop
    v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
  end loop;
  if v_acc_n > 0 then v_bytes := array_append(v_bytes, v_acc & 255); end if;   -- pad final byte

  drop table pq_deflate_hash_scratch;
  return (select decode(string_agg(lpad(to_hex(x), 2, '0'), '' order by ord), 'hex')
          from unnest(v_bytes) with ordinality as t(x, ord));
end;
$$;

-- the full RFC 1952 gzip container Parquet's GZIP codec expects (confirmed empirically: a real
-- pyarrow-written GZIP-compressed Parquet file's page bytes open with the 1f8b gzip magic and
-- read cleanly via Python's stdlib gzip reader end to end, not a bare zlib/RFC-1950 stream) --
-- 10-byte header, the DEFLATE stream, then a CRC-32 + ISIZE trailer over the ORIGINAL
-- (uncompressed) bytes.
create or replace function pq._gzip_compress(payload bytea) returns bytea
language plpgsql as $$
declare
  v_deflate bytea := pq._deflate_encode(payload);
  v_header bytea := decode('1f8b08000000000000ff', 'hex');
  v_crc bigint := pq._crc32(payload);
  v_isize bigint := length(payload) & 4294967295;
  v_trailer bytea;
begin
  v_trailer := pq._reverse_bytes(int4send((v_crc - 4294967296 * (v_crc >> 31))::int4))
            || pq._reverse_bytes(int4send((v_isize - 4294967296 * (v_isize >> 31))::int4));
  return v_header || v_deflate || v_trailer;
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
create or replace function pq._build_schema_leaf(p_name text, p_ptype int4, p_converted int4, p_nullable boolean) returns bytea
language plpgsql immutable as $$
declare
  buf bytea;
begin
  buf := pq._write_i32(0, 1, p_ptype);                                     -- type
  buf := buf || pq._write_i32(1, 3, case when p_nullable then 1 else 0 end); -- repetition_type
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

-- p_compressed_len defaults to p_uncompressed_len (codec = UNCOMPRESSED, the existing
-- behavior unchanged); pass a smaller value when the page bytes going into the file are
-- actually pq._gzip_compress(...) output rather than the raw encoded bytes.
create or replace function pq._build_page_header(p_num_values int4, p_uncompressed_len int4, p_compressed_len int4 default null) returns bytea
language plpgsql immutable as $$
declare
  dph bytea := pq._build_data_page_header(p_num_values);
  v_compressed_len int4 := coalesce(p_compressed_len, p_uncompressed_len);
  buf bytea;
begin
  buf := pq._write_i32(0, 1, 0);                        -- type = DATA_PAGE
  buf := buf || pq._write_i32(1, 2, p_uncompressed_len); -- uncompressed_page_size
  buf := buf || pq._write_i32(2, 3, v_compressed_len);   -- compressed_page_size
  buf := buf || pq._write_struct(3, 5, dph);             -- data_page_header
  buf := buf || pq._stop();
  return buf;
end;
$$;

-- p_codec: 0 = UNCOMPRESSED (default, existing behavior), 2 = GZIP. p_total_compressed
-- defaults to p_total_uncompressed for the UNCOMPRESSED case.
create or replace function pq._build_column_metadata(
    p_ptype int4, p_colname text, p_num_values bigint,
    p_total_uncompressed bigint, p_data_page_offset bigint,
    p_codec int4 default 0, p_total_compressed bigint default null
) returns bytea
language plpgsql immutable as $$
declare
  v_total_compressed bigint := coalesce(p_total_compressed, p_total_uncompressed);
  buf bytea;
begin
  buf := pq._write_i32(0, 1, p_ptype);                                              -- type
  buf := buf || pq._write_list_i32(1, 2, array[0]);                                 -- encodings = [PLAIN]
  buf := buf || pq._write_list_binary(2, 3, array[convert_to(p_colname,'UTF8')]);   -- path_in_schema
  buf := buf || pq._write_i32(3, 4, p_codec);                                       -- codec
  buf := buf || pq._write_i64(4, 5, p_num_values);                                  -- num_values
  buf := buf || pq._write_i64(5, 6, p_total_uncompressed);                          -- total_uncompressed_size
  buf := buf || pq._write_i64(6, 7, v_total_compressed);                            -- total_compressed_size
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

-- p_nullable columns interleave nulls with real values (array_agg preserves NULLs in
-- position, so this is a single order-by-clause-ordered pass either way); is_present[i]
-- tracks which rows had a value so the OPTIONAL path can prepend a definition-levels bitmap,
-- while the values-only payload always contains just the non-null values, in row order. For
-- a NOT NULL column every element is guaranteed non-null (Postgres enforces that at the
-- table level), so this collapses to the old unconditional-encode behavior byte-for-byte;
-- only p_nullable decides whether the definition-levels block gets prepended at all.
--
-- p_order_by defaults to 'ctid': a single relation has a stable physical order and no other
-- column is guaranteed unique, so ctid is the only cheap total order available. It stops being
-- valid the moment p_from_sql spans more than one physical relation (ctid is only comparable
-- within one heap) -- pq.to_parquet_range passes an explicit '<control col>, <key cols>' clause
-- for exactly that reason; see the tiebreaker note there.
create or replace function pq._encode_column_data(p_from_sql text, p_col text, p_pgtype text, p_nullable boolean, p_order_by text default 'ctid') returns bytea
language plpgsql as $$
declare
  values_payload bytea := ''::bytea;
  is_present boolean[] := '{}';
  arr_i4 int4[]; arr_i8 int8[]; arr_f8 float8[]; arr_bool boolean[]; arr_text text[]; arr_ts timestamptz[];
  present_bools boolean[] := '{}';
  i int4; n int4;
begin
  if p_pgtype = 'int4' then
    execute format('select array_agg(%I::int4 order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_i4;
    n := coalesce(array_length(arr_i4,1),0);
    for i in 1..n loop
      is_present[i] := (arr_i4[i] is not null);
      if arr_i4[i] is not null then values_payload := values_payload || pq._plain_int32(arr_i4[i]); end if;
    end loop;
  elsif p_pgtype = 'int8' then
    execute format('select array_agg(%I::int8 order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_i8;
    n := coalesce(array_length(arr_i8,1),0);
    for i in 1..n loop
      is_present[i] := (arr_i8[i] is not null);
      if arr_i8[i] is not null then values_payload := values_payload || pq._plain_int64(arr_i8[i]); end if;
    end loop;
  elsif p_pgtype = 'float8' then
    execute format('select array_agg(%I::float8 order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_f8;
    n := coalesce(array_length(arr_f8,1),0);
    for i in 1..n loop
      is_present[i] := (arr_f8[i] is not null);
      if arr_f8[i] is not null then values_payload := values_payload || pq._plain_double(arr_f8[i]); end if;
    end loop;
  elsif p_pgtype = 'bool' then
    execute format('select array_agg(%I::boolean order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_bool;
    n := coalesce(array_length(arr_bool,1),0);
    for i in 1..n loop
      is_present[i] := (arr_bool[i] is not null);
      if arr_bool[i] is not null then present_bools := present_bools || arr_bool[i]; end if;
    end loop;
    values_payload := pq._plain_boolean_array(present_bools);
  elsif p_pgtype = 'text' then
    execute format('select array_agg(%I::text order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_text;
    n := coalesce(array_length(arr_text,1),0);
    for i in 1..n loop
      is_present[i] := (arr_text[i] is not null);
      if arr_text[i] is not null then values_payload := values_payload || pq._plain_text(arr_text[i]); end if;
    end loop;
  elsif p_pgtype in ('timestamptz','timestamp') then
    execute format('select array_agg(%I::timestamptz order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_ts;
    n := coalesce(array_length(arr_ts,1),0);
    for i in 1..n loop
      is_present[i] := (arr_ts[i] is not null);
      if arr_ts[i] is not null then
        values_payload := values_payload || pq._plain_int64(round(extract(epoch from arr_ts[i]) * 1000000)::int8);
      end if;
    end loop;
  else
    raise exception 'pq._encode_column_data: unsupported column type % for column %', p_pgtype, p_col;
  end if;

  if p_nullable then
    return pq._definition_levels(is_present) || values_payload;
  else
    return values_payload;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

create or replace function pq.to_parquet(p_relation regclass, p_compress boolean default false) returns bytea
language plpgsql as $$
declare
  v_schema name; v_table name; v_from_sql text;
  v_col record;
  v_col_names text[] := '{}';
  v_col_pgtypes text[] := '{}';
  v_col_ptypes int4[] := '{}';
  v_col_converted int4[] := '{}';
  v_col_nullable boolean[] := '{}';
  v_ncols int4;
  v_num_rows bigint;
  v_magic bytea := convert_to('PAR1', 'UTF8');
  v_body bytea;
  v_data bytea; v_page_bytes bytea; v_page_header bytea; v_page_offset bigint;
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
    v_col_names := v_col_names || v_col.attname;
    v_col_nullable := v_col_nullable || (not v_col.attnotnull);

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
    v_data := pq._encode_column_data(v_from_sql, v_col_names[i], v_col_pgtypes[i], v_col_nullable[i]);
    if p_compress then
      v_page_bytes := pq._gzip_compress(v_data);
      v_page_header := pq._build_page_header(v_num_rows::int4, length(v_data), length(v_page_bytes));
    else
      v_page_bytes := v_data;
      v_page_header := pq._build_page_header(v_num_rows::int4, length(v_data));
    end if;
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_page_bytes;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || pq._build_column_chunk(
        pq._build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset,
          case when p_compress then 2 else 0 end,
          case when p_compress then length(v_page_header) + length(v_page_bytes) else null end));
    v_schema_elements := v_schema_elements || pq._build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i], v_col_nullable[i]);
  end loop;

  v_row_group := pq._build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(pq._build_schema_root(v_ncols), v_schema_elements);
  v_footer := pq._build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  return v_body || v_footer || pq._reverse_bytes(int4send(length(v_footer))) || v_magic;
end;
$$;

-- ---------------------------------------------------------------------------
-- Cross-partition range read (chunked archival: a Parquet file's rows come from a
-- [lo, hi) range of a control column, not from one child partition)
-- ---------------------------------------------------------------------------

-- Discover a resumable-read key for p_relation: a PRIMARY KEY if there is one, else a
-- predicate/expression-free UNIQUE CONSTRAINT (never a bare UNIQUE INDEX unbacked by a
-- constraint) -- the identical contract pgpm.regrain_step already enforces
-- (pgpm_core/install.sql, the v_keyidx/v_pkjoin discovery) for the same underlying reason:
-- only a real key can tiebreak a resumable ordered read when the control column repeats.
-- Returns column names in index order, or NULL if the relation is genuinely keyless -- the
-- caller must refuse, the same 'nokey' contract regrain() raises on; this is an inherited
-- limitation, not a new gap. (On a partitioned parent, Postgres itself requires any unique
-- constraint to include every partitioning column, so in practice the control column is
-- always already one of the columns returned here.)
create or replace function pq._key_columns(p_relation regclass) returns name[]
language plpgsql as $$
declare v_keyidx oid; v_cols name[];
begin
  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_relation and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_relation and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is null then return null; end if;
  select array_agg(a.attname order by k.ord) into v_cols
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx;
  return v_cols;
end;
$$;

-- pq.to_parquet_range: like pq.to_parquet, but reads a [p_lo, p_hi) range of p_control off
-- p_parent (a plain table OR a partitioned parent -- Postgres's own Append/Merge Append
-- pruning spans whichever children the range touches transparently; nothing here names a
-- child) instead of one whole relation. p_lo/p_hi are literals already typed for p_control's
-- actual column type (the caller's job -- e.g. translate a pgpm native-grid value via
-- pgpm._encode first for a uuidv7-kind control column, same as regrain_step's v_lo_lit/
-- v_hi_lit; this function only ever sees the column's own type).
--
-- Ordering by p_control alone is not deterministic once it repeats (duplicate timestamps are
-- routine for a time-kind control column), and ctid -- pq.to_parquet's tiebreak -- is not
-- comparable across a range that spans more than one child's heap. So this orders by
-- (p_control, <key columns>) instead: a real key makes every row's sort position unique and
-- reproducible, which is what lets a future chunk boundary land between two rows rather than
-- inside a run of ties (see the design note on the chunker's stopping rule). A relation with
-- no real key refuses outright, via pq._key_columns's NULL.
create or replace function pq.to_parquet_range(p_parent regclass, p_control name, p_lo text, p_hi text, p_compress boolean default false) returns bytea
language plpgsql as $$
declare
  v_schema name; v_table name; v_from_sql text; v_order_by text; v_key_cols name[];
  v_col record;
  v_col_names text[] := '{}';
  v_col_pgtypes text[] := '{}';
  v_col_ptypes int4[] := '{}';
  v_col_converted int4[] := '{}';
  v_col_nullable boolean[] := '{}';
  v_ncols int4;
  v_num_rows bigint;
  v_magic bytea := convert_to('PAR1', 'UTF8');
  v_body bytea;
  v_data bytea; v_page_bytes bytea; v_page_header bytea; v_page_offset bigint;
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
    where c.oid = p_parent;

  v_key_cols := pq._key_columns(p_parent);
  if v_key_cols is null then
    raise exception 'pq.to_parquet_range: % has no primary key or predicate/expression-free unique constraint; a resumable cross-partition range read cannot tiebreak ties on % without one (the same refusal pgpm.regrain_step already makes for keyless tables)',
      p_parent, p_control;
  end if;
  select string_agg(quote_ident(c), ', ' order by ord) into v_order_by
    from unnest(v_key_cols) with ordinality as t(c, ord);
  v_order_by := quote_ident(p_control) || ', ' || v_order_by;

  v_from_sql := format('(select * from %I.%I where %I >= %L and %I < %L) x',
                        v_schema, v_table, p_control, p_lo, p_control, p_hi);

  for v_col in
    select a.attname, a.attnotnull, t.typname
    from pg_attribute a join pg_type t on t.oid = a.atttypid
    where a.attrelid = p_parent and a.attnum > 0 and not a.attisdropped
    order by a.attnum
  loop
    v_col_names := v_col_names || v_col.attname;
    v_col_nullable := v_col_nullable || (not v_col.attnotnull);

    case v_col.typname
      when 'int4'        then v_col_pgtypes := v_col_pgtypes || 'int4'::text;        v_col_ptypes := v_col_ptypes || 1; v_col_converted := v_col_converted || -1;
      when 'int8'        then v_col_pgtypes := v_col_pgtypes || 'int8'::text;        v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || -1;
      when 'float8'      then v_col_pgtypes := v_col_pgtypes || 'float8'::text;      v_col_ptypes := v_col_ptypes || 5; v_col_converted := v_col_converted || -1;
      when 'bool'        then v_col_pgtypes := v_col_pgtypes || 'bool'::text;        v_col_ptypes := v_col_ptypes || 0; v_col_converted := v_col_converted || -1;
      when 'text'        then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 0;
      when 'timestamptz' then v_col_pgtypes := v_col_pgtypes || 'timestamptz'::text; v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
      when 'timestamp'   then v_col_pgtypes := v_col_pgtypes || 'timestamp'::text;   v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
      else raise exception 'pq.to_parquet_range: unsupported column type % for column %', v_col.typname, v_col.attname;
    end case;
  end loop;

  v_ncols := array_length(v_col_names, 1);
  if v_ncols is null then
    raise exception 'pq.to_parquet_range: relation % has no supported columns', p_parent;
  end if;

  execute format('select count(*) from %s', v_from_sql) into v_num_rows;

  v_body := v_magic;
  for i in 1..v_ncols loop
    v_data := pq._encode_column_data(v_from_sql, v_col_names[i], v_col_pgtypes[i], v_col_nullable[i], v_order_by);
    if p_compress then
      v_page_bytes := pq._gzip_compress(v_data);
      v_page_header := pq._build_page_header(v_num_rows::int4, length(v_data), length(v_page_bytes));
    else
      v_page_bytes := v_data;
      v_page_header := pq._build_page_header(v_num_rows::int4, length(v_data));
    end if;
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_page_bytes;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || pq._build_column_chunk(
        pq._build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset,
          case when p_compress then 2 else 0 end,
          case when p_compress then length(v_page_header) + length(v_page_bytes) else null end));
    v_schema_elements := v_schema_elements || pq._build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i], v_col_nullable[i]);
  end loop;

  v_row_group := pq._build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(pq._build_schema_root(v_ncols), v_schema_elements);
  v_footer := pq._build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  return v_body || v_footer || pq._reverse_bytes(int4send(length(v_footer))) || v_magic;
end;
$$;

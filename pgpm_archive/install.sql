-- =============================================================================
-- pg_partition_magician :: archive  --  archive a managed table's aged
-- partitions to S3 before retention drops them, config-driven.
--
-- OPTIONAL add-on, loaded ON TOP of the core (pgpm_core/install.sql). See
-- README.md in this directory for the front door. pgpm's own core has zero
-- dependency on this schema; nothing here is required for ordinary
-- partitioning.
--
-- Two ways to use it, both reading connection settings (bucket/region/
-- endpoint/prefix/vault key names/compress) from archive.config, the one
-- config surface both share:
--   - The archive_fn strategies (pgpm.archive_to_s3_ndjson / archive_to_s3_parquet,
--     in the pgpm schema, not archive -- they are pgpm_core contract implementations
--     that happen to live in this optional module): set pgpm.config.archive_fn to
--     one of them and pgpm.maintain()'s own byte-budget chunking (pgpm._archive_step,
--     pgpm.archive_ledger) drives archiving automatically, ahead of every drop.
--     This is the normal way to use this module.
--   - The synchronous functions (archive.to_s3 / archive.to_s3_parquet): archive a
--     partition INLINE, called directly, holding the vacuum horizon for the whole
--     read-and-upload. No ledger, no automatic scheduling -- call one yourself
--     before dropping a partition another way.
--
-- The old paced worker (archive.tick(), archive.config's boundary_rule/drop_trigger/
-- format knobs, archive.file_gate, the archive.configure/schedule operator interface,
-- and pgpm.hook, the pre_drop registry it and the synchronous functions used to
-- register through) existed to do by hand what pgpm.maintain()'s archive_fn path now
-- does natively; it was deleted once that path was proven out (issue #240).
--
-- Surface (all in the archive schema, except the archive_fn strategies noted below):
--   archive.config                 per-table connection settings; one row per
--                                  managed table using either path above.
--   archive.to_s3 / archive.to_s3_parquet     the synchronous functions.
--   pgpm.archive_to_s3_ndjson / pgpm.archive_to_s3_parquet   the archive_fn strategies.
-- =============================================================================

create extension if not exists http;
create extension if not exists pgcrypto;
create schema if not exists archive;

-- per-table configuration: one real row per managed table, connection settings only. `create
-- table if not exists` below, mirroring pgpm.config's own idempotent-upgrade shape, so re-running
-- this file is safe.
create table if not exists archive.config (
  parent_table    regclass    primary key,

  -- connection: where this table's archives land
  bucket          text        not null,
  region          text        not null default 'us-east-1',
  endpoint        text,                                    -- null = AWS S3; an
                                                             -- URL for S3-compatible
                                                             -- stores (path prefix
                                                             -- and all)
  prefix          text        not null default 'events/',
  vault_key_id    text        not null default 's3_archive_access_key_id',
  vault_secret    text        not null default 's3_archive_secret_access_key',
  compress        boolean     not null default false,

  -- archive.to_s3's own multipart PUT chunking (the archive_fn strategies don't need this --
  -- pgpm._next_archive_chunk already bounds their read size before they ever run)
  part_bytes      bigint      not null default 8 * 1024 * 1024,
  fetch_rows      int         not null default 20000,

  created_at      timestamptz not null default now()
);
-- the paced worker's knobs and the old archive.ledger's own connection-settings columns are gone
-- (issue #240): boundary_rule/drop_trigger picked which unit to archive and who dropped it,
-- format/byte_budget/probe_sample configured the deleted archive._next_range_byte_budget/
-- archive.archive_range/archive._encode_upload_ndjson_commits. Nothing reads them anymore.
alter table archive.config drop column if exists boundary_rule;
alter table archive.config drop column if exists drop_trigger;
alter table archive.config drop column if exists format;
alter table archive.config drop column if exists byte_budget;
alter table archive.config drop column if exists probe_sample;

-- the old ledger (one row per archived range, written by the paced worker) is gone entirely
-- (issue #240): pgpm.archive_ledger, populated by the archive_fn strategies below via
-- pgpm._archive_step, is its successor.
drop table if exists archive.ledger;

-- ---------------------------------------------------------------------------
-- Key discovery and S3 transport primitives
-- ---------------------------------------------------------------------------

-- key discovery, shared by every reader that has to order a read spanning more than one child's
-- heap (where ctid is no longer comparable): archive._pq_to_parquet_range, the Parquet range
-- reader, calls this. Identical contract to pgpm.regrain_step's own v_keyidx/v_pkjoin discovery: a PRIMARY KEY
-- preferred, else a predicate/expression-free UNIQUE CONSTRAINT, never a bare UNIQUE INDEX
-- unbacked by a constraint. Returns null for a genuinely keyless relation -- the same 'nokey'
-- contract regrain() already enforces, an inherited limitation, not a new gap. (On a partitioned
-- parent, Postgres itself requires any unique constraint to include every partitioning column, so
-- in practice the control column is always already one of the columns this discovers.)
create or replace function archive._key_columns(p_relation regclass) returns name[]
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

-- Multipart variant of the archive.to_s3 pre_drop hook: bounded memory for partitions of any size.
-- Three pieces: a URL-encoder, one shared SigV4 request signer (every S3 call signs the same way),
-- and the hook, which streams the partition in part-sized chunks via keyset pagination.

-- RFC 3986 percent-encoding of everything but the unreserved set, byte-wise (UTF-8), as SigV4 requires.
create or replace function archive.s3_url_encode(p_raw text)
returns text language sql immutable as $$
  select coalesce(string_agg(
    case when b.byte in (45, 46, 95, 126)                    -- - . _ ~
           or b.byte between 48 and 57                       -- 0-9
           or b.byte between 65 and 90                       -- A-Z
           or b.byte between 97 and 122                      -- a-z
         then chr(b.byte)
         else '%' || upper(lpad(to_hex(b.byte), 2, '0')) end, '' order by b.i), '')
  from (select get_byte(convert_to(p_raw, 'UTF8'), i) as byte, i
          from generate_series(0, octet_length(convert_to(p_raw, 'UTF8')) - 1) i) b;
$$;

-- One signed S3 request. p_query must already be the CANONICAL query string (keys sorted,
-- keys and values percent-encoded, '' for none); it is used verbatim in both the signature
-- and the URL, so they cannot drift apart.
create or replace function archive.s3_signed_request(
  p_method text, p_endpoint text, p_bucket text, p_region text,
  p_key text, p_query text, p_ctype text, p_payload text,
  p_key_id text, p_secret text
) returns http_response language plpgsql as $$
declare
  v_host text; v_uri text; v_url text;
  v_amz_date text; v_date text; v_payload_hash text; v_scope text;
  v_signed_headers text := 'content-type;host;x-amz-content-sha256;x-amz-date';
  v_canonical text; v_sts text; v_kbin bytea; v_sig text; v_auth text;
  v_resp http_response;
begin
  if p_endpoint is null then
    v_host := p_bucket || '.s3.' || p_region || '.amazonaws.com';   -- virtual-hosted style
    v_uri  := '/' || p_key;
  else
    -- path style (MinIO, Supabase Storage, et al.); the endpoint may carry a path prefix
    v_host := regexp_replace(p_endpoint, '^https?://([^/]+).*$', '\1');
    v_uri  := regexp_replace(p_endpoint, '^https?://[^/]+', '') || '/' || p_bucket || '/' || p_key;
  end if;
  v_url := case when p_endpoint is null then 'https://' || v_host || v_uri
                else p_endpoint || '/' || p_bucket || '/' || p_key end
        || case when p_query = '' then '' else '?' || p_query end;

  v_amz_date     := to_char(now() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"');
  v_date         := substr(v_amz_date, 1, 8);
  v_payload_hash := encode(digest(convert_to(p_payload, 'UTF8'), 'sha256'), 'hex');
  v_scope        := v_date || '/' || p_region || '/s3/aws4_request';
  v_canonical    := p_method || e'\n' || v_uri || e'\n' || p_query || e'\n'
                 || 'content-type:' || p_ctype || e'\n'
                 || 'host:' || v_host || e'\n'
                 || 'x-amz-content-sha256:' || v_payload_hash || e'\n'
                 || 'x-amz-date:' || v_amz_date || e'\n'
                 || e'\n' || v_signed_headers || e'\n' || v_payload_hash;
  v_sts          := 'AWS4-HMAC-SHA256' || e'\n' || v_amz_date || e'\n' || v_scope || e'\n'
                 || encode(digest(convert_to(v_canonical, 'UTF8'), 'sha256'), 'hex');
  v_kbin := hmac(convert_to(v_date, 'UTF8'),        convert_to('AWS4' || p_secret, 'UTF8'), 'sha256');
  v_kbin := hmac(convert_to(p_region, 'UTF8'),      v_kbin, 'sha256');
  v_kbin := hmac(convert_to('s3', 'UTF8'),          v_kbin, 'sha256');
  v_kbin := hmac(convert_to('aws4_request', 'UTF8'), v_kbin, 'sha256');
  v_sig  := encode(hmac(convert_to(v_sts, 'UTF8'), v_kbin, 'sha256'), 'hex');
  v_auth := 'AWS4-HMAC-SHA256 Credential=' || p_key_id || '/' || v_scope
         || ', SignedHeaders=' || v_signed_headers || ', Signature=' || v_sig;

  perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '300000');   -- default is 5s; size for real parts

  select * into v_resp from http((
    p_method::http_method, v_url,
    array[ http_header('x-amz-date', v_amz_date),
           http_header('x-amz-content-sha256', v_payload_hash),
           http_header('authorization', v_auth) ],
    p_ctype, p_payload)::http_request);
  return v_resp;
end;
$$;

-- ---------------------------------------------------------------------------
-- Transport: a bytea-native SigV4 signer, and the pre_drop hook
-- ---------------------------------------------------------------------------
-- Why a separate signer from archive.s3_signed_request (to-s3.md's multipart
-- variant): that one hashes the payload via digest(convert_to(p_payload, 'UTF8'), 'sha256'),
-- which requires p_payload to be well-formed text in the server encoding. A Parquet file is
-- binary -- its Thrift-encoded footer alone guarantees stray 0x00 and high-bit-set bytes --
-- so convert_to() raises `invalid byte sequence for encoding "UTF8"` on real payloads
-- (verified: it does, on exactly a literal 0x00). This overload hashes the RAW bytea directly
-- (no encoding involved) and only crosses to text at the network boundary, via the http
-- extension's bytea_to_text() -- a raw memcpy reinterpretation of the same bytes, not a
-- re-encode (confirmed from the extension's C source). Verified end-to-end against MinIO:
-- a Parquet payload survives this exact path byte-for-byte and reads back correctly in pyarrow.
create or replace function archive.s3_signed_request_bytea(
  p_method text, p_endpoint text, p_bucket text, p_region text,
  p_key text, p_query text, p_ctype text, p_payload bytea,
  p_key_id text, p_secret text
) returns http_response language plpgsql as $$
declare
  v_host text; v_uri text; v_url text;
  v_amz_date text; v_date text; v_payload_hash text; v_scope text;
  v_signed_headers text := 'content-type;host;x-amz-content-sha256;x-amz-date';
  v_canonical text; v_sts text; v_kbin bytea; v_sig text; v_auth text;
  v_resp http_response;
begin
  if p_endpoint is null then
    v_host := p_bucket || '.s3.' || p_region || '.amazonaws.com';
    v_uri  := '/' || p_key;
  else
    v_host := regexp_replace(p_endpoint, '^https?://([^/]+).*$', '\1');
    v_uri  := regexp_replace(p_endpoint, '^https?://[^/]+', '') || '/' || p_bucket || '/' || p_key;
  end if;
  v_url := case when p_endpoint is null then 'https://' || v_host || v_uri
                else p_endpoint || '/' || p_bucket || '/' || p_key end
        || case when p_query = '' then '' else '?' || p_query end;

  v_amz_date     := to_char(now() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"');
  v_date         := substr(v_amz_date, 1, 8);
  v_payload_hash := encode(digest(p_payload, 'sha256'), 'hex');   -- bytea-native: no encoding involved
  v_scope        := v_date || '/' || p_region || '/s3/aws4_request';
  v_canonical    := p_method || e'\n' || v_uri || e'\n' || p_query || e'\n'
                 || 'content-type:' || p_ctype || e'\n'
                 || 'host:' || v_host || e'\n'
                 || 'x-amz-content-sha256:' || v_payload_hash || e'\n'
                 || 'x-amz-date:' || v_amz_date || e'\n'
                 || e'\n' || v_signed_headers || e'\n' || v_payload_hash;
  v_sts          := 'AWS4-HMAC-SHA256' || e'\n' || v_amz_date || e'\n' || v_scope || e'\n'
                 || encode(digest(convert_to(v_canonical, 'UTF8'), 'sha256'), 'hex');
  v_kbin := hmac(convert_to(v_date, 'UTF8'),        convert_to('AWS4' || p_secret, 'UTF8'), 'sha256');
  v_kbin := hmac(convert_to(p_region, 'UTF8'),      v_kbin, 'sha256');
  v_kbin := hmac(convert_to('s3', 'UTF8'),          v_kbin, 'sha256');
  v_kbin := hmac(convert_to('aws4_request', 'UTF8'), v_kbin, 'sha256');
  v_sig  := encode(hmac(convert_to(v_sts, 'UTF8'), v_kbin, 'sha256'), 'hex');
  v_auth := 'AWS4-HMAC-SHA256 Credential=' || p_key_id || '/' || v_scope
         || ', SignedHeaders=' || v_signed_headers || ', Signature=' || v_sig;

  perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '300000');

  select * into v_resp from http((
    p_method::http_method, v_url,
    array[ http_header('x-amz-date', v_amz_date),
           http_header('x-amz-content-sha256', v_payload_hash),
           http_header('authorization', v_auth) ],
    p_ctype, bytea_to_text(p_payload))::http_request);   -- the one crossing to text, at the wire
  return v_resp;
end;
$$;


-- ---------------------------------------------------------------------------
-- Parquet writer: byte-level primitives, Thrift compact protocol, PLAIN
-- encoding, GZIP compression, struct builders, column-data extraction.
-- Originally built and verified end-to-end (pyarrow + DuckDB) in a standalone
-- prototype before being ported rename-only; that independent-reader
-- verification now runs directly against these functions instead
-- (scripts/verify_parquet.py/verify_parquet_range.py, via ./test.sh archive).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Byte-level primitives
-- ---------------------------------------------------------------------------

create or replace function archive._pq_byte(b int4) returns bytea
language sql immutable as $$
  select set_byte('\x00'::bytea, 0, b);
$$;

create or replace function archive._pq_reverse_bytes(b bytea) returns bytea
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
create or replace function archive._pq_varint(v bigint) returns bytea
language plpgsql immutable as $$
declare
  n bigint := v;
  buf bytea := ''::bytea;
  b int4;
begin
  if n < 0 then
    raise exception 'archive._pq_varint: negative value % not supported', v;
  end if;
  loop
    b := (n & 127)::int4;
    n := n >> 7;
    if n <> 0 then
      buf := buf || archive._pq_byte(b | 128);
    else
      buf := buf || archive._pq_byte(b);
      exit;
    end if;
  end loop;
  return buf;
end;
$$;

create or replace function archive._pq_zigzag(v bigint) returns bigint
language sql immutable as $$
  select case when v >= 0 then v * 2 else (0 - v) * 2 - 1 end;
$$;

-- ---------------------------------------------------------------------------
-- Thrift compact protocol: field headers, typed field writers, lists, structs
-- ---------------------------------------------------------------------------
-- Compact types used here: BOOLEAN_TRUE/FALSE unused (no bool fields in the
-- subset of the spec this writer touches); I32=5 I64=6 BINARY=8 LIST=9 STRUCT=12.

create or replace function archive._pq_field_hdr(p_last_id int4, p_field_id int4, p_ctype int4) returns bytea
language plpgsql immutable as $$
declare
  delta int4 := p_field_id - p_last_id;
begin
  if delta between 1 and 15 then
    return archive._pq_byte((delta << 4) | p_ctype);
  else
    return archive._pq_byte(p_ctype) || archive._pq_varint(archive._pq_zigzag(p_field_id::bigint));
  end if;
end;
$$;

create or replace function archive._pq_stop() returns bytea
language sql immutable as $$
  select archive._pq_byte(0);
$$;

create or replace function archive._pq_write_i32(p_last_id int4, p_field_id int4, p_val int4) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 5) || archive._pq_varint(archive._pq_zigzag(p_val::bigint));
$$;

create or replace function archive._pq_write_i64(p_last_id int4, p_field_id int4, p_val int8) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 6) || archive._pq_varint(archive._pq_zigzag(p_val));
$$;

create or replace function archive._pq_write_binary(p_last_id int4, p_field_id int4, p_val bytea) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 8) || archive._pq_varint(length(p_val)::bigint) || p_val;
$$;

create or replace function archive._pq_write_struct(p_last_id int4, p_field_id int4, p_val bytea) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 12) || p_val;
$$;

create or replace function archive._pq_list_hdr(p_count int4, p_elem_ctype int4) returns bytea
language plpgsql immutable as $$
begin
  if p_count <= 14 then
    return archive._pq_byte((p_count << 4) | p_elem_ctype);
  else
    return archive._pq_byte((15 << 4) | p_elem_ctype) || archive._pq_varint(p_count::bigint);
  end if;
end;
$$;

create or replace function archive._pq_write_list_struct(p_last_id int4, p_field_id int4, p_elems bytea[]) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 9)
      || archive._pq_list_hdr(coalesce(array_length(p_elems,1),0), 12)
      || coalesce((select string_agg(e, ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

create or replace function archive._pq_write_list_i32(p_last_id int4, p_field_id int4, p_elems int4[]) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 9)
      || archive._pq_list_hdr(coalesce(array_length(p_elems,1),0), 5)
      || coalesce((select string_agg(archive._pq_varint(archive._pq_zigzag(e::bigint)), ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

create or replace function archive._pq_write_list_binary(p_last_id int4, p_field_id int4, p_elems bytea[]) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 9)
      || archive._pq_list_hdr(coalesce(array_length(p_elems,1),0), 8)
      || coalesce((select string_agg(archive._pq_varint(length(e)::bigint) || e, ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

-- ---------------------------------------------------------------------------
-- PLAIN encoding (Type physical values; see Encoding.PLAIN doc in the spec)
-- ---------------------------------------------------------------------------

create or replace function archive._pq_plain_int32(v int4) returns bytea
language sql immutable as $$
  select archive._pq_reverse_bytes(int4send(v));
$$;

create or replace function archive._pq_plain_int64(v int8) returns bytea
language sql immutable as $$
  select archive._pq_reverse_bytes(int8send(v));
$$;

create or replace function archive._pq_plain_double(v float8) returns bytea
language sql immutable as $$
  select archive._pq_reverse_bytes(float8send(v));
$$;

create or replace function archive._pq_plain_bytearray(v bytea) returns bytea
language sql immutable as $$
  select archive._pq_reverse_bytes(int4send(length(v))) || v;
$$;

create or replace function archive._pq_plain_text(v text) returns bytea
language sql immutable as $$
  select archive._pq_plain_bytearray(convert_to(v, 'UTF8'));
$$;

create or replace function archive._pq_plain_boolean_array(vals boolean[]) returns bytea
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
-- LSB-first-per-byte packing archive._pq_plain_boolean_array already uses, so this reuses that shape.
create or replace function archive._pq_definition_levels(is_present boolean[]) returns bytea
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
    return archive._pq_reverse_bytes(int4send(0));   -- valid empty hybrid stream: zero-length encoded-data
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
  header := archive._pq_varint(((nbytes::bigint) << 1) | 1);
  encoded_data := header || packed;
  return archive._pq_reverse_bytes(int4send(length(encoded_data))) || encoded_data;
end;
$$;

-- ---------------------------------------------------------------------------
-- Compression: GZIP (RFC 1952) wrapping a from-scratch DEFLATE (RFC 1951)
-- encoder -- LZ77 matching plus a fixed Huffman code. Originally built and
-- verified end-to-end (pyarrow + DuckDB, including cross-partition ranges) in
-- a standalone prototype before being ported rename-only (pq._* ->
-- archive._pq_*); that verification now runs directly against these
-- functions instead (scripts/verify_parquet.py/verify_parquet_range.py).
-- ---------------------------------------------------------------------------

-- CRC-32/ISO-HDLC (the checksum RFC 1952's gzip trailer requires), table-driven.
create or replace function archive._pq_crc32_table() returns bigint[]
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
create or replace function archive._pq_crc32(data bytea) returns bigint
language plpgsql as $$
declare
  tbl bigint[] := archive._pq_crc32_table();
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
create or replace function archive._pq_lz_pos_hashes(data bytea) returns table(pos int4, h int4)
language sql immutable as $$
  select i, (get_byte(data,i)<<16) | (get_byte(data,i+1)<<8) | get_byte(data,i+2)
  from generate_series(0, length(data)-3) i;
$$;

-- longest k in [0, max_len] with substr(data,a+1,k) = substr(data,b+1,k): a binary search over
-- native substr-equality comparisons (each a C-level memcmp regardless of k), not a byte-by-byte
-- extend loop -- O(log max_len) comparisons instead of O(max_len).
create or replace function archive._pq_lz_match_len(data bytea, a int4, b int4, max_len int4) returns int4
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
-- bits here), not once per output bit -- see archive._pq_deflate_encode. Distinct from
-- archive._pq_reverse_bytes above (byte-order reversal, not bit-within-a-value reversal).
create or replace function archive._pq_bit_reverse(value int4, nbits int4) returns int4
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
create or replace function archive._pq_deflate_encode(payload bytea) returns bytea
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
  create temp table pq_deflate_hash_scratch as select * from archive._pq_lz_pos_hashes(payload);
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
      v_mlen := archive._pq_lz_match_len(payload, v_pos, v_candidate, least(258, n - v_pos));
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
      v_rev := archive._pq_bit_reverse(v_code, v_nbits);
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
      v_rev := archive._pq_bit_reverse(v_dcode, 5);
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
      v_rev := archive._pq_bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop
        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
      end loop;
      v_pos := v_pos + 1;
    end if;
  end loop;

  -- end-of-block (symbol 256): 7-bit code, value 0
  v_rev := archive._pq_bit_reverse(0, 7);
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
create or replace function archive._pq_gzip_compress(payload bytea) returns bytea
language plpgsql as $$
declare
  v_deflate bytea := archive._pq_deflate_encode(payload);
  v_header bytea := decode('1f8b08000000000000ff', 'hex');
  v_crc bigint := archive._pq_crc32(payload);
  v_isize bigint := length(payload) & 4294967295;
  v_trailer bytea;
begin
  v_trailer := archive._pq_reverse_bytes(int4send((v_crc - 4294967296 * (v_crc >> 31))::int4))
            || archive._pq_reverse_bytes(int4send((v_isize - 4294967296 * (v_isize >> 31))::int4));
  return v_header || v_deflate || v_trailer;
end;
$$;

-- ---------------------------------------------------------------------------
-- Dynamic Huffman coding (issue #206), step 1 of 2: canonical code lengths and
-- code assignment (RFC 1951 3.2.2). archive._pq_gzip_compress above (fixed-Huffman)
-- stays defined and directly callable -- a valid, simpler, slightly cheaper-to-run
-- rung, kept rather than deleted -- but every GZIP call site this module drives on
-- its own (archive._pq_to_parquet, archive._pq_to_parquet_range,
-- archive._encode_upload_ndjson_single) now calls archive._pq_gzip_compress_dynamic
-- (below) instead: a pre-build measurement (reimplementing this project's own LZ77
-- matcher, cross-checked against real zlib's Z_FIXED vs default strategy) put the
-- expected win at ~20-30% additional size reduction over fixed Huffman on realistic
-- PLAIN-encoded column data, confirmed end to end afterward (both pyarrow and DuckDB
-- reading real compressed Parquet files, 24-35% smaller in the cases measured) --
-- strictly better compression for a modest extra cost building the per-block tree,
-- with no config surface added and nothing for an operator to opt into.
-- ---------------------------------------------------------------------------

-- Standard Huffman code-length construction, then length-limited to p_max_bits
-- (DEFLATE's own cap is 15). p_freqs is a 1-based array indexed by symbol+1
-- (i.e. p_freqs[i] is symbol i-1's frequency); returns an array of the same
-- shape, 0 for any symbol with zero frequency (unused, no code assigned).
--
-- Construction: repeatedly merge the two lowest-frequency groups (ties broken
-- by insertion order, ascending); every symbol in EITHER merged group gets +1
-- code length per merge -- one more bit to distinguish left vs right below it.
-- This reads code lengths straight off the merge sequence without building an
-- explicit tree.
--
-- Length limiting: clamp any length exceeding p_max_bits down to it (folding the
-- overflow into a bit-length histogram, bl_count[L] = how many symbols have
-- length L), then repeatedly repair the histogram -- move one leaf from the
-- shortest length still below the cap down to length+1 (which needs a new
-- sibling to stay a valid full binary tree, so that bucket gains TWO, not
-- one) and consume one unit of the max_bits overflow -- until total weight
-- (sum of bl_count[L] * 2^(p_max_bits-L), exact integer arithmetic throughout,
-- no floating point) lands EXACTLY on 2^p_max_bits. Finally reassigns actual
-- per-symbol lengths from the repaired histogram, longest-original-length
-- symbols first, so a symbol the unbounded tree considered rarer never ends
-- up shorter than one it considered more common.
--
-- This always terminates and always succeeds for any alphabet size <=
-- 2^p_max_bits (true here with room to spare: DEFLATE's litlen/dist alphabets
-- are 286/30 symbols against a 15-bit cap), since assigning every symbol
-- p_max_bits alone already satisfies Kraft with room left over. Landing on
-- an EXACTLY complete code (not just Kraft <= 1) matters in practice, not
-- just in theory: real DEFLATE decoders (confirmed against real zlib) reject
-- an incomplete multi-symbol code outright -- an earlier version of this
-- function used a floating-point Kraft comparison and a "lengthen the
-- shortest code" loop that could silently converge to an INCOMPLETE code
-- (there is no guarantee that repeatedly halving one term lands exactly on
-- the target rather than overshooting past it), and zlib's own decompressor
-- caught it immediately on real column data (a float8 price column) with
-- "invalid code lengths set" -- the bug this histogram-based repair fixes.
-- Verified against a 27-symbol Fibonacci-weighted worst case, the classic
-- adversarial input for unbounded Huffman (unbounded construction hits depth
-- 26 for 27 symbols; the length-limited pass correctly caps it to 15 with an
-- exactly complete code), and 2000+ randomized trials across uniform,
-- geometric, spiky, and Fibonacci frequency shapes at both real DEFLATE
-- alphabet sizes (286, 30) and smaller ones, all landing on an exactly
-- complete code within the requested cap.
create or replace function archive._pq_huffman_lengths(p_freqs bigint[], p_max_bits int default 15)
returns int4[]
language plpgsql as $$
declare
  n int4 := array_length(p_freqs, 1);
  v_lengths int4[] := array_fill(0, array[n]);
  i int4;
  v_node_id int4 := 0;
  v_ncount int4;
  v_id1 int4; v_id2 int4;
  v_f1 bigint; v_f2 bigint;
  v_m1 int4[]; v_m2 int4[];
  v_sym int4;
  v_max_len int4;
  v_bl_count int4[];
  v_overflow int4;
  v_bits int4;
  v_weight bigint;
  v_target bigint;
  v_order int4[];
  v_new_lengths int4[];
  v_idx int4;
  v_l int4;
begin
  create temp table archive_huff_groups (node_id int4 primary key, freq bigint, members int4[])
    on commit drop;

  for i in 1..n loop
    if p_freqs[i] > 0 then
      v_node_id := v_node_id + 1;
      insert into archive_huff_groups values (v_node_id, p_freqs[i], array[i]);
    end if;
  end loop;

  select count(*) into v_ncount from archive_huff_groups;

  -- a length-limited prefix code for v_ncount symbols can only ever exist if
  -- v_ncount <= 2^p_max_bits (Kraft's inequality's own ceiling: v_ncount codes of
  -- exactly p_max_bits each already sum to v_ncount * 2^-p_max_bits, which must be
  -- <= 1). Never reachable from a real DEFLATE call (max_bits is always 15 there,
  -- alphabets max out at 286) -- guarded so a misuse fails loudly instead of
  -- infinite-looping in the Kraft-restore pass below.
  if v_ncount > power(2, p_max_bits)::bigint then
    raise exception 'archive._pq_huffman_lengths: % distinct symbols cannot fit a %-bit-limited prefix code (needs <= % symbols)',
      v_ncount, p_max_bits, power(2, p_max_bits)::bigint;
  end if;

  if v_ncount = 0 then
    drop table archive_huff_groups;
    return v_lengths;
  end if;

  if v_ncount = 1 then
    select members into v_m1 from archive_huff_groups;
    v_lengths[v_m1[1]] := 1;
    drop table archive_huff_groups;
    return v_lengths;
  end if;

  while v_ncount > 1 loop
    select node_id, freq, members into v_id1, v_f1, v_m1
      from archive_huff_groups order by freq, node_id limit 1;
    select node_id, freq, members into v_id2, v_f2, v_m2
      from archive_huff_groups where node_id <> v_id1 order by freq, node_id limit 1;

    foreach v_sym in array v_m1 loop
      v_lengths[v_sym] := v_lengths[v_sym] + 1;
    end loop;
    foreach v_sym in array v_m2 loop
      v_lengths[v_sym] := v_lengths[v_sym] + 1;
    end loop;

    delete from archive_huff_groups where node_id in (v_id1, v_id2);
    v_node_id := v_node_id + 1;
    insert into archive_huff_groups values (v_node_id, v_f1 + v_f2, v_m1 || v_m2);

    select count(*) into v_ncount from archive_huff_groups;
  end loop;

  drop table archive_huff_groups;

  -- v_lengths now holds the UNBOUNDED assignment (always exactly complete: Kraft
  -- == 1 exactly, guaranteed by the merge construction above). Length-limit it.
  select max(v_lengths[gs]) into v_max_len from generate_series(1, n) gs;

  v_bl_count := array_fill(0, array[greatest(v_max_len, p_max_bits)]);
  for i in 1..n loop
    if v_lengths[i] > 0 then
      v_bl_count[v_lengths[i]] := v_bl_count[v_lengths[i]] + 1;
    end if;
  end loop;

  v_overflow := 0;
  for v_l in (p_max_bits + 1)..greatest(v_max_len, p_max_bits) loop
    v_overflow := v_overflow + v_bl_count[v_l];
  end loop;
  v_bl_count := v_bl_count[1:p_max_bits];
  v_bl_count[p_max_bits] := v_bl_count[p_max_bits] + v_overflow;

  v_target := power(2, p_max_bits)::bigint;
  v_weight := 0;
  for v_l in 1..p_max_bits loop
    v_weight := v_weight + v_bl_count[v_l]::bigint * power(2, p_max_bits - v_l)::bigint;
  end loop;

  while v_weight > v_target loop
    v_bits := p_max_bits - 1;
    while v_bl_count[v_bits] = 0 loop
      v_bits := v_bits - 1;
    end loop;
    v_bl_count[v_bits] := v_bl_count[v_bits] - 1;
    v_bl_count[v_bits + 1] := v_bl_count[v_bits + 1] + 2;
    v_bl_count[p_max_bits] := v_bl_count[p_max_bits] - 1;
    v_weight := v_weight - 1;
  end loop;

  -- reassign: symbols with the longest ORIGINAL (unbounded) length get the
  -- longest final length, and so on down, preserving the unbounded tree's
  -- relative ordering.
  select array_agg(gs order by v_lengths[gs] desc, gs) into v_order
    from generate_series(1, n) gs where v_lengths[gs] > 0;

  v_new_lengths := array_fill(0, array[n]);
  v_idx := 1;
  for v_l in reverse p_max_bits..1 loop
    for i in 1..v_bl_count[v_l] loop
      v_new_lengths[v_order[v_idx]] := v_l;
      v_idx := v_idx + 1;
    end loop;
  end loop;

  return v_new_lengths;
end;
$$;

-- Canonical code assignment from code lengths (RFC 1951 3.2.2): sort symbols by
-- (length, symbol value), assign codes starting at 0, incrementing by 1 within
-- a length and shifting left by 1 (i.e. *= 2) whenever the length grows. p_lengths
-- is the same 1-based, symbol-i-1-at-index-i shape archive._pq_huffman_lengths returns;
-- 0 means "unused". Returns the assigned code VALUE per symbol (not yet bit-
-- reversed for the wire -- Huffman codes are MSB-first, same convention
-- archive._pq_bit_reverse already exists to flip, reused unchanged when this gets wired
-- into a block encoder).
create or replace function archive._pq_canonical_codes(p_lengths int4[]) returns int4[]
language plpgsql as $$
declare
  n int4 := array_length(p_lengths, 1);
  v_codes int4[] := array_fill(0, array[n]);
  v_order int4[];
  v_code int4 := 0;
  v_prev_len int4 := 0;
  v_sym int4;
begin
  select array_agg(gs order by p_lengths[gs], gs) into v_order
    from generate_series(1, n) gs where p_lengths[gs] > 0;

  if v_order is null then
    return v_codes;
  end if;

  foreach v_sym in array v_order loop
    v_code := v_code << (p_lengths[v_sym] - v_prev_len);
    v_codes[v_sym] := v_code;
    v_code := v_code + 1;
    v_prev_len := p_lengths[v_sym];
  end loop;

  return v_codes;
end;
$$;

-- ---------------------------------------------------------------------------
-- Dynamic Huffman coding (issue #206), step 2 of 2: the full BTYPE=10 block
-- encoder. Factors the LZ77 matcher out of archive._pq_deflate_encode into its own
-- function (archive._pq_deflate_encode itself is untouched, still fixed-Huffman-only
-- -- a valid, simpler rung, not replaced) so both encoders share one matching
-- implementation rather than risking a second, subtly different copy.
-- ---------------------------------------------------------------------------

-- Same matching algorithm as archive._pq_deflate_encode's inline loop (single most-
-- recent candidate per 3-byte hash, precomputed over the whole buffer via
-- archive._pq_lz_pos_hashes, greedy, window 32768, max match 258) -- factored out so
-- archive._pq_deflate_encode_dynamic below can reuse it verbatim. Returns one row per
-- token in stream order: literal (is_match=false, val1=byte 0-255) or match
-- (is_match=true, val1=length, val2=distance).
create or replace function archive._pq_lz77_tokens(payload bytea)
returns table(is_match boolean, val1 int4, val2 int4)
language plpgsql as $$
declare
  n int4 := length(payload);
  v_pos int4 := 0;
  v_hash int4; v_candidate int4; v_mlen int4;
begin
  drop table if exists archive_lz77_hash_scratch;
  create temp table archive_lz77_hash_scratch as select * from archive._pq_lz_pos_hashes(payload);
  create index on archive_lz77_hash_scratch (h, pos);

  while v_pos < n loop
    v_candidate := null;
    if v_pos <= n - 3 then
      v_hash := (get_byte(payload,v_pos)<<16) | (get_byte(payload,v_pos+1)<<8) | get_byte(payload,v_pos+2);
      select pos into v_candidate from archive_lz77_hash_scratch
       where h = v_hash and pos < v_pos and v_pos - pos <= 32768
       order by pos desc limit 1;
    end if;
    if v_candidate is not null then
      v_mlen := archive._pq_lz_match_len(payload, v_pos, v_candidate, least(258, n - v_pos));
    else
      v_mlen := 0;
    end if;

    if v_mlen >= 3 then
      is_match := true; val1 := v_mlen; val2 := v_pos - v_candidate;
      return next;
      v_pos := v_pos + v_mlen;
    else
      is_match := false; val1 := get_byte(payload, v_pos); val2 := null;
      return next;
      v_pos := v_pos + 1;
    end if;
  end loop;

  drop table archive_lz77_hash_scratch;
  return;
end;
$$;

-- RFC 1951 3.2.7's code-length meta-alphabet: RLE-encodes p_lengths (the
-- combined litlen-then-dist code-length sequence a dynamic block transmits)
-- into a token stream over the 19-symbol code-length alphabet -- 0-15 mean
-- "this next code has length N" literally; 16 repeats the PREVIOUS length
-- 3-6 more times (2 extra bits); 17 repeats a zero length 3-10 times (3 extra
-- bits); 18 repeats a zero length 11-138 times (7 extra bits). Standard greedy
-- strategy: prefer the longest applicable repeat code for each run, falling
-- back to literal symbols for runs of 1-2 (too short for any repeat code) --
-- the DEFLATE format doesn't mandate a specific encoder strategy here, only
-- that the decoder can interpret whatever choices were made, so greedy is a
-- legal, simple choice.
create or replace function archive._pq_clc_rle(p_lengths int4[])
returns table(sym int4, extra_val int4, extra_bits int4)
language plpgsql as $$
declare
  n int4 := array_length(p_lengths, 1);
  i int4 := 1;
  v_val int4;
  v_run int4;
  v_j int4;
  v_take int4;
begin
  while i <= n loop
    v_val := p_lengths[i];
    v_j := i + 1;
    while v_j <= n and p_lengths[v_j] = v_val loop
      v_j := v_j + 1;
    end loop;
    v_run := v_j - i;

    if v_val = 0 then
      while v_run > 0 loop
        if v_run >= 11 then
          v_take := least(v_run, 138);
          sym := 18; extra_val := v_take - 11; extra_bits := 7;
        elsif v_run >= 3 then
          v_take := least(v_run, 10);
          sym := 17; extra_val := v_take - 3; extra_bits := 3;
        else
          v_take := 1;
          sym := 0; extra_val := 0; extra_bits := 0;
        end if;
        return next;
        v_run := v_run - v_take;
      end loop;
    else
      sym := v_val; extra_val := 0; extra_bits := 0;
      return next;
      v_run := v_run - 1;
      while v_run > 0 loop
        if v_run >= 3 then
          v_take := least(v_run, 6);
          sym := 16; extra_val := v_take - 3; extra_bits := 2;
        else
          v_take := 1;
          sym := v_val; extra_val := 0; extra_bits := 0;
        end if;
        return next;
        v_run := v_run - v_take;
      end loop;
    end if;

    i := v_j;
  end loop;
  return;
end;
$$;

-- The full dynamic-Huffman (BTYPE=10) block encoder: tokenizes via
-- archive._pq_lz77_tokens (pass 1, also tallying the real litlen/distance symbol
-- frequencies), builds a genuine per-block Huffman code for each alphabet
-- (archive._pq_huffman_lengths/_canonical_codes -- pass 2), transmits both via the
-- code-length meta-alphabet (archive._pq_clc_rle, Huffman-coded the same way), then
-- emits the actual token stream under the new codes (pass 3). Same bit-
-- accumulator convention as archive._pq_deflate_encode (LSB-first byte packing,
-- Huffman codes bit-reversed via archive._pq_bit_reverse before packing since they're
-- conventionally written MSB-first, raw fields/extra-bits pushed unreversed).
create or replace function archive._pq_deflate_encode_dynamic(payload bytea) returns bytea
language plpgsql as $$
declare
  v_tok record;
  v_k int4 := 0;
  v_litlen_sym int4[] := '{}';
  v_litlen_extra_val int4[] := '{}';
  v_litlen_extra_bits int4[] := '{}';
  v_dist_sym int4[] := '{}';
  v_dist_extra_val int4[] := '{}';
  v_dist_extra_bits int4[] := '{}';

  v_litlen_freq bigint[] := array_fill(0::bigint, array[286]);
  v_dist_freq bigint[] := array_fill(0::bigint, array[30]);

  v_litlen_lengths int4[]; v_litlen_codes int4[];
  v_dist_lengths int4[]; v_dist_codes int4[];

  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;
  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;
  v_len int4; v_dist int4;

  v_acc int4 := 0; v_acc_n int4 := 0; v_bytes int4[] := '{}';

  v_combined_lengths int4[];
  v_litlen_hi int4; v_dist_hi int4;
  v_hlit int4; v_hdist int4;
  v_clc_sym int4[] := '{}'; v_clc_extra_val int4[] := '{}'; v_clc_extra_bits int4[] := '{}';
  v_clc_freq bigint[] := array_fill(0::bigint, array[19]);
  v_clc_lengths int4[]; v_clc_codes int4[];
  v_clc_order int4[] := array[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
  v_hclen int4;
  i int4; v_sym int4; v_code int4; v_nbits int4; v_rev int4;
begin
  -- ---- pass 1: tokenize, tally frequencies ----
  for v_tok in select * from archive._pq_lz77_tokens(payload) loop
    v_k := v_k + 1;
    if v_tok.is_match then
      v_len := v_tok.val1; v_dist := v_tok.val2;

      case
        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;
        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;
        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;
        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;
        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;
        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;
        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;
      end case;

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

      v_litlen_sym[v_k] := v_lcode; v_litlen_extra_val[v_k] := v_lextra_val; v_litlen_extra_bits[v_k] := v_lextra_bits;
      v_dist_sym[v_k] := v_dcode; v_dist_extra_val[v_k] := v_dextra_val; v_dist_extra_bits[v_k] := v_dextra_bits;

      v_litlen_freq[v_lcode+1] := v_litlen_freq[v_lcode+1] + 1;
      v_dist_freq[v_dcode+1] := v_dist_freq[v_dcode+1] + 1;
    else
      v_litlen_sym[v_k] := v_tok.val1; v_litlen_extra_val[v_k] := 0; v_litlen_extra_bits[v_k] := 0;
      v_dist_sym[v_k] := null;

      v_litlen_freq[v_tok.val1+1] := v_litlen_freq[v_tok.val1+1] + 1;
    end if;
  end loop;

  v_litlen_freq[257] := v_litlen_freq[257] + 1;   -- symbol 256 (end-of-block), always present

  if (select count(*) from unnest(v_dist_freq) f where f > 0) = 0 then
    v_dist_freq[1] := 1;   -- RFC 1951 requires >=1 distance code even with zero matches
  end if;

  -- ---- pass 2: the real per-block Huffman codes ----
  v_litlen_lengths := archive._pq_huffman_lengths(v_litlen_freq, 15);
  v_litlen_codes := archive._pq_canonical_codes(v_litlen_lengths);
  v_dist_lengths := archive._pq_huffman_lengths(v_dist_freq, 15);
  v_dist_codes := archive._pq_canonical_codes(v_dist_lengths);

  -- meta-alphabet: RLE the combined length sequence, then Huffman-code THAT
  select max(gs) into v_litlen_hi from generate_series(1,286) gs where v_litlen_lengths[gs] > 0;
  if v_litlen_hi < 257 then v_litlen_hi := 257; end if;
  select max(gs) into v_dist_hi from generate_series(1,30) gs where v_dist_lengths[gs] > 0;
  if v_dist_hi is null then v_dist_hi := 1; end if;

  v_hlit := v_litlen_hi - 257;
  v_hdist := v_dist_hi - 1;

  v_combined_lengths := v_litlen_lengths[1:v_litlen_hi] || v_dist_lengths[1:v_dist_hi];

  for v_tok in select * from archive._pq_clc_rle(v_combined_lengths) loop
    v_clc_sym := array_append(v_clc_sym, v_tok.sym);
    v_clc_extra_val := array_append(v_clc_extra_val, v_tok.extra_val);
    v_clc_extra_bits := array_append(v_clc_extra_bits, v_tok.extra_bits);
    v_clc_freq[v_tok.sym+1] := v_clc_freq[v_tok.sym+1] + 1;
  end loop;

  v_clc_lengths := archive._pq_huffman_lengths(v_clc_freq, 7);
  v_clc_codes := archive._pq_canonical_codes(v_clc_lengths);

  v_hclen := 19;
  while v_hclen > 4 and v_clc_lengths[v_clc_order[v_hclen]+1] = 0 loop
    v_hclen := v_hclen - 1;
  end loop;

  -- ---- pass 3: emit bits ----
  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BFINAL=1
  v_acc := v_acc | (0 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE low bit
  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE high bit (=10, dynamic)
  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;

  v_acc := v_acc | (v_hlit << v_acc_n); v_acc_n := v_acc_n + 5;
  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;
  v_acc := v_acc | (v_hdist << v_acc_n); v_acc_n := v_acc_n + 5;
  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;
  v_acc := v_acc | ((v_hclen - 4) << v_acc_n); v_acc_n := v_acc_n + 4;
  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;

  for i in 1..v_hclen loop
    v_acc := v_acc | (v_clc_lengths[v_clc_order[i]+1] << v_acc_n); v_acc_n := v_acc_n + 3;
    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;
  end loop;

  for i in 1..array_length(v_clc_sym, 1) loop
    v_sym := v_clc_sym[i];
    v_nbits := v_clc_lengths[v_sym+1];
    v_code := v_clc_codes[v_sym+1];
    v_rev := archive._pq_bit_reverse(v_code, v_nbits);
    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;

    if v_clc_extra_bits[i] > 0 then
      v_acc := v_acc | (v_clc_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_clc_extra_bits[i];
      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;
    end if;
  end loop;

  for i in 1..v_k loop
    v_sym := v_litlen_sym[i];
    v_nbits := v_litlen_lengths[v_sym+1];
    v_code := v_litlen_codes[v_sym+1];
    v_rev := archive._pq_bit_reverse(v_code, v_nbits);
    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;

    if v_litlen_extra_bits[i] > 0 then
      v_acc := v_acc | (v_litlen_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_litlen_extra_bits[i];
      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;
    end if;

    if v_dist_sym[i] is not null then
      v_sym := v_dist_sym[i];
      v_nbits := v_dist_lengths[v_sym+1];
      v_code := v_dist_codes[v_sym+1];
      v_rev := archive._pq_bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;

      if v_dist_extra_bits[i] > 0 then
        v_acc := v_acc | (v_dist_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_dist_extra_bits[i];
        while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;
      end if;
    end if;
  end loop;

  -- end-of-block symbol (256), dynamic code
  v_nbits := v_litlen_lengths[257];
  v_code := v_litlen_codes[257];
  v_rev := archive._pq_bit_reverse(v_code, v_nbits);
  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;

  if v_acc_n > 0 then v_bytes := array_append(v_bytes, v_acc & 255); end if;

  return (select decode(string_agg(lpad(to_hex(x), 2, '0'), '' order by ord), 'hex')
          from unnest(v_bytes) with ordinality as t(x, ord));
end;
$$;

-- Same RFC 1952 gzip container as archive._pq_gzip_compress, wrapping the dynamic-Huffman
-- encoder instead of the fixed one.
create or replace function archive._pq_gzip_compress_dynamic(payload bytea) returns bytea
language plpgsql as $$
declare
  v_deflate bytea := archive._pq_deflate_encode_dynamic(payload);
  v_header bytea := decode('1f8b08000000000000ff', 'hex');
  v_crc bigint := archive._pq_crc32(payload);
  v_isize bigint := length(payload) & 4294967295;
  v_trailer bytea;
begin
  v_trailer := archive._pq_reverse_bytes(int4send((v_crc - 4294967296 * (v_crc >> 31))::int4))
            || archive._pq_reverse_bytes(int4send((v_isize - 4294967296 * (v_isize >> 31))::int4));
  return v_header || v_deflate || v_trailer;
end;
$$;

-- ---------------------------------------------------------------------------
-- Struct builders (SchemaElement / DataPageHeader / PageHeader /
-- ColumnMetaData / ColumnChunk / RowGroup / FileMetaData)
-- ---------------------------------------------------------------------------

create or replace function archive._pq_build_schema_root(p_num_children int4) returns bytea
language sql immutable as $$
  select archive._pq_write_binary(0, 4, convert_to('root', 'UTF8'))
      || archive._pq_write_i32(4, 5, p_num_children)
      || archive._pq_stop();
$$;

-- p_converted: parquet ConvertedType code, or -1 for "none"
create or replace function archive._pq_build_schema_leaf(p_name text, p_ptype int4, p_converted int4, p_nullable boolean) returns bytea
language plpgsql immutable as $$
declare
  buf bytea;
begin
  buf := archive._pq_write_i32(0, 1, p_ptype);                                     -- type
  buf := buf || archive._pq_write_i32(1, 3, case when p_nullable then 1 else 0 end); -- repetition_type
  buf := buf || archive._pq_write_binary(3, 4, convert_to(p_name, 'UTF8'));        -- name
  if p_converted >= 0 then
    buf := buf || archive._pq_write_i32(4, 6, p_converted);                       -- converted_type
  end if;
  buf := buf || archive._pq_stop();
  return buf;
end;
$$;

create or replace function archive._pq_build_data_page_header(p_num_values int4) returns bytea
language sql immutable as $$
  select archive._pq_write_i32(0, 1, p_num_values)      -- num_values
      || archive._pq_write_i32(1, 2, 0)                 -- encoding = PLAIN
      || archive._pq_write_i32(2, 3, 3)                  -- definition_level_encoding = RLE
      || archive._pq_write_i32(3, 4, 3)                  -- repetition_level_encoding = RLE
      || archive._pq_stop();
$$;

-- p_compressed_len defaults to p_uncompressed_len (codec = UNCOMPRESSED, the existing
-- behavior unchanged); pass a smaller value when the page bytes going into the file are
-- actually archive._pq_gzip_compress_dynamic(...) output rather than the raw encoded bytes.
create or replace function archive._pq_build_page_header(p_num_values int4, p_uncompressed_len int4, p_compressed_len int4 default null) returns bytea
language plpgsql immutable as $$
declare
  dph bytea := archive._pq_build_data_page_header(p_num_values);
  v_compressed_len int4 := coalesce(p_compressed_len, p_uncompressed_len);
  buf bytea;
begin
  buf := archive._pq_write_i32(0, 1, 0);                        -- type = DATA_PAGE
  buf := buf || archive._pq_write_i32(1, 2, p_uncompressed_len); -- uncompressed_page_size
  buf := buf || archive._pq_write_i32(2, 3, v_compressed_len);   -- compressed_page_size
  buf := buf || archive._pq_write_struct(3, 5, dph);             -- data_page_header
  buf := buf || archive._pq_stop();
  return buf;
end;
$$;

-- p_codec: 0 = UNCOMPRESSED (default, existing behavior), 2 = GZIP. p_total_compressed
-- defaults to p_total_uncompressed for the UNCOMPRESSED case.
create or replace function archive._pq_build_column_metadata(
    p_ptype int4, p_colname text, p_num_values bigint,
    p_total_uncompressed bigint, p_data_page_offset bigint,
    p_codec int4 default 0, p_total_compressed bigint default null
) returns bytea
language plpgsql immutable as $$
declare
  v_total_compressed bigint := coalesce(p_total_compressed, p_total_uncompressed);
  buf bytea;
begin
  buf := archive._pq_write_i32(0, 1, p_ptype);                                              -- type
  buf := buf || archive._pq_write_list_i32(1, 2, array[0]);                                 -- encodings = [PLAIN]
  buf := buf || archive._pq_write_list_binary(2, 3, array[convert_to(p_colname,'UTF8')]);   -- path_in_schema
  buf := buf || archive._pq_write_i32(3, 4, p_codec);                                       -- codec
  buf := buf || archive._pq_write_i64(4, 5, p_num_values);                                  -- num_values
  buf := buf || archive._pq_write_i64(5, 6, p_total_uncompressed);                          -- total_uncompressed_size
  buf := buf || archive._pq_write_i64(6, 7, v_total_compressed);                            -- total_compressed_size
  buf := buf || archive._pq_write_i64(7, 9, p_data_page_offset);                            -- data_page_offset
  buf := buf || archive._pq_stop();
  return buf;
end;
$$;

create or replace function archive._pq_build_column_chunk(p_metadata bytea) returns bytea
language sql immutable as $$
  select archive._pq_write_i64(0, 2, 0)              -- file_offset (deprecated, 0)
      || archive._pq_write_struct(2, 3, p_metadata)  -- meta_data
      || archive._pq_stop();
$$;

create or replace function archive._pq_build_row_group(p_chunks bytea[], p_total_bytes bigint, p_num_rows bigint) returns bytea
language sql immutable as $$
  select archive._pq_write_list_struct(0, 1, p_chunks)      -- columns
      || archive._pq_write_i64(1, 2, p_total_bytes)         -- total_byte_size
      || archive._pq_write_i64(2, 3, p_num_rows)            -- num_rows
      || archive._pq_stop();
$$;

create or replace function archive._pq_build_file_metadata(p_schema bytea[], p_num_rows bigint, p_row_groups bytea[]) returns bytea
language sql immutable as $$
  select archive._pq_write_i32(0, 1, 1)                                                       -- version
      || archive._pq_write_list_struct(1, 2, p_schema)                                        -- schema
      || archive._pq_write_i64(2, 3, p_num_rows)                                               -- num_rows
      || archive._pq_write_list_struct(3, 4, p_row_groups)                                     -- row_groups
      || archive._pq_write_binary(4, 6, convert_to('pg_partition_magician parquet prototype', 'UTF8')) -- created_by
      || archive._pq_stop();
$$;

-- ---------------------------------------------------------------------------
-- Column data extraction (server-side aggregation, ctid-ordered by default so
-- every column's array lines up on the same row order)
-- ---------------------------------------------------------------------------

-- p_nullable columns interleave nulls with real values (array_agg preserves NULLs in
-- position, so this is a single ordered pass either way); is_present[i] tracks which
-- rows had a value so the OPTIONAL path can prepend a definition-levels bitmap, while the
-- values-only payload always contains just the non-null values, in row order. For a NOT
-- NULL column every element is guaranteed non-null (Postgres enforces that at the table
-- level), so this collapses to the old unconditional-encode behavior byte-for-byte; only
-- p_nullable decides whether the definition-levels block gets prepended at all.
--
-- p_order_by defaults to 'ctid' (this function's original, whole-relation ordering,
-- unchanged byte-for-byte); docs/chunked-parquet.md's cross-partition range reader
-- passes an explicit '(control column, key columns)' order-by instead, since ctid is not
-- comparable once a read spans more than one child's heap. This one definition serves both
-- callers -- it is deliberately NOT redeclared with a different parameter list anywhere
-- else, since Postgres overload resolution is keyed on the parameter type list (not names or
-- defaults): a second, differently-aritied "replacement" would coexist as a distinct
-- overload rather than actually replacing this one, and a 4-arg call would become ambiguous
-- between the two (see #209).
create or replace function archive._pq_encode_column_data(p_from_sql text, p_col text, p_pgtype text, p_nullable boolean, p_order_by text default 'ctid') returns bytea
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
      if arr_i4[i] is not null then values_payload := values_payload || archive._pq_plain_int32(arr_i4[i]); end if;
    end loop;
  elsif p_pgtype = 'int8' then
    execute format('select array_agg(%I::int8 order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_i8;
    n := coalesce(array_length(arr_i8,1),0);
    for i in 1..n loop
      is_present[i] := (arr_i8[i] is not null);
      if arr_i8[i] is not null then values_payload := values_payload || archive._pq_plain_int64(arr_i8[i]); end if;
    end loop;
  elsif p_pgtype = 'float8' then
    execute format('select array_agg(%I::float8 order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_f8;
    n := coalesce(array_length(arr_f8,1),0);
    for i in 1..n loop
      is_present[i] := (arr_f8[i] is not null);
      if arr_f8[i] is not null then values_payload := values_payload || archive._pq_plain_double(arr_f8[i]); end if;
    end loop;
  elsif p_pgtype = 'bool' then
    execute format('select array_agg(%I::boolean order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_bool;
    n := coalesce(array_length(arr_bool,1),0);
    for i in 1..n loop
      is_present[i] := (arr_bool[i] is not null);
      if arr_bool[i] is not null then present_bools := present_bools || arr_bool[i]; end if;
    end loop;
    values_payload := archive._pq_plain_boolean_array(present_bools);
  elsif p_pgtype = 'text' then
    execute format('select array_agg(%I::text order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_text;
    n := coalesce(array_length(arr_text,1),0);
    for i in 1..n loop
      is_present[i] := (arr_text[i] is not null);
      if arr_text[i] is not null then values_payload := values_payload || archive._pq_plain_text(arr_text[i]); end if;
    end loop;
  elsif p_pgtype in ('timestamptz','timestamp') then
    execute format('select array_agg(%I::timestamptz order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_ts;
    n := coalesce(array_length(arr_ts,1),0);
    for i in 1..n loop
      is_present[i] := (arr_ts[i] is not null);
      if arr_ts[i] is not null then
        values_payload := values_payload || archive._pq_plain_int64(round(extract(epoch from arr_ts[i]) * 1000000)::int8);
      end if;
    end loop;
  else
    raise exception 'archive._pq_encode_column_data: unsupported column type % for column %', p_pgtype, p_col;
  end if;

  if p_nullable then
    return archive._pq_definition_levels(is_present) || values_payload;
  else
    return values_payload;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

create or replace function archive._pq_to_parquet(p_relation regclass, p_compress boolean default true) returns bytea
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
      else raise exception 'archive._pq_to_parquet: unsupported column type % for column %', v_col.typname, v_col.attname;
    end case;
  end loop;

  v_ncols := array_length(v_col_names, 1);
  if v_ncols is null then
    raise exception 'archive._pq_to_parquet: relation % has no supported columns', p_relation;
  end if;

  execute format('select count(*) from %s', v_from_sql) into v_num_rows;

  v_body := v_magic;
  for i in 1..v_ncols loop
    v_data := archive._pq_encode_column_data(v_from_sql, v_col_names[i], v_col_pgtypes[i], v_col_nullable[i]);
    if p_compress then
      v_page_bytes := archive._pq_gzip_compress_dynamic(v_data);
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data), length(v_page_bytes));
    else
      v_page_bytes := v_data;
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data));
    end if;
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_page_bytes;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || archive._pq_build_column_chunk(
        archive._pq_build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset,
          case when p_compress then 2 else 0 end,
          case when p_compress then length(v_page_header) + length(v_page_bytes) else null end));
    v_schema_elements := v_schema_elements || archive._pq_build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i], v_col_nullable[i]);
  end loop;

  v_row_group := archive._pq_build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(archive._pq_build_schema_root(v_ncols), v_schema_elements);
  v_footer := archive._pq_build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  return v_body || v_footer || archive._pq_reverse_bytes(int4send(length(v_footer))) || v_magic;
end;
$$;


-- ---------------------------------------------------------------------------
-- The range-based Parquet encoder (reads a [lo, hi) range off the parent,
-- relying on Postgres's own partition pruning), the derived watermark, and
-- the gate.
-- ---------------------------------------------------------------------------

-- archive._pq_to_parquet_range: reads [p_lo, p_hi) of p_control off p_parent (typically a
-- partitioned parent), relying on Postgres's own partition pruning. p_lo/p_hi are literals
-- already typed for p_control's actual column type -- e.g. for a uuidv7-kind control column,
-- translate a pgpm native-grid (timestamptz) value via pgpm._encode first, the same way
-- pgpm.regrain_step builds its own v_lo_lit/v_hi_lit before using them.
create or replace function archive._pq_to_parquet_range(p_parent regclass, p_control name, p_lo text, p_hi text, p_compress boolean default true) returns bytea
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

  v_key_cols := archive._key_columns(p_parent);
  if v_key_cols is null then
    raise exception 'archive._pq_to_parquet_range: % has no primary key or predicate/expression-free unique constraint; a resumable cross-partition range read cannot tiebreak ties on % without one (the same refusal pgpm.regrain_step already makes for keyless tables)',
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
      else raise exception 'archive._pq_to_parquet_range: unsupported column type % for column %', v_col.typname, v_col.attname;
    end case;
  end loop;

  v_ncols := array_length(v_col_names, 1);
  if v_ncols is null then
    raise exception 'archive._pq_to_parquet_range: relation % has no supported columns', p_parent;
  end if;

  execute format('select count(*) from %s', v_from_sql) into v_num_rows;

  v_body := v_magic;
  for i in 1..v_ncols loop
    v_data := archive._pq_encode_column_data(v_from_sql, v_col_names[i], v_col_pgtypes[i], v_col_nullable[i], v_order_by);
    if p_compress then
      v_page_bytes := archive._pq_gzip_compress_dynamic(v_data);
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data), length(v_page_bytes));
    else
      v_page_bytes := v_data;
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data));
    end if;
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_page_bytes;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || archive._pq_build_column_chunk(
        archive._pq_build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset,
          case when p_compress then 2 else 0 end,
          case when p_compress then length(v_page_header) + length(v_page_bytes) else null end));
    v_schema_elements := v_schema_elements || archive._pq_build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i], v_col_nullable[i]);
  end loop;

  v_row_group := archive._pq_build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(archive._pq_build_schema_root(v_ncols), v_schema_elements);
  v_footer := archive._pq_build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  return v_body || v_footer || archive._pq_reverse_bytes(int4send(length(v_footer))) || v_magic;
end;
$$;

-- pgpm_archive's old range-picking, drop-gating, and self-driving-retire-sweep apparatus
-- (archive._file_watermark, archive.file_gate, archive._next_range_partition_aligned,
-- archive._next_range_byte_budget, archive._retire_covered) is gone entirely (issue #240):
-- pgpm._next_archive_chunk/_archive_fully_covered/_archive_step in pgpm_core replaced it.

-- ---------------------------------------------------------------------------
-- The encode/upload transport: given a [lo, hi) range, produce and PUT the
-- archived object, returning what a ledger insert needs. Matching shapes --
-- (p_parent, p_lo, p_hi, p_compress) in, (s3_key, etag, rows_archived) out --
-- called directly by whichever pgpm.archive_to_s3_* strategy (below) a table's
-- config.archive_fn names. Connection settings (bucket/region/endpoint/prefix/
-- vault key names) come from archive.config, not local deployment constants.
--
-- Parquet has no internal-commits variant, and cannot: a Parquet file's footer
-- needs every row group's byte offset, known only once the whole file's bytes
-- exist, so there is no way to COMMIT partway through building one -- a
-- structural fact about the format, not a gap
-- (docs/to-s3.md#honest-limits-for-the-parquet-variant, #211).
-- ---------------------------------------------------------------------------

-- single read, single PUT (optionally one gzip member for the whole body). No pagination, so no
-- tiebreak is needed: a plain `order by` with no LIMIT never splits a run of ties across pages.
create or replace function archive._encode_upload_ndjson_single(p_parent regclass, p_lo text, p_hi text, p_compress boolean default false)
returns table(s3_key text, etag text, rows_archived bigint)
language plpgsql as $$
declare
  cfg archive.config; pcfg pgpm.config; v_nsp name; v_rel name;
  v_payload text; v_body bytea; v_key text;
  v_key_id text; v_secret text; v_resp http_response; h http_header; v_etag text; v_rows bigint;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive._encode_upload_ndjson_single: % has no archive.config row', p_parent; end if;
  select * into pcfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._encode_upload_ndjson_single: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  execute format(
    'select coalesce(string_agg(row_to_json(t)::text, e''\n'' order by t.%I), ''''), count(*)
       from %I.%I t where t.%I >= %L and t.%I < %L',
    pcfg.control_column, v_nsp, v_rel, pcfg.control_column, pgpm._encode(pcfg.control_kind, p_lo),
    pcfg.control_column, pgpm._encode(pcfg.control_kind, p_hi))
    into v_payload, v_rows;

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive._encode_upload_ndjson_single: credentials missing from vault';
  end if;

  v_key := cfg.prefix || p_parent::text || '_' || regexp_replace(p_lo, '[^0-9]', '', 'g') || '.ndjson';
  if p_compress then
    v_key := v_key || '.gz';
    v_body := archive._pq_gzip_compress_dynamic(convert_to(v_payload, 'UTF8'));
    v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                              'application/gzip', v_body, v_key_id, v_secret);
  else
    v_resp := archive.s3_signed_request('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                       'application/x-ndjson', v_payload, v_key_id, v_secret);
  end if;
  if v_resp.status not between 200 and 299 then
    raise exception 'archive._encode_upload_ndjson_single: PUT of % failed: HTTP % %', v_key, v_resp.status, left(v_resp.content, 200);
  end if;
  foreach h in array v_resp.headers loop
    if lower(h.field) = 'etag' then v_etag := h.value; end if;
  end loop;

  s3_key := v_key; etag := v_etag; rows_archived := v_rows;
  return next;
end;
$$;

-- archive._encode_upload_ndjson_commits, the third format (per-part-COMMIT, for an otherwise-
-- unbounded single read) is gone (issue #240): its only caller was the deleted archive.archive_range,
-- and the archive_fn strategies below cannot use a COMMIT-ing procedure anyway -- archive_fn is a
-- plain function, and PL/pgSQL forbids transaction control inside one regardless of call context.
-- They don't need to: pgpm._next_archive_chunk already bounds every call's own [lo, hi) to
-- config.archive_byte_budget before archive_fn ever runs, so the vacuum-horizon hold is already
-- small by construction.

-- thin wrapper around the range-based Parquet encoder + a PUT.
create or replace function archive._encode_upload_parquet(p_parent regclass, p_lo text, p_hi text, p_compress boolean default true)
returns table(s3_key text, etag text, rows_archived bigint)
language plpgsql as $$
declare
  cfg archive.config; pcfg pgpm.config; v_nsp name; v_rel name;
  v_payload bytea; v_key text; v_key_id text; v_secret text;
  v_resp http_response; h http_header; v_etag text; v_rows bigint;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive._encode_upload_parquet: % has no archive.config row', p_parent; end if;
  select * into pcfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._encode_upload_parquet: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  v_payload := archive._pq_to_parquet_range(p_parent, pcfg.control_column,
                                            pgpm._encode(pcfg.control_kind, p_lo), pgpm._encode(pcfg.control_kind, p_hi),
                                            p_compress);
  execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                 v_nsp, v_rel, pcfg.control_column, pgpm._encode(pcfg.control_kind, p_lo),
                 pcfg.control_column, pgpm._encode(pcfg.control_kind, p_hi))
    into v_rows;

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive._encode_upload_parquet: credentials missing from vault';
  end if;

  v_key := cfg.prefix || p_parent::text || '_' || regexp_replace(p_lo, '[^0-9]', '', 'g') || '.parquet';
  v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                            'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then
    raise exception 'archive._encode_upload_parquet: PUT of % failed: HTTP % %', v_key, v_resp.status, left(v_resp.content, 200);
  end if;
  foreach h in array v_resp.headers loop
    if lower(h.field) = 'etag' then v_etag := h.value; end if;
  end loop;

  s3_key := v_key; etag := v_etag; rows_archived := v_rows;
  return next;
end;
$$;

-- pgpm_archive's old paced worker (archive.archive_range/archive_partition/_tick_one/tick/run_all,
-- driven by archive.config's boundary_rule/drop_trigger knobs and a pgpm-archiver pg_cron job) is
-- gone entirely (issue #240): pgpm.maintain()'s own archive_fn-driven chunking replaced it, with no
-- second scheduled job -- archiving now rides maintain()'s existing cadence.

-- ---------------------------------------------------------------------------
-- The synchronous functions: archive a partition INLINE, called directly (no
-- ledger, no automatic scheduling), just archive.config's connection
-- settings.
-- ---------------------------------------------------------------------------

-- Small partitions (one part's worth or less) take a plain single PUT; bigger ones stream
-- through S3 multipart, holding at most one part in memory at a time.
create or replace function archive.to_s3(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  cfg archive.config; pcfg pgpm.config; v_ctltype text;
  v_ctype text := 'application/x-ndjson';
  v_key_id text; v_secret text; v_nsp name; v_key text;
  v_part_payload text; v_chunk text; v_cursor text; v_done boolean := false;
  v_upload_id text; v_part int := 0; v_etag text; v_parts_xml text := '';
  v_resp http_response; h http_header;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive.to_s3: % has no archive.config row', p_parent; end if;
  select * into pcfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive.to_s3: % is not managed', p_parent; end if;

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive.to_s3: credentials missing from vault';
  end if;

  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select a.atttypid::regtype::text into v_ctltype
    from pg_attribute a where a.attrelid = p_parent and a.attname = pcfg.control_column;
  v_key := cfg.prefix || p_child || '.ndjson';

  v_part_payload := '';
  v_cursor := null;
  <<parts>>
  loop
    while not v_done and octet_length(v_part_payload) < cfg.part_bytes loop
      execute format(
        'select coalesce(string_agg(j, e''\n'' order by k), ''''), (array_agg(k order by k desc))[1]::text
           from (select row_to_json(t)::text as j, t.%I as k from %I.%I t
                  where $1 is null or t.%I > $1::%s
                  order by t.%I limit $2) s',
        pcfg.control_column, v_nsp, p_child, pcfg.control_column, v_ctltype, pcfg.control_column)
        into v_chunk, v_cursor using v_cursor, cfg.fetch_rows;
      if v_chunk = '' then v_done := true;
      else v_part_payload := v_part_payload || v_chunk || e'\n';
      end if;
    end loop;

    exit parts when v_done and v_part > 0 and v_part_payload = '';

    if v_part = 0 and v_done then
      v_resp := archive.s3_signed_request('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                         v_ctype, v_part_payload, v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive.to_s3: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      return;
    end if;

    if v_part = 0 then
      v_resp := archive.s3_signed_request('POST', cfg.endpoint, cfg.bucket, cfg.region, v_key, 'uploads=',
                                         v_ctype, '', v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive.to_s3: initiate multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      v_upload_id := (xpath('//*[local-name()=''UploadId'']/text()', v_resp.content::xml))[1]::text;
    end if;

    v_part := v_part + 1;
    v_resp := archive.s3_signed_request('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                       'partNumber=' || v_part || '&uploadId=' || archive.s3_url_encode(v_upload_id),
                                       v_ctype, v_part_payload, v_key_id, v_secret);
    if v_resp.status not between 200 and 299 then
      raise exception 'archive.to_s3: part % of % failed: HTTP % %', v_part, p_child, v_resp.status, left(v_resp.content, 200);
    end if;
    v_etag := null;
    foreach h in array v_resp.headers loop
      if lower(h.field) = 'etag' then v_etag := h.value; end if;
    end loop;
    v_parts_xml := v_parts_xml || format('<Part><PartNumber>%s</PartNumber><ETag>%s</ETag></Part>', v_part, v_etag);
    v_part_payload := '';
    exit parts when v_done;
  end loop;

  -- complete. S3's one famous quirk: complete can return HTTP 200 with an <Error> body, so check both.
  v_resp := archive.s3_signed_request('POST', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                     'uploadId=' || archive.s3_url_encode(v_upload_id),
                                     'application/xml',
                                     '<CompleteMultipartUpload>' || v_parts_xml || '</CompleteMultipartUpload>',
                                     v_key_id, v_secret);
  if v_resp.status not between 200 and 299 or v_resp.content like '%<Error>%' then
    raise exception 'archive.to_s3: complete multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
  end if;
exception when others then
  -- abort the in-flight upload so no invisible incomplete parts accrue storage, then re-raise so
  -- retain() keeps the partition. (Belt and braces: also set a bucket lifecycle rule that expires
  -- incomplete multipart uploads, for the day even this abort cannot reach S3.)
  if v_upload_id is not null then
    begin
      perform archive.s3_signed_request('DELETE', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                       'uploadId=' || archive.s3_url_encode(v_upload_id),
                                       'text/plain', '', v_key_id, v_secret);
    exception when others then null;
    end;
  end if;
  raise;
end;
$$;

-- The Parquet hook: single PUT, same shape and ceiling as archive.to_s3's basic (non-multipart)
-- variant -- archive._pq_to_parquet reads every column via array_agg() with no COMMIT in between
-- (each column's array must come from the same snapshot as every other column's, or concurrent
-- writes between column reads could misalign rows across columns), so this holds the vacuum
-- horizon for the whole read+upload, structurally, not as an oversight.
create or replace function archive.to_s3_parquet(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  cfg archive.config;
  v_key_id text; v_secret text; v_key text; v_payload bytea; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive.to_s3_parquet: % has no archive.config row', p_parent; end if;

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive.to_s3_parquet: credentials missing from vault';
  end if;

  v_payload := archive._pq_to_parquet(p_child::regclass, cfg.compress);
  v_key := cfg.prefix || p_child || '.parquet';

  v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                            'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then
    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- archive_fn-conforming S3 strategies (issue #239): the same transport as the
-- synchronous functions above (archive._encode_upload_ndjson_single /
-- archive._encode_upload_parquet), adapted to pgpm.config.archive_fn's calling contract --
-- (p_parent, p_child, p_lo, p_hi) returns pgpm.archive_result -- so a table can set
-- archive_fn directly and ride pgpm.maintain()'s own byte-budget chunking
-- (pgpm._next_archive_chunk/_archive_step, #237). Connection settings (bucket/region/endpoint/
-- prefix/vault key names/compress) still come from archive.config -- one config surface, not two.
--
-- archive._encode_upload_ndjson_commits (the third format, with internal COMMITs to bound an
-- otherwise-unbounded single read) has no archive_fn counterpart and is gone (#240): archive_fn is
-- a plain FUNCTION, and PL/pgSQL forbids transaction control inside a function regardless of call
-- context, so it could never call a COMMIT-ing procedure anyway. It also doesn't need to --
-- pgpm._next_archive_chunk already bounds every call's own [lo, hi) to
-- config.archive_byte_budget before archive_fn ever runs, so the vacuum-horizon hold this
-- call needs to bound is already small by construction, the same goal ndjson_commits'
-- internal commits existed to reach a different way.
--
-- p_child is part of the archive_fn contract's required shape but unused here:
-- archive._encode_upload_ndjson_single/_encode_upload_parquet already scope their read to
-- [p_lo, p_hi) off p_parent directly, which pgpm._next_archive_chunk guarantees never spans
-- more than p_child's own bounds.
--
-- archive.to_s3/archive.to_s3_parquet (the synchronous functions above) are untouched and keep
-- working exactly as before; the paced worker they used to sit alongside is gone entirely (#240).
create or replace function pgpm.archive_to_s3_ndjson(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare
  cfg archive.config; v_result pgpm.archive_result;
  v_s3_key text; v_etag text; v_rows bigint;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'pgpm.archive_to_s3_ndjson: % has no archive.config row', p_parent; end if;

  select t.s3_key, t.etag, t.rows_archived into v_s3_key, v_etag, v_rows
    from archive._encode_upload_ndjson_single(p_parent, p_lo, p_hi, cfg.compress) t;

  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  v_result.s3_key := v_s3_key;
  v_result.etag := v_etag;
  return v_result;
end;
$$;

create or replace function pgpm.archive_to_s3_parquet(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare
  cfg archive.config; v_result pgpm.archive_result;
  v_s3_key text; v_etag text; v_rows bigint;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'pgpm.archive_to_s3_parquet: % has no archive.config row', p_parent; end if;

  select t.s3_key, t.etag, t.rows_archived into v_s3_key, v_etag, v_rows
    from archive._encode_upload_parquet(p_parent, p_lo, p_hi, cfg.compress) t;

  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  v_result.s3_key := v_s3_key;
  v_result.etag := v_etag;
  return v_result;
end;
$$;

-- archive.configure/unconfigure/schedule/unschedule -- the paced worker's operator interface
-- (issue #233) -- are gone entirely (issue #240), along with the pgpm-archiver pg_cron job they
-- managed: wire connection settings directly into archive.config (insert/update the row yourself;
-- it is a plain table, not an API surface with its own invariants to protect) and set
-- pgpm.config.archive_fn to choose a strategy. No second scheduled job -- pgpm.maintain()'s own
-- cadence drives archiving.
drop function if exists archive.configure(regclass, text, text, text, text, text, text, text, boolean, bigint, int, bigint, int, text, text);
drop function if exists archive.unconfigure(regclass);
drop function if exists archive.schedule(text);
drop function if exists archive.unschedule();

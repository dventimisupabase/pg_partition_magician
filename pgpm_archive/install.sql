-- =============================================================================
-- pg_partition_magician :: archive  --  archive a managed table's aged
-- partitions to S3 before retention drops them, config-driven.
--
-- OPTIONAL add-on, loaded ON TOP of the core (pgpm_core/install.sql). See
-- README.md in this directory for the front door. Graduates
-- docs/to-s3.md, docs/assistant.md, and
-- docs/chunked-parquet.md's embedded SQL into one installable module
-- (the harmonization stack, #217-#221, unified the ledger/gate/boundary-rule/
-- drop-trigger/encode-upload machinery those pages hand-built separately; this
-- module is what actually ships it). Those three pages remain the narrative:
-- motivation, honest limits, and the live-verification write-ups this module's
-- design rests on. pgpm's own core has zero dependency on this schema; nothing
-- here is required for ordinary partitioning.
--
-- Two independent architectures, same as the docs describe:
--   - The synchronous hook (archive.to_s3 / archive.to_s3_parquet): archives a
--     partition INLINE, inside retain()'s own drop transaction. Simplest model,
--     but holds the vacuum horizon for the whole read-and-upload.
--   - The paced worker (everything else here): an independently-paced procedure
--     (archive.tick(), driven by pg_cron) that archives ahead of any drop,
--     bounding the vacuum-horizon hold by committing between chunks of work.
--     Configured per managed table via archive.config, not hardcoded constants:
--       boundary_rule  'partition_aligned' | 'byte_budget'   -- which unit to archive
--       drop_trigger   'self_driving' | 'gate_only'          -- who drops it
--       format         'ndjson_single' | 'ndjson_commits' | 'parquet'
--     archive.file_gate (a pre_drop hook) is the backstop either way: it defers
--     a drop until the ledger shows the range fully, correctly archived.
--
-- Surface (all in the archive schema):
--   archive.config                 per-table settings (see above); one row per
--                                  managed table using either architecture.
--   archive.ledger                 one row per archived [lo, hi) range.
--   archive.file_gate              the pre_drop hook (register on every table
--                                  using the paced worker).
--   archive.tick()                 the standing worker: one pg_cron job, all
--                                  archive.config rows, paced.
--   archive.run_all(parent)        the operator's "do it now" for one table.
--   archive.archive_partition(parent, child)  manual, one partition, right now.
--   archive.to_s3 / archive.to_s3_parquet     the synchronous pre_drop hooks.
-- =============================================================================

create extension if not exists http;
create extension if not exists pgcrypto;
create schema if not exists archive;

-- per-table configuration, replacing the docs' "deployment constants: edit
-- these N" pattern with one real row per managed table. `create table if not
-- exists` + `alter table ... add column if not exists` below, mirroring
-- pgpm.config's own idempotent-upgrade shape, so re-running this file is safe.
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

  -- the paced worker's two independent knobs (see docs/strategies-overview.md)
  boundary_rule   text        not null default 'partition_aligned'
                  check (boundary_rule in ('partition_aligned', 'byte_budget')),
  drop_trigger    text        not null default 'self_driving'
                  check (drop_trigger in ('self_driving', 'gate_only')),

  -- the pluggable encode/upload step
  format          text        not null default 'ndjson_commits'
                  check (format in ('ndjson_single', 'ndjson_commits', 'parquet')),
  compress        boolean     not null default false,

  -- boundary-rule-specific tuning (unused columns for the other rule are simply ignored)
  byte_budget     bigint      not null default 8 * 1024 * 1024,   -- byte_budget rule
  probe_sample    int         not null default 1000,              -- byte_budget rule

  -- encode/upload-specific tuning (ndjson_commits only; ignored otherwise)
  part_bytes      bigint      not null default 8 * 1024 * 1024,
  fetch_rows      int         not null default 20000,

  created_at      timestamptz not null default now()
);

-- the ledger: one row per archived range, written by the archiver at the moment it verified the
-- upload. The drop gate consults THIS, never job history. A partition's own bounds are already a
-- native-grid [lo, hi) range -- the same shape a cross-partition, byte-budget-aligned archiver
-- needs for a range that spans part of one partition or several -- so this table is shared by
-- both boundary rules: `lo` is the primary key (ranges never overlap, by either rule's own
-- invariant), and `child_name` is an optional convenience column, populated only when the
-- archived range happens to equal exactly one partition's bounds, so a name-based lookup stays a
-- cheap equality check instead of a bounds-membership query.
create table if not exists archive.ledger (
  parent_table  regclass    not null,
  lo            text        not null,   -- native-grid text, same convention as pgpm.config lo/hi
  hi            text        not null,
  child_name    name,                   -- populated iff [lo, hi) is exactly one partition's bounds
  s3_key        text        not null,
  etag          text,
  rows_archived bigint      not null,
  archived_at   timestamptz not null default now(),
  primary key (parent_table, lo)
);
create index if not exists ledger_parent_table_hi_idx on archive.ledger (parent_table, hi desc);   -- cheap max(hi) for range-based readers

-- ---------------------------------------------------------------------------
-- Key discovery and S3 transport primitives
-- ---------------------------------------------------------------------------

-- key discovery, shared by every reader that has to order a read spanning more than one child's
-- heap (where ctid is no longer comparable): docs/chunked-parquet.md's Parquet range
-- reader and docs/assistant.md's NDJSON-with-commits range reader (#221) both call this.
-- Identical contract to pgpm.regrain_step's own v_keyidx/v_pkjoin discovery: a PRIMARY KEY
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
-- encoding, GZIP compression, struct builders, column-data extraction. Ported
-- rename-only from prototypes/parquet-writer/, verified there end to end
-- (pyarrow + DuckDB) before this port; nothing else changes.
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
-- encoder -- LZ77 matching plus a fixed Huffman code. Ported rename-only from
-- prototypes/parquet-writer/ (pq._* -> archive._pq_*), where this same logic
-- was verified end-to-end (pyarrow + DuckDB, including cross-partition
-- ranges) before this port; nothing else changes.
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
-- actually archive._pq_gzip_compress(...) output rather than the raw encoded bytes.
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
      v_page_bytes := archive._pq_gzip_compress(v_data);
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
      v_page_bytes := archive._pq_gzip_compress(v_data);
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

-- the derived watermark: kind-aware (numeric for id, timestamptz otherwise, matching
-- pgpm.config.control_kind), so a plain lexicographic max on the stored text never runs.
create or replace function archive._file_watermark(p_parent regclass) returns text
language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_wm text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._file_watermark: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select max(hi::%s)::text from archive.ledger where parent_table = %L::regclass',
                 v_ncast, p_parent::text) into v_wm;
  return v_wm;
end;
$$;

create or replace function archive.file_gate(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; v_wm text; v_nsp name; v_rel name;
  r record; v_overlap_live bigint; v_ov_lo text; v_ov_hi text; v_child_overlap bigint;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive.file_gate: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  -- fast path: derived, no scan
  v_wm := archive._file_watermark(p_parent);
  if v_wm is null or pgpm._native_gt(cfg.control_kind, p_hi, v_wm) then
    raise exception 'archive.file_gate: % (hi %) is not yet fully covered by the ledger watermark (%); deferring the drop',
      p_child, p_hi, coalesce(v_wm, '<none>');
  end if;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- defense in depth: every ledger row overlapping [p_lo, p_hi), whole-range recounted
  for r in
    execute format(
      'select lo, hi, rows_archived from archive.ledger
        where parent_table = %L::regclass and hi::%s > %L::%s and lo::%s < %L::%s
        for update',
      p_parent::text, v_ncast, p_lo, v_ncast, v_ncast, p_hi, v_ncast)
  loop
    execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                   v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, r.lo),
                   cfg.control_column, pgpm._encode(cfg.control_kind, r.hi))
      into v_overlap_live;
    if v_overlap_live is distinct from r.rows_archived then
      raise exception 'archive.file_gate: file % [%, %) changed since it was archived (% rows live, % archived); deferring for re-archive',
        (select s3_key from archive.ledger where parent_table = p_parent and lo = r.lo),
        r.lo, r.hi, v_overlap_live, r.rows_archived;
    end if;

    -- keep rows_archived in lockstep: subtract exactly the overlap between the partition about
    -- to be dropped and this row's range (a partition can span more than one row; each gets only
    -- its own slice subtracted).
    v_ov_lo := case when pgpm._native_gt(cfg.control_kind, p_lo, r.lo) then p_lo else r.lo end;
    v_ov_hi := case when pgpm._native_gt(cfg.control_kind, r.hi, p_hi) then p_hi else r.hi end;
    execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                   v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, v_ov_lo),
                   cfg.control_column, pgpm._encode(cfg.control_kind, v_ov_hi))
      into v_child_overlap;
    update archive.ledger set rows_archived = rows_archived - v_child_overlap
      where parent_table = p_parent and lo = r.lo;
  end loop;
end;
$$;


-- ---------------------------------------------------------------------------
-- Boundary rule: which range to archive next. Matching shapes -- (p_parent)
-- in, (lo, hi[, child_name]) or no rows out -- dispatched by archive.config's
-- boundary_rule column.
-- ---------------------------------------------------------------------------

-- picks the assistant's next range: the first attached, retention-eligible partition (in lo
-- order) whose ledger row is missing or stale (the live count no longer matches what was
-- recorded). Returns no rows once every eligible partition already has a fresh ledger row --
-- unlike the chunker's boundary rule, this one DOES revisit already-covered ranges, because a
-- partition-aligned range can still be attached (and still mutable) long after it was archived,
-- where a chunked file's range is retention-eligible-or-gone by the time it would be reconsidered.
create or replace function archive._next_range_partition_aligned(p_parent regclass)
returns table(lo text, hi text, child_name name)
language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_ncast text; v_nsp name;
  v_part record; v_rows bigint; v_live bigint;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._next_range_partition_aligned: % is not managed', p_parent; end if;
  v_boundary := pgpm._retain_boundary(cfg);
  v_ncast := pgpm._native_type(cfg.control_kind);
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  for v_part in execute format(
    'select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, v_boundary, v_ncast, v_ncast)
  loop
    select a.rows_archived into v_rows from archive.ledger a
     where a.parent_table = p_parent and a.child_name = v_part.child_name;
    execute format('select count(*) from %I.%I', v_nsp, v_part.child_name) into v_live;
    if v_rows is null or v_rows is distinct from v_live then
      lo := v_part.lo; hi := v_part.hi; child_name := v_part.child_name;
      return next;
      return;
    end if;
  end loop;
end;
$$;

-- picks this chunker's next range: the derived watermark (or this table's own grid anchor on the
-- very first call -- reusing pgpm.config's grid origin rather than inventing a second one) up to
-- the smallest of the frozen floor, the retention horizon, and the byte-budget estimate, extended
-- to the next distinct control value so a run of ties never splits across two files. Returns no
-- rows if nothing is eligible to archive yet.
create or replace function archive._next_range_byte_budget(p_parent regclass, c_byte_budget bigint default 8 * 1024 * 1024, c_probe_sample int default 1000)
returns table(lo text, hi text)
language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; v_nsp name; v_rel name;
  v_lo text; v_frontier text; v_floor text; v_retain_boundary text;
  v_avg numeric; v_batch int; v_batch_count int; v_probe_hi_col text; v_probe_hi text;
  v_next_distinct_col text; v_bytebudget_stop text;
  v_stop text; v_hi text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._next_range_byte_budget: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  v_lo := coalesce(archive._file_watermark(p_parent), cfg.partition_anchor);

  v_frontier := pgpm._frontier_native(p_parent);
  v_floor := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier);
  if not pgpm._native_gt(cfg.control_kind, v_floor, v_lo) then
    return;   -- nothing has frozen past the watermark yet
  end if;

  v_retain_boundary := pgpm._retain_boundary(cfg);
  if v_retain_boundary is not null and not pgpm._native_gt(cfg.control_kind, v_retain_boundary, v_lo) then
    return;   -- nothing retention-eligible past the watermark yet
  end if;
  v_stop := v_floor;
  if v_retain_boundary is not null and pgpm._native_gt(cfg.control_kind, v_stop, v_retain_boundary) then
    v_stop := v_retain_boundary;
  end if;

  -- byte budget -> row-count estimate, via a sampled average row width
  execute format(
    'select avg(pg_column_size(t.*))::numeric from (select * from %I.%I t where t.%I >= %L order by t.%I limit %s) t',
    v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, v_lo), cfg.control_column, c_probe_sample)
    into v_avg;
  if coalesce(v_avg, 0) <= 0 then
    return;   -- nothing at/after the watermark yet
  end if;
  v_batch := greatest(1, floor(c_byte_budget::numeric / v_avg))::int;

  execute format(
    'select count(*), max(%I)::text from (select %I from %I.%I t where t.%I >= %L order by t.%I limit %s) s',
    cfg.control_column, cfg.control_column, v_nsp, v_rel, cfg.control_column,
    pgpm._encode(cfg.control_kind, v_lo), cfg.control_column, v_batch)
    into v_batch_count, v_probe_hi_col;

  if v_batch_count < v_batch then
    v_bytebudget_stop := null;   -- reached the live end of the table: this bound does not apply
  else
    v_probe_hi := pgpm._decode(cfg.control_kind, v_probe_hi_col);
    -- extend to the next distinct value past the boundary, so hi never splits a run of ties
    execute format('select min(%I)::text from %I.%I t where t.%I > %L',
                   cfg.control_column, v_nsp, v_rel, cfg.control_column, v_probe_hi_col)
      into v_next_distinct_col;
    v_bytebudget_stop := case when v_next_distinct_col is null then null
                              else pgpm._decode(cfg.control_kind, v_next_distinct_col) end;
  end if;

  if v_bytebudget_stop is not null and pgpm._native_gt(cfg.control_kind, v_stop, v_bytebudget_stop) then
    v_stop := v_bytebudget_stop;
  end if;
  v_hi := v_stop;
  if not pgpm._native_gt(cfg.control_kind, v_hi, v_lo) then
    return;   -- no progress possible this call
  end if;

  lo := v_lo; hi := v_hi;
  return next;
end;
$$;


-- ---------------------------------------------------------------------------
-- Drop-trigger rule: archive.config.drop_trigger dispatches to this shared
-- retire sweep for 'self_driving' tables.
-- ---------------------------------------------------------------------------

create or replace procedure archive._retire_covered(p_parent regclass, p_up_to text, inout p_count int default 0)
language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; v_child record;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._retire_covered: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  for v_child in execute format(
    'select child_name from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, p_up_to, v_ncast, v_ncast)
  loop
    if pgpm.retire(p_parent, v_child.child_name) then
      p_count := p_count + 1;
    end if;
    commit;
  end loop;
end;
$$;


-- ---------------------------------------------------------------------------
-- The pluggable encode/upload step: given a [lo, hi) range, produce and PUT
-- the archived object, returning what the ledger insert needs. Matching
-- shapes -- (p_parent, p_lo, p_hi, p_compress) in, (s3_key, etag,
-- rows_archived) out -- dispatched by archive.config.format. Connection
-- settings (bucket/region/endpoint/prefix/vault key names) come from
-- archive.config, not local deployment constants.
--
-- Parquet with internal commits is not a fourth option, and cannot become
-- one: a Parquet file's footer needs every row group's byte offset, known
-- only once the whole file's bytes exist, so there is no way to COMMIT
-- partway through building one -- a structural fact about the format, not a
-- gap (docs/to-s3.md#honest-limits-for-the-parquet-variant, #211).
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
    v_body := archive._pq_gzip_compress(convert_to(v_payload, 'UTF8'));
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

-- per-part-commit technique: reads a [lo, hi) range off the parent, keyset-paginated, committing
-- between a page's read and a part's PUT (each snapshot held for at most one of those, not both) --
-- so the vacuum-horizon hold is bounded by archive.config.part_bytes over bandwidth, not the whole
-- range's read-and-upload time. A PROCEDURE, not a function, for two reasons: procedure-local
-- variables survive COMMIT (the keyset cursor, the UploadId, the ETag list), and PL/pgSQL forbids
-- transaction control inside a block with an EXCEPTION clause, so there is no handler and no
-- abort-on-exit -- cleanup-on-entry (aborting any stale in-flight upload for this key) and a bucket
-- lifecycle rule are the backstops instead.
--
-- Ordering matters more than it looks: a range read off the parent can span more than one child,
-- and a time-kind control column routinely repeats (duplicate timestamps are the common case, not
-- the exception), so ordering by the control column alone is not deterministic across a keyset
-- page boundary -- a run of ties straddling one silently drops rows under a naive `>` resume
-- predicate (confirmed live: a 21-row fixture with repeated timestamps lost 5 rows this way).
-- Ordering and resuming on a `text[]` of (control column, real key columns) fixes it: Postgres
-- compares arrays lexicographically, element by element, so `max(k)` / `array[...] > cursor` is a
-- genuine composite tiebreak without dynamic-arity ROW() construction. Key discovery is
-- archive._key_columns, the same helper the Parquet range reader uses.
--
-- Compression, if requested, gzips each part independently (archive._pq_gzip_compress) and lets S3
-- multipart's own byte-range concatenation produce the final object -- a valid multi-member gzip
-- stream (RFC 1952 permits concatenating independent gzip members; standard decompressors read
-- through all of them transparently; verified against a 30,000-row fixture forced into several
-- 6MiB+ parts, decompressing cleanly with a stock gunzip into all 30,000 rows).
create or replace procedure archive._encode_upload_ndjson_commits(
  p_parent regclass, p_lo text, p_hi text, p_compress boolean default false,
  inout p_s3_key text default null, inout p_etag text default null, inout p_rows bigint default 0)
language plpgsql as $$
declare
  cfg archive.config; pcfg pgpm.config; v_nsp name; v_rel name; v_ctype text;
  v_key_cols name[]; v_castlist text; v_key text;
  v_key_id text; v_secret text;
  v_part_payload text; v_chunk text; v_cursor text[]; v_done boolean := false;
  v_upload_id text; v_part int := 0; v_etag text; v_parts_xml text := '';
  v_rows bigint := 0; v_n bigint; v_stale text; v_body bytea;
  v_resp http_response; h http_header;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive._encode_upload_ndjson_commits: % has no archive.config row', p_parent; end if;
  select * into pcfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._encode_upload_ndjson_commits: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  v_key_cols := archive._key_columns(p_parent);
  if v_key_cols is null then
    raise exception 'archive._encode_upload_ndjson_commits: % has no primary key or predicate/expression-free unique constraint; a resumable range read cannot tiebreak ties on % without one',
      p_parent, pcfg.control_column;
  end if;
  select string_agg(format('%I::text', c), ', ' order by ord) into v_castlist
    from unnest(array_prepend(pcfg.control_column, v_key_cols)) with ordinality as t(c, ord);

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive._encode_upload_ndjson_commits: credentials missing from vault';
  end if;

  v_key := cfg.prefix || p_parent::text || '_' || regexp_replace(p_lo, '[^0-9]', '', 'g') || '.ndjson'
           || (case when p_compress then '.gz' else '' end);
  v_ctype := case when p_compress then 'application/gzip' else 'application/x-ndjson' end;
  commit;

  -- cleanup-on-entry: abort any in-flight multipart upload a failed or crashed prior run left
  -- behind for this key (invisible in listings, billed until aborted)
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, '',
                                     'prefix=' || archive.s3_url_encode(v_key) || '&uploads=',
                                     'application/xml', '', v_key_id, v_secret);
  for v_stale in
    select unnest(xpath('//*[local-name()=''Upload'']/*[local-name()=''UploadId'']/text()', v_resp.content::xml))::text
  loop
    perform archive.s3_signed_request('DELETE', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                     'uploadId=' || archive.s3_url_encode(v_stale),
                                     'text/plain', '', v_key_id, v_secret);
  end loop;
  commit;

  -- stream the range: read one part (snapshot held for a disk-speed moment, then COMMITted
  -- away), PUT it (snapshot held for one part's network time, then COMMITted away), repeat.
  v_part_payload := '';
  v_cursor := null;
  <<parts>>
  loop
    while not v_done and octet_length(v_part_payload) < cfg.part_bytes loop
      execute format(
        'select coalesce(string_agg(j, e''\n'' order by k), ''''), max(k), count(*)
           from (select row_to_json(t)::text as j, array[%s] as k from %I.%I t
                  where t.%I >= %L and t.%I < %L and ($1 is null or array[%s] > $1)
                  order by array[%s] limit $2) s',
        v_castlist, v_nsp, v_rel,
        pcfg.control_column, pgpm._encode(pcfg.control_kind, p_lo), pcfg.control_column, pgpm._encode(pcfg.control_kind, p_hi),
        v_castlist, v_castlist)
        into v_chunk, v_cursor, v_n using v_cursor, cfg.fetch_rows;
      if v_chunk = '' then v_done := true;
      else v_part_payload := v_part_payload || v_chunk || e'\n'; v_rows := v_rows + v_n;
      end if;
      commit;   -- release the read snapshot before any network time
    end loop;

    exit parts when v_done and v_part > 0 and v_part_payload = '';
    if p_compress and v_part_payload != '' then
      v_body := archive._pq_gzip_compress(convert_to(v_part_payload, 'UTF8'));
    end if;

    if v_part = 0 and v_done then
      -- everything fit in one part: plain single PUT, no multipart bookkeeping
      if p_compress then
        v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                                  v_ctype, v_body, v_key_id, v_secret);
      else
        v_resp := archive.s3_signed_request('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                           v_ctype, v_part_payload, v_key_id, v_secret);
      end if;
      if v_resp.status not between 200 and 299 then
        raise exception 'archive._encode_upload_ndjson_commits: PUT of % failed: HTTP % %', v_key, v_resp.status, left(v_resp.content, 200);
      end if;
      foreach h in array v_resp.headers loop
        if lower(h.field) = 'etag' then v_etag := h.value; end if;
      end loop;
      exit parts;
    end if;

    if v_part = 0 then
      v_resp := archive.s3_signed_request('POST', cfg.endpoint, cfg.bucket, cfg.region, v_key, 'uploads=',
                                         v_ctype, '', v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive._encode_upload_ndjson_commits: initiate multipart for % failed: HTTP % %', v_key, v_resp.status, left(v_resp.content, 200);
      end if;
      v_upload_id := (xpath('//*[local-name()=''UploadId'']/text()', v_resp.content::xml))[1]::text;
      commit;
    end if;

    v_part := v_part + 1;
    if p_compress then
      v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                                'partNumber=' || v_part || '&uploadId=' || archive.s3_url_encode(v_upload_id),
                                                v_ctype, v_body, v_key_id, v_secret);
    else
      v_resp := archive.s3_signed_request('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                         'partNumber=' || v_part || '&uploadId=' || archive.s3_url_encode(v_upload_id),
                                         v_ctype, v_part_payload, v_key_id, v_secret);
    end if;
    if v_resp.status not between 200 and 299 then
      raise exception 'archive._encode_upload_ndjson_commits: part % of % failed: HTTP % %', v_part, v_key, v_resp.status, left(v_resp.content, 200);
    end if;
    v_etag := null;
    foreach h in array v_resp.headers loop
      if lower(h.field) = 'etag' then v_etag := h.value; end if;
    end loop;
    v_parts_xml := v_parts_xml || format('<Part><PartNumber>%s</PartNumber><ETag>%s</ETag></Part>', v_part, v_etag);
    v_part_payload := '';
    commit;   -- the horizon-hold window ends here; vacuum may advance before the next part
    exit parts when v_done;
  end loop;

  if v_part > 0 then
    v_resp := archive.s3_signed_request('POST', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                       'uploadId=' || archive.s3_url_encode(v_upload_id),
                                       'application/xml',
                                       '<CompleteMultipartUpload>' || v_parts_xml || '</CompleteMultipartUpload>',
                                       v_key_id, v_secret);
    if v_resp.status not between 200 and 299 or v_resp.content like '%<Error>%' then
      raise exception 'archive._encode_upload_ndjson_commits: complete multipart for % failed: HTTP % %', v_key, v_resp.status, left(v_resp.content, 200);
    end if;
    v_etag := null;
    v_etag := (xpath('//*[local-name()=''ETag'']/text()', v_resp.content::xml))[1]::text;
  end if;

  p_s3_key := v_key; p_etag := v_etag; p_rows := v_rows;
end;
$$;

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

-- ---------------------------------------------------------------------------
-- The unified worker. archive.config's boundary_rule and drop_trigger columns
-- are the only two knobs; everything downstream (the archiver, the ledger
-- write, the retire sweep) is the same code path regardless of which table
-- picked which knob.
-- ---------------------------------------------------------------------------

-- archives exactly [p_lo, p_hi) for p_parent: dispatches to whichever encode/upload step
-- archive.config.format configures, then writes the ledger row. p_child, if given, is a
-- convenience column populated only when [p_lo, p_hi) happens to equal one partition's bounds.
create or replace procedure archive.archive_range(p_parent regclass, p_lo text, p_hi text, p_child name default null)
language plpgsql as $$
declare
  cfg archive.config;
  v_s3_key text; v_etag text; v_rows bigint;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive.archive_range: % has no archive.config row', p_parent; end if;

  if cfg.format = 'ndjson_commits' then
    call archive._encode_upload_ndjson_commits(p_parent, p_lo, p_hi, cfg.compress, v_s3_key, v_etag, v_rows);
  elsif cfg.format = 'ndjson_single' then
    select t.s3_key, t.etag, t.rows_archived into v_s3_key, v_etag, v_rows
      from archive._encode_upload_ndjson_single(p_parent, p_lo, p_hi, cfg.compress) t;
  elsif cfg.format = 'parquet' then
    select t.s3_key, t.etag, t.rows_archived into v_s3_key, v_etag, v_rows
      from archive._encode_upload_parquet(p_parent, p_lo, p_hi, cfg.compress) t;
  else
    raise exception 'archive.archive_range: unknown format % for %', cfg.format, p_parent;
  end if;

  -- the ledger row: written only now, after the store confirmed the object. A crash between the
  -- encode/upload step and this insert just re-archives next tick (a PUT to the same key
  -- overwrites; the encode/upload step's own cleanup-on-entry finds nothing in flight because the
  -- upload completed).
  insert into archive.ledger (parent_table, lo, hi, child_name, s3_key, etag, rows_archived)
  values (p_parent, p_lo, p_hi, p_child, v_s3_key, v_etag, v_rows)
  on conflict (parent_table, lo)
    do update set hi = excluded.hi, child_name = excluded.child_name,
                  s3_key = excluded.s3_key, etag = excluded.etag,
                  rows_archived = excluded.rows_archived, archived_at = now();
  commit;
end;
$$;

-- manual, one-partition-right-now entry point (also used internally by archive._tick_one for
-- partition_aligned tables). Enforces the forward-only guard: archive.file_gate's fast path
-- trusts the ledger's watermark to mean "everything below this is archived" -- true only if
-- coverage is gap-free from wherever the ledger starts. The byte_budget boundary rule keeps that
-- by construction (archive._next_range_byte_budget always extends the watermark forward); this
-- procedure takes an arbitrary child name, so it enforces the same contract explicitly. A
-- re-archive of an already-ledgered partition (the stale-veto self-repair path) is exempt -- it
-- overwrites its own existing row, not extending the frontier.
create or replace procedure archive.archive_partition(p_parent regclass, p_child name)
language plpgsql as $$
declare
  v_lo text; v_hi text; v_reledger boolean; v_expected_lo text;
begin
  select lo, hi into v_lo, v_hi from pgpm.part where parent_table = p_parent and child_name = p_child;

  select exists(select 1 from archive.ledger where parent_table = p_parent and lo = v_lo) into v_reledger;
  if not v_reledger then
    select coalesce(archive._file_watermark(p_parent), (select min(lo) from pgpm.part where parent_table = p_parent))
      into v_expected_lo;
    if v_lo is distinct from v_expected_lo then
      raise exception 'archive.archive_partition: % [lo %] is out of order -- % is next expected to archive lo %; archive partitions in ascending lo order (archive.tick always does) so the shared ledger stays gap-free for archive.file_gate''s fast path',
        p_child, v_lo, p_parent, coalesce(v_expected_lo, '<none>');
    end if;
  end if;
  commit;   -- release this procedure's own read snapshot before the encode/upload step's work

  call archive.archive_range(p_parent, v_lo, v_hi, p_child);
end;
$$;

-- one unit of work for one archive.config row: picks the next range via whichever boundary_rule
-- is configured, archives it if there is one. p_progress reports whether it made progress, so
-- callers (archive.tick(), archive.run_all()) know when to stop looping.
create or replace procedure archive._tick_one(p_parent regclass, inout p_progress boolean default false)
language plpgsql as $$
declare
  cfg archive.config;
  v_lo text; v_hi text; v_child name;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive._tick_one: % has no archive.config row', p_parent; end if;

  if cfg.boundary_rule = 'partition_aligned' then
    select t.lo, t.hi, t.child_name into v_lo, v_hi, v_child from archive._next_range_partition_aligned(p_parent) t;
  elsif cfg.boundary_rule = 'byte_budget' then
    select t.lo, t.hi into v_lo, v_hi from archive._next_range_byte_budget(p_parent, cfg.byte_budget, cfg.probe_sample) t;
  else
    raise exception 'archive._tick_one: unknown boundary_rule % for %', cfg.boundary_rule, p_parent;
  end if;

  if v_lo is null then
    p_progress := false;
    return;
  end if;

  if cfg.boundary_rule = 'partition_aligned' then
    call archive.archive_partition(p_parent, v_child);
  else
    call archive.archive_range(p_parent, v_lo, v_hi);
  end if;
  p_progress := true;
end;
$$;

-- the standing worker: one pg_cron job, every archive.config row, paced. Two passes, not
-- interleaved per table: archiving drains archive._tick_one until each table has nothing left to
-- report, THEN (for drop_trigger = 'self_driving' tables) the retire sweep runs -- unconditionally,
-- not just for tables that archived something just now. That "unconditionally" matters: a
-- partition-aligned table with nothing new to archive could otherwise never retry a partition
-- whose retire() failed earlier for a reason unrelated to archiving (the exact gap #219 fixed for
-- the partition-aligned rule specifically); a byte-budget table that has quiesced (no new data,
-- so no new chunks, ever) would have the identical problem if retiring only ever piggybacked on a
-- fresh chunk. Running the sweep every tick, for every self-driving table, closes both cases the
-- same way.
create or replace procedure archive.tick()
language plpgsql as $$
declare
  cfg archive.config; pcfg pgpm.config;
  v_progress boolean; v_iter int; v_up_to text; v_count int;
begin
  if not pg_try_advisory_lock(hashtext('pgpm-archiver')) then return; end if;

  for cfg in select * from archive.config loop
    v_iter := 0;
    loop
      v_progress := false;
      call archive._tick_one(cfg.parent_table, v_progress);
      exit when not v_progress;
      v_iter := v_iter + 1;
      if v_iter > 1000000 then raise exception 'archive.tick: safety limit for %', cfg.parent_table; end if;
    end loop;
  end loop;

  for cfg in select * from archive.config where drop_trigger = 'self_driving' loop
    select * into pcfg from pgpm.config where parent_table = cfg.parent_table;
    if cfg.boundary_rule = 'partition_aligned' then
      v_up_to := pgpm._retain_boundary(pcfg);
    else
      v_up_to := archive._file_watermark(cfg.parent_table);
    end if;
    if v_up_to is not null then
      v_count := 0;
      call archive._retire_covered(cfg.parent_table, v_up_to, v_count);
    end if;
  end loop;

  perform pg_advisory_unlock(hashtext('pgpm-archiver'));
end;
$$;

-- the operator's "do it now" for one table: drains archive._tick_one until no more progress, then
-- (if self_driving) runs the same unconditional retire sweep archive.tick() does. Shares
-- archive.tick()'s own advisory lock, so a manual run_all() call and the standing cron job can
-- never race on the same (or a different) table at the same time.
create or replace procedure archive.run_all(p_parent regclass)
language plpgsql as $$
declare
  cfg archive.config; pcfg pgpm.config;
  v_progress boolean; v_iter int := 0; v_up_to text; v_count int;
begin
  if not pg_try_advisory_lock(hashtext('pgpm-archiver')) then return; end if;

  select * into cfg from archive.config where parent_table = p_parent;
  if not found then
    perform pg_advisory_unlock(hashtext('pgpm-archiver'));
    raise exception 'archive.run_all: % has no archive.config row', p_parent;
  end if;

  loop
    v_progress := false;
    call archive._tick_one(p_parent, v_progress);
    exit when not v_progress;
    v_iter := v_iter + 1;
    if v_iter > 1000000 then raise exception 'archive.run_all: safety limit for %', p_parent; end if;
  end loop;

  if cfg.drop_trigger = 'self_driving' then
    select * into pcfg from pgpm.config where parent_table = p_parent;
    if cfg.boundary_rule = 'partition_aligned' then
      v_up_to := pgpm._retain_boundary(pcfg);
    else
      v_up_to := archive._file_watermark(p_parent);
    end if;
    if v_up_to is not null then
      v_count := 0;
      call archive._retire_covered(p_parent, v_up_to, v_count);
    end if;
  end if;

  perform pg_advisory_unlock(hashtext('pgpm-archiver'));
end;
$$;

-- ---------------------------------------------------------------------------
-- The synchronous hooks: archive a partition INLINE, inside retain()'s own
-- drop transaction. Structurally separate from the paced worker above (a
-- pre_drop hook is a nested call inside retain()'s already-open transaction,
-- and PL/pgSQL forbids issuing COMMIT from inside a block reachable that way,
-- so a synchronous hook can never bound its own vacuum-horizon hold by
-- committing between chunks of work, no matter how it's rewritten) -- no
-- ledger, no gate, no archive.config.boundary_rule/drop_trigger/format
-- involvement, just archive.config's connection settings.
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
-- The operator interface: configure, register a hook, schedule. Nothing above
-- this is meant to be hand-edited or hand-inserted for normal operation -- a
-- raw insert/update into archive.config, or a raw cron.schedule call, is
-- never the interface.
-- ---------------------------------------------------------------------------

-- wires up (or re-wires) archival's connection settings and knobs for one managed table. Call
-- again to change any setting -- an upsert, not an error, on a table already configured. Does NOT
-- register any pre_drop hook: which one to register (archive.file_gate for the paced worker,
-- archive.to_s3/archive.to_s3_parquet for the synchronous hook) depends on which architecture the
-- table uses, so that stays its own explicit pgpm.hook_register call.
create or replace function archive.configure(
  p_parent        regclass,
  p_bucket        text,
  p_region        text default 'us-east-1',
  p_endpoint      text default null,
  p_prefix        text default 'events/',
  p_boundary_rule text default 'partition_aligned',   -- or 'byte_budget'
  p_drop_trigger  text default 'self_driving',        -- or 'gate_only'
  p_format        text default 'ndjson_commits',      -- or 'ndjson_single' / 'parquet'
  p_compress      boolean default false,
  p_byte_budget   bigint default 8 * 1024 * 1024,      -- byte_budget rule only
  p_probe_sample  int default 1000,                    -- byte_budget rule only
  p_part_bytes    bigint default 8 * 1024 * 1024,      -- ndjson_commits format only
  p_fetch_rows    int default 20000,                   -- ndjson_commits format only
  p_vault_key_id  text default 's3_archive_access_key_id',
  p_vault_secret  text default 's3_archive_secret_access_key'
) returns void language plpgsql as $$
begin
  if not exists (select 1 from pgpm.config where parent_table = p_parent) then
    raise exception 'archive.configure: % is not managed by pgpm; transmute() it first', p_parent;
  end if;

  insert into archive.config (
    parent_table, bucket, region, endpoint, prefix, boundary_rule, drop_trigger, format, compress,
    byte_budget, probe_sample, part_bytes, fetch_rows, vault_key_id, vault_secret)
  values (
    p_parent, p_bucket, p_region, p_endpoint, p_prefix, p_boundary_rule, p_drop_trigger, p_format, p_compress,
    p_byte_budget, p_probe_sample, p_part_bytes, p_fetch_rows, p_vault_key_id, p_vault_secret)
  on conflict (parent_table) do update set
    bucket = excluded.bucket, region = excluded.region, endpoint = excluded.endpoint, prefix = excluded.prefix,
    boundary_rule = excluded.boundary_rule, drop_trigger = excluded.drop_trigger,
    format = excluded.format, compress = excluded.compress,
    byte_budget = excluded.byte_budget, probe_sample = excluded.probe_sample,
    part_bytes = excluded.part_bytes, fetch_rows = excluded.fetch_rows,
    vault_key_id = excluded.vault_key_id, vault_secret = excluded.vault_secret;
end;
$$;

-- the reverse of archive.configure: drops the config row (idempotent -- a no-op if there wasn't
-- one). The ledger is untouched -- it is a record of what was actually archived, not
-- configuration -- and any registered pre_drop hook is untouched too, for the same reason
-- archive.configure never registered one: this function doesn't know which hook(s) this table
-- was using, so it doesn't guess. Unregister explicitly via pgpm.hook_unregister first if wanted.
create or replace function archive.unconfigure(p_parent regclass) returns void language plpgsql as $$
begin
  delete from archive.config where parent_table = p_parent;
end;
$$;

-- the one standing job, same shape as pgpm.schedule(): one call, every archive.config row, paced
-- by archive.tick(). p_every is a pg_cron schedule (standard 5-field cron, or pg_cron's seconds
-- interval). cron.schedule_in_database (not bare cron.schedule) pins the job to the CURRENT
-- database explicitly, the same way pgpm.schedule() does, since pg_cron's own scheduler process
-- can serve more than one database.
create or replace function archive.schedule(p_every text default '* * * * *')
returns bigint language plpgsql as $$
declare v_jobid bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'archive.schedule: pg_cron is not installed in this database; enable it (create extension pg_cron) to schedule the archiver, or call archive.tick() by hand';
  end if;
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm-archiver', p_every, 'call archive.tick()', current_database())
    into v_jobid;
  return v_jobid;
end;
$$;

create or replace function archive.unschedule() returns int language plpgsql as $$
declare v_n int := 0;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    return 0;   -- nothing scheduled if pg_cron is not here
  end if;
  execute 'select count(*)::int from (select cron.unschedule(jobid) from cron.job '
       || 'where jobname = ''pgpm-archiver'' and database = current_database()) s' into v_n;
  return v_n;
end;
$$;

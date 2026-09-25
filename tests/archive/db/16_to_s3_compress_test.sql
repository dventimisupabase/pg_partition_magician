-- archive.to_s3, the synchronous NDJSON export, never read archive.config.compress. With the flag on
-- it uploaded plain NDJSON at <prefix><child>.ndjson, while pgpm_archive/README.md promises GZIP for
-- either format and archive.to_s3_parquet and both archive_fn strategies honour the flag (issue
-- #520). It now writes a GZIP stream at <prefix><child>.ndjson.gz with Content-Type application/gzip,
-- the key the automatic NDJSON strategy already uses for a compressed object, and nothing at the
-- plain key.
--
-- Two compressed exports, because the function has two upload paths and the flag has to reach both.
-- A small partition takes the single PUT. Its object is one gzip member, and a member ends with the
-- CRC-32 and the byte length of what it compressed (RFC 1952), so this file can check from inside the
-- database that the member holds EXACTLY the partition's NDJSON, not merely that it starts with the
-- gzip magic. A large partition streams through multipart. There each text chunk becomes a gzip
-- member of its own and members accumulate into a part until the part is full, because S3 and MinIO
-- refuse a non-final part under 5 MiB (EntityTooSmall, verified against this harness's MinIO) and a
-- compressed chunk is usually far under it; the object is a concatenation of members, which RFC 1952
-- section 2.2 defines as a valid gzip file. That object's ETag carries the part count, the witness
-- that multipart really ran. Its content identity is asserted by bench/archive_to_s3_compress.sh,
-- which reads both objects out of t16.obj and inflates them with Python's gzip, a decoder this module
-- does not have (the same split as bench/archive_parquet_snapshot.sh). An empty partition is exported
-- too, because a compressed object has to be a gzip file even when it holds no rows. A last export
-- with the flag off is the control: plain NDJSON at the plain key, nothing at the .gz key.
--
-- The multipart fixture is 16000 rows of 1024 base64 characters over 768 random bytes each, about
-- 16.8 MiB of NDJSON. Base64 over random bytes cannot compress below three quarters (six bits of
-- entropy per eight-bit character), so three 5 MiB text chunks give members of which two are needed
-- to fill a 5 MiB part: two parts, whatever the encoder's exact ratio. Compressible filler would need
-- gigabytes of text to fill one part.
--
-- Fixtures are asymmetric (distinct payloads, a 2-row control against a 40-row export), and every key
-- is cleared and witnessed empty before its export, because the bucket outlives a test database and a
-- stale object from an earlier run could otherwise satisfy an assertion below.
select plan(37);

create schema t16;

-- GET status alone: 404 is the witness that a key is empty.
create function t16.object_status(p_parent regclass, p_key text) returns int
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  return v_resp.status;
end;
$$;

-- DELETE the key, then report the GET status: 404 means the next export starts from an empty key.
create function t16.clear_object(p_parent regclass, p_key text) returns int
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  perform archive.s3_signed_request('DELETE', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  return t16.object_status(p_parent, p_key);
end;
$$;

-- The object, with the two response headers this file reads. http_response.content is text, but the
-- extension fills it by reinterpreting the body's bytes rather than re-encoding them, and text_to_bytea
-- reverses that reinterpretation, so a binary gzip body comes back byte-for-byte.
create function t16.fetch(p_parent regclass, p_key text)
returns table(status int, ctype text, etag text, bytes bytea)
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response; h http_header;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  status := v_resp.status;
  foreach h in array v_resp.headers loop
    if lower(h.field) = 'content-type' then ctype := h.value; end if;
    if lower(h.field) = 'etag' then etag := h.value; end if;
  end loop;
  bytes := text_to_bytea(v_resp.content);
  return next;
end;
$$;

-- an unsigned little-endian 32-bit integer at a 0-based offset: how a gzip trailer stores CRC-32 and ISIZE
create function t16.le32(b bytea, off int) returns bigint language sql immutable as $$
  select get_byte(b, off)::bigint
       + get_byte(b, off + 1)::bigint * 256
       + get_byte(b, off + 2)::bigint * 65536
       + get_byte(b, off + 3)::bigint * 16777216
$$;

-- what archive.to_s3 is expected to emit for a child: one row_to_json line per row, each newline-terminated,
-- in control-column order
create function t16.expected_text(p_child regclass) returns text language plpgsql as $$
declare v text;
begin
  execute format('select coalesce(string_agg(row_to_json(t)::text || %L, %L order by t.id), %L) from %s t', e'\n', '', '', p_child) into v;
  return v;
end;
$$;

create function t16.ids(p_child regclass) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  execute format('select array_agg(id order by id) from %s', p_child) into v;
  return v;
end;
$$;

-- handed to bench/archive_to_s3_compress.sh, which inflates each object and checks it against these
create table t16.obj (label text primary key, bytes bytea not null, expected_md5 text not null, expected_ids bigint[] not null);

-- =====================================================================================================
-- 1. Compress on, small partition: the single-PUT path
-- =====================================================================================================

call mk_archive_table('gz', 40, 10, 20, p_paused => false);
update public.gz set payload = 'row-' || id;
select mk_archive_config('gz', true);

select ok((select compress from archive.config where parent_table = 'public.gz'::regclass),
  'LIVENESS: archive.config.compress is on for public.gz');

-- the child transmute built over ids 1..40, located by tableoid rather than by name
select c.relname as gz_child from public.gz t join pg_class c on c.oid = t.tableoid where t.id = 1 \gset
select lo as gz_lo, hi as gz_hi from pgpm.part where parent_table = 'public.gz'::regclass and child_name = :'gz_child' \gset

select is((select count(distinct tableoid)::int from public.gz), 1,
  'setup: all 40 rows sit in the one partition being exported');
select is(t16.clear_object('public.gz', 'gz/' || :'gz_child' || '.ndjson'), 404,
  'setup: no object at the plain key before the export');
select is(t16.clear_object('public.gz', 'gz/' || :'gz_child' || '.ndjson.gz'), 404,
  'setup: no object at the .gz key before the export');

-- the other synchronous function honours the flag on this same table, so the flag reaches the synchronous
-- path and what follows is about archive.to_s3, not about config plumbing
select isnt(
  md5(archive._pq_to_parquet(format('public.%I', :'gz_child')::regclass, true)),
  md5(archive._pq_to_parquet(format('public.%I', :'gz_child')::regclass, false)),
  'LIVENESS: the Parquet encoder produces different bytes with compress on, so the flag has an effect the module can honour');

select lives_ok(
  format($$ select archive.to_s3('public.gz', %L, %L, %L) $$, :'gz_child', :'gz_lo', :'gz_hi'),
  'archive.to_s3 exports the 40-row partition with compress on');

create temporary table gz_obj as select * from t16.fetch('public.gz', 'gz/' || :'gz_child' || '.ndjson.gz');
create temporary table gz_expect as
  select convert_to(t16.expected_text(format('public.%I', :'gz_child')::regclass), 'UTF8') as bytes;

select is((select status from gz_obj), 200, 'the object lands at <prefix><child>.ndjson.gz');
select is((select encode(substring(bytes from 1 for 3), 'hex') from gz_obj), '1f8b08',
  'and it is a gzip member: magic 1f 8b, compression method 08 (deflate)');
select is((select ctype from gz_obj), 'application/gzip', 'stored with Content-Type application/gzip');

select is(
  (select array_agg((l::jsonb ->> 'id')::int order by (l::jsonb ->> 'id')::int)
     from gz_expect, regexp_split_to_table(convert_from(bytes, 'UTF8'), e'\n') l where l <> ''),
  (select array_agg(g) from generate_series(1, 40) g),
  'LIVENESS: the NDJSON the trailer is checked against names ids 1..40, one line each');

-- identity: a gzip member ends with the CRC-32 and the byte length of what it compressed, which must be
-- exactly the partition's NDJSON
select is((select t16.le32(o.bytes, octet_length(o.bytes) - 4) from gz_obj o), (select octet_length(bytes)::bigint from gz_expect),
  'the trailer''s ISIZE is the byte length of the partition''s NDJSON');
select is((select t16.le32(o.bytes, octet_length(o.bytes) - 8) from gz_obj o), (select archive._pq_crc32(bytes) from gz_expect),
  'and its CRC-32 is the CRC-32 of that NDJSON: the member holds exactly these 40 rows');

select is(t16.object_status('public.gz', 'gz/' || :'gz_child' || '.ndjson'), 404,
  'nothing was written at the plain .ndjson key');

insert into t16.obj (label, bytes, expected_md5, expected_ids)
  select 'single', o.bytes, md5(e.bytes), t16.ids(format('public.%I', :'gz_child')::regclass) from gz_obj o, gz_expect e;

-- an empty partition still gets one gzip member (header, an empty deflate block, CRC-32 0, ISIZE 0), so
-- the object at the .gz key is always a gzip file a reader can open, never a zero-byte object
select child_name as empty_child from pgpm.part where parent_table = 'public.gz'::regclass and lo = '60' \gset
select is((select count(*)::int from public.gz where id >= 60 and id < 70), 0,
  'setup: the [60, 70) partition holds no rows');
select is(t16.clear_object('public.gz', 'gz/' || :'empty_child' || '.ndjson.gz'), 404,
  'setup: no object at its .gz key before the export');
select lives_ok(
  format($$ select archive.to_s3('public.gz', %L, '60', '70') $$, :'empty_child'),
  'archive.to_s3 exports the empty partition with compress on');
create temporary table empty_obj as select * from t16.fetch('public.gz', 'gz/' || :'empty_child' || '.ndjson.gz');
select is((select status || ' ' || encode(substring(bytes from 1 for 3), 'hex') from empty_obj), '200 1f8b08',
  'the empty export is a gzip member at the .gz key: HTTP 200, magic 1f 8b, method 08');
select is((select t16.le32(bytes, octet_length(bytes) - 8) || ' ' || t16.le32(bytes, octet_length(bytes) - 4) from empty_obj), '0 0',
  'whose trailer says CRC-32 0 and ISIZE 0: a member holding no rows, not a zero-byte object');

-- =====================================================================================================
-- 2. Compress on, large partition: the multipart path
-- =====================================================================================================

call mk_archive_table('gzm', 16000, 20000);
update public.gzm set payload = replace(encode(gen_random_bytes(768), 'base64'), e'\n', '');
select mk_archive_config('gzm', true);
update archive.config set part_bytes = 5 * 1024 * 1024, fetch_rows = 1000 where parent_table = 'public.gzm'::regclass;

select c.relname as gzm_child from public.gzm t join pg_class c on c.oid = t.tableoid where t.id = 1 \gset
select lo as gzm_lo, hi as gzm_hi from pgpm.part where parent_table = 'public.gzm'::regclass and child_name = :'gzm_child' \gset

select is((select count(distinct tableoid)::int from public.gzm), 1,
  'setup: all 16000 rows sit in the one partition being exported');

create temporary table gzm_expect as
  select convert_to(t16.expected_text(format('public.%I', :'gzm_child')::regclass), 'UTF8') as bytes;

select cmp_ok((select octet_length(bytes) from gzm_expect), '>=', 3 * 5 * 1024 * 1024,
  'LIVENESS: the partition''s NDJSON spans at least three 5 MiB text chunks, so the export compresses several members and must fill more than one part');

select is(t16.clear_object('public.gzm', 'gzm/' || :'gzm_child' || '.ndjson'), 404,
  'setup: no object at the plain key before the export');
select is(t16.clear_object('public.gzm', 'gzm/' || :'gzm_child' || '.ndjson.gz'), 404,
  'setup: no object at the .gz key before the export');

select lives_ok(
  format($$ select archive.to_s3('public.gzm', %L, %L, %L) $$, :'gzm_child', :'gzm_lo', :'gzm_hi'),
  'archive.to_s3 exports the 16000-row partition with compress on');

create temporary table gzm_obj as select * from t16.fetch('public.gzm', 'gzm/' || :'gzm_child' || '.ndjson.gz');

select is((select status from gzm_obj), 200, 'the object lands at <prefix><child>.ndjson.gz');
select cmp_ok((select substring(etag from '-([0-9]+)"?$')::int from gzm_obj), '>=', 2,
  'LIVENESS: the ETag carries a part count of two or more, so this object came through multipart');
select is((select encode(substring(bytes from 1 for 3), 'hex') from gzm_obj), '1f8b08',
  'and it starts with a gzip member: magic 1f 8b, compression method 08 (deflate)');
select is((select ctype from gzm_obj), 'application/gzip', 'stored with Content-Type application/gzip');
select is(t16.object_status('public.gzm', 'gzm/' || :'gzm_child' || '.ndjson'), 404,
  'nothing was written at the plain .ndjson key');
select ok((select o.status = 200 and octet_length(o.bytes) < (select octet_length(bytes) from gzm_expect) from gzm_obj o),
  'the object is smaller than the NDJSON it holds: compressed, not plain text under a .gz name');

insert into t16.obj (label, bytes, expected_md5, expected_ids)
  select 'multipart', o.bytes, md5(e.bytes), t16.ids(format('public.%I', :'gzm_child')::regclass) from gzm_obj o, gzm_expect e;

-- =====================================================================================================
-- 3. Control: compress off, the plain object at the plain key and nothing at the .gz key
-- =====================================================================================================

insert into public.gz (id, payload) values (55, 'fifty-five'), (56, 'fifty-six');
select mk_archive_config('gz', false);

select ok(not (select compress from archive.config where parent_table = 'public.gz'::regclass),
  'LIVENESS: archive.config.compress is now off for public.gz');

select c.relname as ctl_child from public.gz t join pg_class c on c.oid = t.tableoid where t.id = 55 \gset
select lo as ctl_lo, hi as ctl_hi from pgpm.part where parent_table = 'public.gz'::regclass and child_name = :'ctl_child' \gset

select is(t16.clear_object('public.gz', 'gz/' || :'ctl_child' || '.ndjson'), 404,
  'setup: no object at the plain key before the control export');
select is(t16.clear_object('public.gz', 'gz/' || :'ctl_child' || '.ndjson.gz'), 404,
  'setup: no object at the .gz key before the control export');

select lives_ok(
  format($$ select archive.to_s3('public.gz', %L, %L, %L) $$, :'ctl_child', :'ctl_lo', :'ctl_hi'),
  'control: archive.to_s3 exports the 2-row partition with compress off');

create temporary table ctl_obj as select * from t16.fetch('public.gz', 'gz/' || :'ctl_child' || '.ndjson');

select is((select status from ctl_obj), 200, 'control: the object lands at the plain .ndjson key');
select is(
  (select array_agg((l::jsonb ->> 'id')::int order by (l::jsonb ->> 'id')::int)
     from ctl_obj, regexp_split_to_table(convert_from(bytes, 'UTF8'), e'\n') l where l <> ''),
  array[55, 56],
  'control: it is plain NDJSON naming ids 55 and 56');
select is((select ctype from ctl_obj), 'application/x-ndjson', 'control: stored with Content-Type application/x-ndjson');
select is(t16.object_status('public.gz', 'gz/' || :'ctl_child' || '.ndjson.gz'), 404,
  'control: nothing at the .gz key');

select * from finish();

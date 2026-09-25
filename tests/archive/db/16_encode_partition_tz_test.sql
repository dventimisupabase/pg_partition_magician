-- The S3 transports behind pgpm.archive_to_s3_ndjson and pgpm.archive_to_s3_parquet
-- (archive._encode_upload_ndjson_single and archive._encode_upload_parquet) translate the chunk's native
-- [p_lo, p_hi) into column literals with pgpm._encode, and used to leave out its last parameter, the
-- zone, which defaults to UTC (issue #501). Every reader of a chunk in pgpm_core passes
-- config.partition_tz. On a timestamptz column the two renderings name the same instant and nothing is
-- wrong. On a NAIVE `timestamp` column PostgreSQL drops the literal's offset and keeps its wall clock,
-- so the wall clock has to be the one in partition_tz: rendered in UTC, a grid recorded in
-- America/New_York had its chunk read five hours late. The object held the wrong hour's rows,
-- rows_archived counted them, and covered_hi = p_hi still opened retire()'s drop gate for rows that had
-- never been uploaded.
--
-- The fixture is the issue's own, asymmetric so that no two errors can cancel: under America/New_York,
-- two rows at wall 10:15 and 10:45 on 2024-01-02 and one at wall 15:30 the same day, 15:00 being the
-- hour the UTC rendering of 10:00-05 names. Transmuted under New York on an hourly grid, all three land
-- in the monolith, whose own [lo, hi) from pgpm.part is handed to each strategy exactly as
-- pgpm._archive_step hands it. The archiving session then runs under UTC, as pg_cron's does. Witnesses
-- first: the grid really is recorded in a zone other than the session's, the column really is naive,
-- and the two renderings of the same [lo, hi) really select different rows on it (three against one),
-- so a correct object could not come from a fixture the defect never had a chance to touch. The
-- objects' keys are cleared and witnessed absent before the exports, because the bucket outlives a
-- test database and a stale object from an earlier run at the same key would satisfy every read-back
-- below. Then each object is read straight back from MinIO and checked by row identity, not by count.
select plan(17);

set timezone = 'America/New_York';
create table public.tz16 (ts timestamp not null, id int not null, payload text, primary key (ts, id));
insert into public.tz16 (ts, id, payload) values
  ('2024-01-02 10:15:00', 1, 'in-a'),
  ('2024-01-02 10:45:00', 2, 'in-b'),
  ('2024-01-02 15:30:00', 3, 'twin');   -- the hour the UTC rendering of the child's lo names
call pgpm.transmute('public.tz16', 'ts', interval '1 hour');
set timezone = 'UTC';   -- the archiving session: pg_cron runs under the cluster's zone

select mk_archive_config('tz16', false);

-- the child pgpm will hand the strategies, located by tableoid rather than by name, with its own bounds
select p.child_name as child, p.lo, p.hi from pgpm.part p
 where p.parent_table = 'public.tz16'::regclass
   and exists (select 1 from public.tz16 t where t.id = 1 and t.tableoid = to_regclass(format('public.%I', p.child_name))) \gset
-- the keys the transports derive from the chunk: prefix, the parent's regclass text (which omits a schema
-- the search_path reaches, so `tz16` here), the digits of lo, the format
select 'tz16/' || 'public.tz16'::regclass::text || '_' || regexp_replace(:'lo', '[^0-9]', '', 'g') || '.ndjson'  as nd_key,
       'tz16/' || 'public.tz16'::regclass::text || '_' || regexp_replace(:'lo', '[^0-9]', '', 'g') || '.parquet' as pq_key \gset

-- ---------------------------------------------------------------------------
-- Witnesses: the conditions for the defect are present
-- ---------------------------------------------------------------------------

select is((select partition_tz from pgpm.config where parent_table = 'public.tz16'::regclass), 'America/New_York',
  'LIVENESS: the grid is recorded in America/New_York');

select is(current_setting('TimeZone'), 'UTC',
  'LIVENESS: the archiving session runs in UTC, not the grid''s zone');

select is(pgpm._control_naive('public.tz16'::regclass, 'ts'), true,
  'LIVENESS: the control column is a naive timestamp, which keeps a literal''s wall clock and drops its offset');

select is(
  (select array_agg(t.id order by t.id) from public.tz16 t where t.tableoid = to_regclass(format('public.%I', :'child'))),
  array[1, 2, 3],
  'LIVENESS: the child handed to the strategies holds ids 1, 2 and 3');

select is(
  (select array_agg(id order by id) from public.tz16
    where ts >= pgpm._encode('time', :'lo', null, null, null, null, null, 0, '1970-01-01 00:00:00+00', 'America/New_York')::timestamp
      and ts <  pgpm._encode('time', :'hi', null, null, null, null, null, 0, '1970-01-01 00:00:00+00', 'America/New_York')::timestamp),
  array[1, 2, 3],
  'LIVENESS: [lo, hi) rendered in partition_tz, as pgpm_core renders it, selects exactly ids 1, 2 and 3 on this column');

select is(
  (select array_agg(id order by id) from public.tz16
    where ts >= pgpm._encode('time', :'lo', null, null, null, null, null, 0, '1970-01-01 00:00:00+00', 'UTC')::timestamp
      and ts <  pgpm._encode('time', :'hi', null, null, null, null, null, 0, '1970-01-01 00:00:00+00', 'UTC')::timestamp),
  array[3],
  'LIVENESS: the same [lo, hi) rendered in UTC, the default the transports fell back to, selects id 3 alone: the fixture tells the two renderings apart');

create schema pgpm_test16;

-- DELETE the key, then report the GET status: 404 means the export below starts from an empty key.
create function pgpm_test16.clear_object(p_parent regclass, p_key text) returns int
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  perform archive.s3_signed_request('DELETE', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  return v_resp.status;
end;
$$;

create function pgpm_test16.fetch_ndjson_ids(p_parent regclass, p_key text) returns int[]
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then
    raise exception 'fetch of % failed: HTTP %', p_key, v_resp.status;
  end if;
  return (select array_agg((l::jsonb ->> 'id')::int order by (l::jsonb ->> 'id')::int)
            from regexp_split_to_table(v_resp.content, e'\n') l where l <> '');
end;
$$;

-- pgsql-http hands a binary body back as text that reinterprets its bytes, and text_to_bytea reverses
-- that reinterpretation, so a Parquet object comes back byte-for-byte (the idiom tests/archive/db/13 uses).
create function pgpm_test16.fetch_object(p_parent regclass, p_key text) returns bytea
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then
    raise exception 'fetch of % failed: HTTP %', p_key, v_resp.status;
  end if;
  return text_to_bytea(v_resp.content);
end;
$$;

select is(pgpm_test16.clear_object('public.tz16', :'nd_key'), 404,
  'LIVENESS: no object at the NDJSON key before the export, so what is read back came from THIS export');

select is(pgpm_test16.clear_object('public.tz16', :'pq_key'), 404,
  'LIVENESS: no object at the Parquet key before the export');

-- ---------------------------------------------------------------------------
-- The exports, handed the child's own [lo, hi) exactly as pgpm._archive_step hands it
-- ---------------------------------------------------------------------------

create temp table nd as select (r).* from (select pgpm.archive_to_s3_ndjson('public.tz16', :'child', :'lo', :'hi') r) s;
create temp table pq as select (r).* from (select pgpm.archive_to_s3_parquet('public.tz16', :'child', :'lo', :'hi') r) s;

select is((select s3_key from nd), :'nd_key',
  'LIVENESS: the NDJSON strategy wrote the key that was witnessed empty');

select is((select s3_key from pq), :'pq_key',
  'LIVENESS: the Parquet strategy wrote the key that was witnessed empty');

select is((select covered_hi from nd), :'hi',
  'LIVENESS: the NDJSON strategy reports the whole chunk covered, which is what opens retire()''s drop gate');

select is((select covered_hi from pq), :'hi',
  'LIVENESS: the Parquet strategy reports the whole chunk covered');

-- ---------------------------------------------------------------------------
-- The objects hold the child's rows, by identity
-- ---------------------------------------------------------------------------

select is(pgpm_test16.fetch_ndjson_ids('public.tz16', :'nd_key'), array[1, 2, 3],
  'the NDJSON object holds exactly the child''s rows, ids 1, 2 and 3');

select is((select rows_archived from nd), 3::bigint,
  'and NDJSON rows_archived is the 3 rows the child holds (1 would be the 15:00 twin alone)');

select is(
  pgpm_test16.fetch_object('public.tz16', :'pq_key'),
  archive._pq_to_parquet_range('public.tz16', 'ts',
    pgpm._encode('time', :'lo', null, null, null, null, null, 0, '1970-01-01 00:00:00+00', 'America/New_York'),
    pgpm._encode('time', :'hi', null, null, null, null, null, 0, '1970-01-01 00:00:00+00', 'America/New_York'),
    false),
  'the Parquet object is byte-for-byte the encoding of [lo, hi) rendered in partition_tz');

select ok(
  (select position(convert_to('in-a', 'UTF8') in bytes) > 0
      and position(convert_to('in-b', 'UTF8') in bytes) > 0
      and position(convert_to('twin', 'UTF8') in bytes) > 0
     from (select pgpm_test16.fetch_object('public.tz16', :'pq_key') as bytes) o),
  'rows by identity: in-a, in-b and twin are all in the Parquet object (the defect kept twin alone)');

select is((select rows_archived from pq), 3::bigint,
  'and Parquet rows_archived is the 3 rows the child holds');

select * from finish();

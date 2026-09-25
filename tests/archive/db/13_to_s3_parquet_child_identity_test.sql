-- archive.to_s3_parquet took its child as a bare name and cast it to regclass, so the name resolved
-- through the CALLER's search_path rather than in the parent's schema (issue #464). From a session
-- whose search_path did not reach a managed table's schema, the real child was refused with
-- `relation does not exist`; and once any relation of the same name existed in public, that
-- relation's rows went out under the partition's key, with HTTP 200 and no error. archive.to_s3
-- resolved `%I.%I` from the parent's namespace and was right about the schema, but neither function
-- compared what the name resolved to against the oid pgpm.part recorded for the partition, which
-- the automatic path has done before every read of a child since #421 (fail_archive_identity in
-- pgpm._archive_step).
--
-- Both now resolve p_child in the parent's schema (archive._resolve_child) and refuse, with a
-- `pg_partition_magician:` error naming both oids, a relation that has taken a partition's name.
-- The fixture is the issue's own: a managed table in schema app, a session whose search_path is the
-- default `"$user", public`, and a same-named decoy in public with rows of its own. Every negative
-- is paired with a witness that the condition it denies was present: the decoy exists, differs from
-- the real child, and is what the bare name resolves to from this session; the object's key is
-- cleared and witnessed absent before each export, because the bucket outlives a test database and a
-- stale object from an earlier run at the same key would otherwise satisfy a read-back.
select plan(32);

set search_path = "$user", public;

-- ======================= PART A: the real child, archived past a decoy =======================

-- 50 rows in one partition, [0, 60), of a table that lives OUTSIDE the search_path.
create schema app;
create table app.evts (id bigint primary key, payload text);
insert into app.evts (id, payload) select g, 'REAL-app-row-' || g from generate_series(1, 50) g;
call pgpm.transmute('app.evts', 'id', 60::bigint);
select archive.configure('app.evts'::regclass, 'archive-test-bucket',
  p_endpoint => 'http://minio:9000', p_prefix => 'a13_child_identity/', p_compress => false);

select child_name as child, lo, hi from pgpm.part where parent_table = 'app.evts'::regclass and lo = '0' \gset
select format('app.%I', :'child')::regclass::oid as real_oid \gset
select 'a13_child_identity/' || :'child' || '.parquet' as pq_key,
       'a13_child_identity/' || :'child' || '.ndjson'  as nd_key \gset

create schema pgpm_test13;

create function pgpm_test13.rowcount(p_rel regclass) returns int
language plpgsql as $$
declare n int;
begin
  execute format('select count(*) from %s', p_rel) into n;
  return n;
end;
$$;

-- GET status alone: 404 is the witness that a key is empty.
create function pgpm_test13.object_status(p_parent regclass, p_key text) returns int
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
create function pgpm_test13.clear_object(p_parent regclass, p_key text) returns int
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  perform archive.s3_signed_request('DELETE', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  return pgpm_test13.object_status(p_parent, p_key);
end;
$$;

-- The object's bytes. http_response.content is text, but the extension fills it by reinterpreting the
-- body's bytes rather than re-encoding them, and text_to_bytea reverses that reinterpretation, so a
-- binary Parquet object (stray 0x00 and high bytes in its Thrift footer) comes back byte-for-byte.
create function pgpm_test13.fetch_object(p_parent regclass, p_key text) returns bytea
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

create function pgpm_test13.fetch_ndjson_lines(p_parent regclass, p_key text) returns setof jsonb
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
  return query select l::jsonb from regexp_split_to_table(v_resp.content, e'\n') l where l <> '';
end;
$$;

-- --- Witnesses: the session cannot see the real child by its bare name --------------------

select is(current_setting('search_path'), '"$user", public',
  'setup: the session search_path is the default, "$user", public');

select ok('app' <> all (current_schemas(true)),
  'witness: app is not on the search_path, so a bare child name cannot resolve to the real child');

select is(to_regclass(:'child'), null::regclass,
  'witness: before the decoy exists, the bare child name resolves to nothing from this session');

select is(
  (select child_oid from pgpm.part where parent_table = 'app.evts'::regclass and child_name = :'child'),
  :'real_oid'::oid,
  'LIVENESS: pgpm.part records WHICH relation the child is, by oid, so the identity check has an anchor');

select is(pgpm_test13.rowcount(:'real_oid'::oid::regclass), 50,
  'setup: the real child holds the 50 REAL rows');

-- --- The decoy: same name, different schema, different rows -------------------------------

select format('create table public.%I (id bigint, payload text)', :'child') \gexec
select format($$ insert into public.%I (id, payload) select g, 'DECOY-public-row-' || g from generate_series(1, 3) g $$, :'child') \gexec
select format('public.%I', :'child')::regclass::oid as decoy_oid \gset

select is(to_regclass(:'child')::oid, :'decoy_oid'::oid,
  'LIVENESS: the bare child name now resolves, through search_path, to the decoy in public');

select isnt(:'decoy_oid'::oid, :'real_oid'::oid,
  'LIVENESS: and the decoy is a different relation from the real child');

select is(pgpm_test13.rowcount(:'decoy_oid'::oid::regclass), 3,
  'LIVENESS: the decoy has 3 rows of its own, so an export of it cannot pass for an export of the real 50');

select isnt(
  archive._pq_to_parquet(:'real_oid'::oid::regclass, false),
  archive._pq_to_parquet(:'decoy_oid'::oid::regclass, false),
  'LIVENESS: the two relations encode to different Parquet objects, so the equality below discriminates');

-- --- Parquet: the object is the real child's ----------------------------------------------

select is(pgpm_test13.clear_object('app.evts', :'pq_key'), 404,
  'setup: no object at the Parquet key before the export, so what is read back came from THIS export');

select lives_ok(
  format($$ select archive.to_s3_parquet('app.evts', %L, %L, %L) $$, :'child', :'lo', :'hi'),
  'archive.to_s3_parquet exports the child from a session whose search_path does not reach the parent''s schema');

create temporary table obj_a as select pgpm_test13.fetch_object('app.evts', :'pq_key') as bytes;

select is(
  (select bytes from obj_a),
  archive._pq_to_parquet(:'real_oid'::oid::regclass, false),
  'the object is byte-for-byte the Parquet encoding of the REAL child in app: its 50 rows and nothing else');

select ok(
  (select position(convert_to('REAL-app-row-7', 'UTF8') in bytes) > 0
      and position(convert_to('REAL-app-row-50', 'UTF8') in bytes) > 0 from obj_a),
  'sample rows by identity: REAL-app-row-7 and REAL-app-row-50 are in the object');

select is(
  (select position(convert_to('DECOY-public-row-1', 'UTF8') in bytes) from obj_a), 0,
  'and no decoy row is: DECOY-public-row-1 is absent');

-- --- NDJSON: archive.to_s3 from the same session, past the same decoy ----------------------

select is(pgpm_test13.clear_object('app.evts', :'nd_key'), 404,
  'setup: no object at the NDJSON key before the export');

select lives_ok(
  format($$ select archive.to_s3('app.evts', %L, %L, %L) $$, :'child', :'lo', :'hi'),
  'archive.to_s3 exports the same child from the same session');

select set_eq(
  format($$ select (doc ->> 'id')::bigint, doc ->> 'payload' from pgpm_test13.fetch_ndjson_lines('app.evts', %L) doc $$, :'nd_key'),
  $$ select id, payload from app.evts $$,
  'the NDJSON object''s (id, payload) identities are exactly the real child''s: nothing from the decoy');

-- ============ PART B: a child that is not in the parent's schema is refused, clearly ============
--
-- The name exists, but only in public, where search_path would find it. Resolving in the parent's
-- schema must say so rather than surface a bare `relation does not exist` or, worse, export it.

create table public.evts_only_in_public (id bigint, payload text);

select ok(to_regclass('evts_only_in_public') is not null,
  'LIVENESS: the bare name resolves through search_path, so a search_path lookup would have found it');

select throws_like(
  $$ select archive.to_s3_parquet('app.evts', 'evts_only_in_public', '0', '60') $$,
  '%pg_partition_magician: app.evts_only_in_public does not exist%',
  'archive.to_s3_parquet refuses a child that is not in the parent''s schema with a clear message, not a search_path hit');

select throws_like(
  $$ select archive.to_s3('app.evts', 'evts_only_in_public', '0', '60') $$,
  '%pg_partition_magician: app.evts_only_in_public does not exist%',
  'archive.to_s3 refuses it the same way');

-- ============ PART C: a relation that has taken the partition's name is refused ============
--
-- The substitution tests/104 and the #421 work stage: the partition is renamed aside and an
-- unrelated relation takes the name it vacated, IN the parent's schema this time, so schema
-- resolution alone cannot tell them apart. Only the recorded oid can.

select format('alter table app.%I rename to evts_kept_aside', :'child') \gexec
select format('create table app.%I (id bigint, payload text)', :'child') \gexec
select format($$ insert into app.%I (id, payload) values (1, 'SUBSTITUTE-app-row-1') $$, :'child') \gexec
select format('app.%I', :'child')::regclass::oid as impostor_oid \gset

select isnt(:'impostor_oid'::oid, :'real_oid'::oid,
  'LIVENESS: the partition''s name in app now answers to a DIFFERENT relation than pgpm recorded');

select is(
  (select child_oid from pgpm.part where parent_table = 'app.evts'::regclass and child_name = :'child'),
  :'real_oid'::oid,
  'LIVENESS: pgpm.part still anchors the name to the original relation (a rename does not change an oid)');

select is(pgpm_test13.rowcount(:'impostor_oid'::oid::regclass), 1,
  'LIVENESS: the impostor has a row of its own, so an export of it would be visible');

select is(pgpm_test13.clear_object('app.evts', :'pq_key'), 404,
  'setup: the Parquet key is cleared again, so a refusal below can be shown to have uploaded nothing');

select is(pgpm_test13.clear_object('app.evts', :'nd_key'), 404,
  'setup: and the NDJSON key');

select throws_like(
  format($$ select archive.to_s3_parquet('app.evts', %L, %L, %L) $$, :'child', :'lo', :'hi'),
  format('%%pg_partition_magician: app.%s is oid %s now, not the oid %s recorded for this partition; refusing to archive it%%',
         :'child', :'impostor_oid', :'real_oid'),
  'archive.to_s3_parquet refuses a relation that has taken the partition''s name, naming both oids, as fail_archive_identity does');

select throws_like(
  format($$ select archive.to_s3('app.evts', %L, %L, %L) $$, :'child', :'lo', :'hi'),
  format('%%pg_partition_magician: app.%s is oid %s now, not the oid %s recorded for this partition; refusing to archive it%%',
         :'child', :'impostor_oid', :'real_oid'),
  'archive.to_s3 refuses it the same way');

select is(pgpm_test13.object_status('app.evts', :'pq_key'), 404,
  'and the Parquet refusal uploaded nothing: the key is still empty (fail closed)');

select is(pgpm_test13.object_status('app.evts', :'nd_key'), 404,
  'nor did the NDJSON refusal');

-- ============ PART D: a null anchor is unanchored and skips the check ============
--
-- Same as everywhere else in pgpm: a row with no recorded oid (one that predates child_oid and
-- whose name did not resolve at upgrade time) has nothing to compare against, and refusing on it
-- would wedge a manual archive that nothing can un-wedge. The boundary is asserted, not inferred.

update pgpm.part set child_oid = null where parent_table = 'app.evts'::regclass and child_name = :'child';

select is(
  (select child_oid from pgpm.part where parent_table = 'app.evts'::regclass and child_name = :'child'),
  null::oid,
  'setup: the anchor is cleared, as for a row pgpm has no recorded oid for');

select lives_ok(
  format($$ select archive.to_s3_parquet('app.evts', %L, %L, %L) $$, :'child', :'lo', :'hi'),
  'an unanchored row skips the identity check, so an upgrade never wedges a manual archive it has nothing to compare against');

select is(
  pgpm_test13.fetch_object('app.evts', :'pq_key'),
  archive._pq_to_parquet(:'impostor_oid'::oid::regclass, false),
  'and what went out is the relation the name resolves to in the parent''s schema now: the impostor''s one row');

select * from finish();

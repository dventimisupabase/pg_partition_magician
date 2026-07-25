-- Real S3 archive strategies on the archive_fn contract (issue #239; see
-- docs/retention-write-block-and-merge.md, #242). pgpm.archive_to_s3_ndjson /
-- pgpm.archive_to_s3_parquet adapt archive.to_s3 / archive.to_s3_parquet's transport --
-- archive._encode_upload_ndjson_single / archive._encode_upload_parquet, the SAME
-- encode/upload steps the paced worker already uses and 01/03/04 already exercise
-- against real MinIO -- onto pgpm.config.archive_fn's contract, so a table can set
-- archive_fn directly and ride pgpm.maintain()'s own byte-budget chunking
-- (pgpm._next_archive_chunk/_archive_step, #237) instead of archive.config's separate
-- boundary_rule/drop_trigger machinery. Connection settings (bucket/endpoint/prefix/vault
-- key names/compress) still come from archive.config -- one config surface, not two.
--
-- Proves the adapter end to end: dispatched via pgpm._run_archive_strategy, chunked via
-- pgpm._archive_step, ledgered into pgpm.archive_ledger WITH s3_key/etag actually populated
-- (the gap #237's own comment flagged: "s3_key/etag stay null until a real strategy (#239)
-- has something to put there"), and the uploaded object is real -- fetched straight back
-- from MinIO and its row count checked, not just the ledger's own bookkeeping trusted.
--
-- retain_batch is forced to 0 on both fixtures so pgpm.maintain()'s own pgpm.retain() call
-- never drops what this test wants to keep inspecting via pgpm.part/_archive_fully_covered
-- afterward -- deliberately decoupled from whatever retire()'s drop precondition happens to
-- be on this branch (pre- or post-#238), since that is not what this test is about.
select plan(10);

-- --- Part A: pgpm.archive_to_s3_ndjson -------------------------------------------------

select mk_archive_table('a8', 5000, 1000, 3000);   -- monolith [0, 6000), premakes 4 ahead
insert into public.a8 (id, payload) select g, 'y' from generate_series(6001, 6005) g;   -- into [6000,7000)
insert into public.a8 (id, payload) select g, 'z' from generate_series(7001, 7005) g;   -- into [7000,8000)
insert into public.a8 (id, payload) values (11000, 'frontier');   -- advances the frontier to 11000

select mk_archive_config('a8', 'partition_aligned', 'gate_only', 'ndjson_single', false);
update pgpm.config set retain_batch = 0, paused = false where parent_table = 'public.a8'::regclass;
update pgpm.config set archive_fn = 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure
  where parent_table = 'public.a8'::regclass;

-- boundary = grid_floor(11000 - 3000, 1000) = 8000: eligible = monolith [0,6000), [6000,7000),
-- [7000,8000), the same shape as 04's own Part A fixture (transplanted directly so the
-- eligibility math is already proven). One maintain() tick both write-blocks every eligible
-- child (#235) and archives each of them in a single chunk (the default 8 MiB byte budget
-- comfortably covers each one).
select pgpm.maintain('public.a8');

select is(
  (select count(*)::int from pgpm.archive_ledger where parent_table = 'public.a8'::regclass),
  3, 'one maintain() tick wrote one ledger row per eligible child');

select is(
  (select coalesce(sum(rows_archived), 0)::bigint from pgpm.archive_ledger where parent_table = 'public.a8'::regclass),
  5010::bigint, 'rows_archived sums to the monolith (5000) plus the two live inserts (5 + 5)');

select is(
  (select count(*)::int from pgpm.archive_ledger where parent_table = 'public.a8'::regclass and s3_key is null),
  0, 'every ledger row carries a real s3_key -- the contract gap #237 left open is now closed');

select is(
  (select count(*)::int from pgpm.archive_ledger where parent_table = 'public.a8'::regclass and etag is null),
  0, 'every ledger row also carries the ETag MinIO returned for its PUT');

select ok(
  pgpm._archive_fully_covered('public.a8', (select child_name from pgpm.part where parent_table = 'public.a8'::regclass and lo = '0')),
  'the monolith is fully covered after the single tick');

-- fetch the monolith's uploaded object straight back from MinIO: proof the object genuinely
-- holds every row, not just what the ledger claims.
create schema pgpm_test08;
create function pgpm_test08.fetch_ndjson_row_count(p_parent regclass, p_key text) returns int
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
  return (select count(*) from regexp_split_to_table(v_resp.content, e'\n') l where l <> '');
end;
$$;

select is(
  pgpm_test08.fetch_ndjson_row_count('public.a8'::regclass,
    (select s3_key from pgpm.archive_ledger where parent_table = 'public.a8'::regclass and lo = '0')),
  5000, 'the monolith''s uploaded NDJSON object round-trips exactly 5000 lines');

-- --- Part B: pgpm.archive_to_s3_parquet -------------------------------------------------

select mk_archive_table('a8p', 5000, 1000, 3000);
insert into public.a8p (id, payload) select g, 'y' from generate_series(6001, 6005) g;
insert into public.a8p (id, payload) select g, 'z' from generate_series(7001, 7005) g;
insert into public.a8p (id, payload) values (11000, 'frontier');

select mk_archive_config('a8p', 'partition_aligned', 'gate_only', 'parquet', false);
update pgpm.config set retain_batch = 0, paused = false where parent_table = 'public.a8p'::regclass;
update pgpm.config set archive_fn = 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure
  where parent_table = 'public.a8p'::regclass;

select pgpm.maintain('public.a8p');

select is(
  (select count(*)::int from pgpm.archive_ledger where parent_table = 'public.a8p'::regclass),
  3, 'one maintain() tick wrote one ledger row per eligible child (parquet)');

select is(
  (select coalesce(sum(rows_archived), 0)::bigint from pgpm.archive_ledger where parent_table = 'public.a8p'::regclass),
  5010::bigint, 'rows_archived sums to the monolith (5000) plus the two live inserts (5 + 5) (parquet)');

select is(
  (select count(*)::int from pgpm.archive_ledger
    where parent_table = 'public.a8p'::regclass and s3_key like '%.parquet' and etag is not null),
  3, 'every uploaded object key carries the parquet extension and a real ETag');

select ok(
  pgpm._archive_fully_covered('public.a8p', (select child_name from pgpm.part where parent_table = 'public.a8p'::regclass and lo = '0')),
  'the monolith is fully covered after the single tick (parquet)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

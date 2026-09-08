-- Real S3 archive strategies on the archive_fn contract (issue #239).
-- pgpm.archive_to_s3_ndjson /
-- pgpm.archive_to_s3_parquet adapt the encode/upload transport archive._encode_upload_ndjson_single
-- / archive._encode_upload_parquet onto pgpm.config.archive_fn's contract, so a table can set
-- archive_fn directly and ride pgpm.maintain()'s own byte-budget chunking
-- (pgpm._next_archive_chunk/_archive_step, #237). Connection settings (bucket/endpoint/prefix/
-- vault key names/compress) still come from archive.config -- one config surface, not two.
--
-- Proves the adapter end to end: dispatched via pgpm._run_archive_strategy, chunked via
-- pgpm._archive_step, ledgered into pgpm.archive_ledger WITH s3_key/etag actually populated
-- (the gap #237's own comment flagged: "s3_key/etag stay null until a real strategy (#239)
-- has something to put there"), and the uploaded object is real -- fetched straight back
-- from MinIO and its row count checked, not just the ledger's own bookkeeping trusted.
--
-- retain_batch is forced to 0 on both fixtures so pgpm.maintain()'s own pgpm.retain() call never
-- drops what this test wants to keep inspecting via pgpm.part/_archive_fully_covered afterward --
-- this test is about the archive_fn adapter, not retire()'s drop precondition (tests/64 covers that).
select plan(19);

-- --- Part A: pgpm.archive_to_s3_ndjson -------------------------------------------------

call mk_archive_table('a8', 5000, 1000, 3000, p_paused => false);   -- monolith [0, 6000), premakes 4 ahead
insert into public.a8 (id, payload) select g, 'y' from generate_series(6001, 6005) g;   -- into [6000,7000)
insert into public.a8 (id, payload) select g, 'z' from generate_series(7001, 7005) g;   -- into [7000,8000)
insert into public.a8 (id, payload) values (11000, 'frontier');   -- advances the frontier to 11000

select mk_archive_config('a8', false);
update pgpm.config set retain_batch = 0, archive_batch = null where parent_table = 'public.a8'::regclass;
select pgpm.set_archive_fn('public.a8', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);

-- boundary = grid_floor(11000 - 3000, 1000) = 8000: eligible = monolith [0,6000), [6000,7000),
-- [7000,8000), the same shape as 04's own Part A fixture (transplanted directly so the
-- eligibility math is already proven). One maintain() tick both write-blocks every eligible
-- child (#235) and archives each of them in a single chunk (the default 8 MiB byte budget
-- comfortably covers each one) -- archive_batch is explicitly set to null (unlimited) above so
-- this stays true; the DEFAULT (1, issue #351) would only archive one of the three per tick,
-- which tests/93 covers.
call pgpm.maintain('public.a8');

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

create function pgpm_test08.fetch_ndjson_ids(p_parent regclass, p_key text) returns text[]
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
  return (select array_agg(l::jsonb ->> 'id' order by l::jsonb ->> 'id')
            from regexp_split_to_table(v_resp.content, e'\n') l where l <> '');
end;
$$;

select is(
  pgpm_test08.fetch_ndjson_row_count('public.a8'::regclass,
    (select s3_key from pgpm.archive_ledger where parent_table = 'public.a8'::regclass and lo = '0')),
  5000, 'the monolith''s uploaded NDJSON object round-trips exactly 5000 lines');

-- --- Part B: pgpm.archive_to_s3_parquet -------------------------------------------------

call mk_archive_table('a8p', 5000, 1000, 3000, p_paused => false);
insert into public.a8p (id, payload) select g, 'y' from generate_series(6001, 6005) g;
insert into public.a8p (id, payload) select g, 'z' from generate_series(7001, 7005) g;
insert into public.a8p (id, payload) values (11000, 'frontier');

select mk_archive_config('a8p', false);
update pgpm.config set retain_batch = 0, archive_batch = null where parent_table = 'public.a8p'::regclass;
select pgpm.set_archive_fn('public.a8p', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);

call pgpm.maintain('public.a8p');

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

-- --- Part C: text_time bounds carry their stored codec configuration -------------------

create table public.a8t (id text primary key, payload text);
insert into public.a8t (id, payload) values
  (pgpm._ts_to_text_time('2026-01-10 00:00:00+00', 't', 8, 16, 's', '0123456789ABCDEF', 4,
                         '2026-01-01 00:00:00+00'), 'inside-first'),
  (pgpm._ts_to_text_time('2026-02-10 00:00:00+00', 't', 8, 16, 's', '0123456789ABCDEF', 4,
                         '2026-01-01 00:00:00+00'), 'inside-second'),
  (pgpm._ts_to_text_time('2026-03-10 00:00:00+00', 't', 8, 16, 's', '0123456789ABCDEF', 4,
                         '2026-01-01 00:00:00+00'), 'outside');

call pgpm.transmute('public.a8t', 'id', interval '1 month',
  p_tt_prefix => 't', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's',
  p_tt_alphabet => '0123456789ABCDEF', p_tt_discard_bits => 4,
  p_tt_epoch => '2026-01-01 00:00:00+00');
select mk_archive_config('a8t', false);

select results_eq(
  $$ select text_time_prefix, text_time_width, text_time_radix, text_time_unit,
            text_time_alphabet, text_time_discard_bits, text_time_epoch
       from pgpm.config where parent_table = 'public.a8t'::regclass $$,
  $$ values ('t'::text, 8, 16, 's'::text, '0123456789ABCDEF'::text, 4,
             timestamptz '2026-01-01 00:00:00+00') $$,
  'setup: the managed table stores every non-default text_time codec field');

create temporary table a8t_expected as
select array[
  pgpm._ts_to_text_time('2026-01-10 00:00:00+00', 't', 8, 16, 's', '0123456789ABCDEF', 4,
                        '2026-01-01 00:00:00+00'),
  pgpm._ts_to_text_time('2026-02-10 00:00:00+00', 't', 8, 16, 's', '0123456789ABCDEF', 4,
                        '2026-01-01 00:00:00+00')
] as ids;

select is(
  (select ids from a8t_expected),
  (select array_agg(id order by id) from public.a8t
    where id >= pgpm._ts_to_text_time('2026-01-01 00:00:00+00', 't', 8, 16, 's',
                                      '0123456789ABCDEF', 4, '2026-01-01 00:00:00+00')
      and id < pgpm._ts_to_text_time('2026-03-01 00:00:00+00', 't', 8, 16, 's',
                                     '0123456789ABCDEF', 4, '2026-01-01 00:00:00+00')),
  'setup: the archive range contains the two identified rows');

create temporary table a8t_ndjson_result as
select (r).* from (select pgpm.archive_to_s3_ndjson(
  'public.a8t', 'unused', '2026-01-01 00:00:00+00', '2026-03-01 00:00:00+00') r) s;

select is(
  pgpm_test08.fetch_ndjson_ids('public.a8t', (select s3_key from a8t_ndjson_result)),
  (select ids from a8t_expected),
  'NDJSON text_time archive contains exactly the two in-range row identities');

select ok(
  (select rows_archived = 2 and s3_key like '%.ndjson' and etag is not null from a8t_ndjson_result),
  'NDJSON text_time strategy reports the live two-row upload');

create temporary table a8t_parquet_result as
select (r).* from (select pgpm.archive_to_s3_parquet(
  'public.a8t', 'unused', '2026-01-01 00:00:00+00', '2026-03-01 00:00:00+00') r) s;

select ok(
  (select rows_archived = 2 and s3_key like '%.parquet' and etag is not null from a8t_parquet_result),
  'Parquet text_time strategy reports the same live two-row range');

-- --- Part D: a PascalCase (quoted-identifier) table name survives the S3 key -----------

-- archive._encode_upload_ndjson_single/_encode_upload_parquet build their S3 key from
-- p_parent::text (schema.table), which Postgres renders WITH double quotes for any identifier
-- that needs them -- e.g. public."A8Pascal". Before the fix (archive._s3_encode_path), that
-- literal '"' rode straight into the S3 request path unencoded: the canonical request used for
-- signing diverged from what actually went out over the wire, and the PUT failed with a 403
-- SignatureDoesNotMatch. This is exactly how it surfaced in production, against a Prisma-style
-- PascalCase table.
create table public."A8Pascal" (id bigint generated by default as identity primary key, payload text);
insert into public."A8Pascal" (payload) select 'x' from generate_series(1, 50);
call pgpm.transmute('public."A8Pascal"'::regclass, 'id', 100::bigint, p_paused => false);
select mk_archive_config('"A8Pascal"', false);

-- hi is exclusive (matches every other range call in this file, e.g. Part C's a8t case), and
-- the identity column starts at 1, so the 50 live rows carry ids 1..50 -- hi must be '51' to
-- include id 50, not '50'.
create temporary table a8pascal_ndjson_result as
select (r).* from (select pgpm.archive_to_s3_ndjson('public."A8Pascal"'::regclass, 'unused', '0', '51') r) s;

-- the liveness witness (house rule): prove the fixture actually exercises the dangerous
-- character, so "the upload succeeded" below cannot be satisfied by an accidentally-safe key.
select ok(
  (select s3_key like '%"%' from a8pascal_ndjson_result),
  'setup: the archived key genuinely carries the quote character that used to break signing');

select ok(
  (select rows_archived = 50 and s3_key like '%.ndjson' and etag is not null from a8pascal_ndjson_result),
  'NDJSON archive of a PascalCase (quoted-identifier) table succeeds');

select is(
  pgpm_test08.fetch_ndjson_row_count('public."A8Pascal"'::regclass, (select s3_key from a8pascal_ndjson_result)),
  50, 'the uploaded NDJSON object for the PascalCase table round-trips all 50 rows -- proof the GET signs the same quoted key correctly too, not just the PUT');

create temporary table a8pascal_parquet_result as
select (r).* from (select pgpm.archive_to_s3_parquet('public."A8Pascal"'::regclass, 'unused', '0', '51') r) s;

select ok(
  (select rows_archived = 50 and s3_key like '%.parquet' and etag is not null from a8pascal_parquet_result),
  'Parquet archive of a PascalCase (quoted-identifier) table succeeds too');

select * from finish();

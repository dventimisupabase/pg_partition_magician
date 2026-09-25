-- archive.to_s3, the synchronous NDJSON export, pages through the partition archive.config.fetch_rows
-- rows at a time and used to resume each page from the previous page's max(control). The control
-- column need not be unique, and a run of equal values straddling a page boundary lost everything
-- past the boundary: the cursor landed ON the tied value and the next page's `> cursor` skipped the
-- rest of the run, with HTTP 200 and no error (issue #463). The fix pages by the total order
-- (control, ctid), and refuses to complete an export whose written row count differs from the
-- partition's row count at the start.
--
-- The fixture is the issue's own: 30 rows tied at one timestamp plus 10 at a later one, exported
-- with a 10-row page, so the tie run spans three pages. Witnesses first (the tie really straddles a
-- page boundary; a 40-line object could otherwise come from a fixture that never exercised the
-- defect), then the object read straight back from MinIO and checked by row identity, not by count
-- alone: the lost rows were ids 11..30, and the assertions name them. The object's key is cleared
-- and witnessed absent before the export, because the bucket outlives a test database: a stale
-- object from an earlier run at the same key would otherwise satisfy every assertion below.
select plan(10);

create table public.tie_evts (ts timestamptz not null, id int not null, payload text, primary key (ts, id));
insert into public.tie_evts (ts, id, payload) select '2024-01-01 12:00:00+00', g, 'tied'  from generate_series(1, 30) g;
insert into public.tie_evts (ts, id, payload) select '2024-01-01 13:00:00+00', g, 'later' from generate_series(31, 40) g;
call pgpm.transmute('public.tie_evts', 'ts', interval '1 day');

select mk_archive_config('tie_evts', false);
update archive.config set fetch_rows = 10 where parent_table = 'public.tie_evts'::regclass;

-- the child holding every row, located by tableoid rather than by name: the monolith's hi is the
-- transmute-time frontier, so its name moves with the calendar.
select c.relname as child from public.tie_evts t join pg_class c on c.oid = t.tableoid where t.id = 1 \gset
select lo, hi from pgpm.part where parent_table = 'public.tie_evts'::regclass and child_name = :'child' \gset

-- --- Witnesses: the conditions for the defect are present ------------------------------------

select is((select count(distinct tableoid)::int from public.tie_evts), 1,
  'setup: all 40 rows sit in the one partition being exported');

select is((select count(*)::int from public.tie_evts where ts = '2024-01-01 12:00:00+00'), 30,
  'setup: 30 rows tie on the control column');

select is((select fetch_rows from archive.config where parent_table = 'public.tie_evts'::regclass), 10,
  'setup: a page is 10 rows, so the 30-row tie run cannot fit in one page');

select is(
  (select count(*)::int from public.tie_evts
    where ts = (select max(ts) from (select ts from public.tie_evts order by ts limit 10) first_page)),
  30, 'witness: the first 10-row page ends INSIDE the 30-row tie run, so the run straddles the page boundary');

-- --- The export, and the object read back --------------------------------------------------

create schema pgpm_test12;

-- DELETE the key, then report the GET status: 404 means this export starts from an empty key.
create function pgpm_test12.clear_object(p_parent regclass, p_key text) returns int
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

create function pgpm_test12.fetch_ndjson_lines(p_parent regclass, p_key text) returns setof jsonb
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

select is(
  pgpm_test12.clear_object('public.tie_evts', 'tie_evts/' || :'child' || '.ndjson'), 404,
  'setup: no object at the key before the export, so what is read back below came from THIS export');

select lives_ok(
  format($$ select archive.to_s3('public.tie_evts', %L, %L, %L) $$, :'child', :'lo', :'hi'),
  'archive.to_s3 exports the partition');

create temporary table tie_object as
select doc from pgpm_test12.fetch_ndjson_lines('public.tie_evts', 'tie_evts/' || :'child' || '.ndjson') doc;

select is((select count(*)::int from tie_object), 40,
  'the object holds 40 lines: the partition''s 30 tied rows plus its 10 later rows');

select is(
  (select array_agg((doc ->> 'id')::int order by (doc ->> 'id')::int) from tie_object
    where (doc ->> 'ts')::timestamptz = '2024-01-01 12:00:00+00'),
  (select array_agg(g) from generate_series(1, 30) g),
  'every tied row is present by identity, ids 1..30, including 11..30 past the first page boundary');

select is(
  (select array_agg((doc ->> 'id')::int order by (doc ->> 'id')::int) from tie_object
    where (doc ->> 'ts')::timestamptz = '2024-01-01 13:00:00+00'),
  (select array_agg(g) from generate_series(31, 40) g),
  'and the 10 later rows are present by identity, ids 31..40');

select set_eq(
  $$ select (doc ->> 'ts')::timestamptz, (doc ->> 'id')::int from tie_object $$,
  $$ select ts, id from public.tie_evts $$,
  'the object''s (ts, id) identities are exactly the partition''s: nothing lost, nothing duplicated');

select * from finish();

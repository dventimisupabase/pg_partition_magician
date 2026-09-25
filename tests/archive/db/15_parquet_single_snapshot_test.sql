-- Every column of a Parquet file comes from ONE snapshot (issue #462).
--
-- archive._pq_encode_column_data runs one query per column, and a VOLATILE plpgsql function under
-- READ COMMITTED takes a fresh snapshot for every statement it runs. Before #462 both encoders
-- pointed those queries straight at the relation: N snapshots for N columns, plus one more for the
-- count(*) that sized the page headers. A row committing between two column reads was in the later
-- columns and not the earlier ones, and from that column on every value sat one row away from the
-- row it belonged to. The file stayed well-formed (every column had exactly count(*) values), so no
-- reader could tell: the hunt read 8000 of 8000 rows with a tag belonging to a different row's id.
-- Now archive._pq_snapshot materialises the rows in one statement and every column is read from
-- that, so a write that commits mid-encode is either wholly in the file or wholly out of it.
--
-- HOW THE RACE IS BUILT. The encode runs in a second session (dblink, asynchronously), so this
-- session is free to commit a write while it runs and to bracket that commit with clock readings of
-- its own. The write is timed at 40% of a calibrated quiescent encode of the same table: with
-- compression on, compressing the ~540-byte payload column is the bulk of the wall time, and that
-- column sits between `id` (read before it) and `tag` (read after it), so on the pre-fix code a
-- commit anywhere in roughly the 5%-95% band lands between those two reads. The proportion is a
-- property of the data shape, not of the machine, which is why the delay is calibrated rather than
-- fixed. The fixed code is indifferent to when the commit lands.
--
-- WHAT IS ASSERTED. Identity, not shape: the racy file must be byte-identical to one of the two
-- files a single snapshot could have produced, the quiescent encode taken before the write or the
-- one taken after it. A well-formedness check passes against the defect (that was the point of the
-- issue), and a row-count check is exactly what count(*) already got wrong. Every negative is paired
-- with the witness that its conditions held: the write committed strictly inside the encode window
-- (this session's own statements bracket the commit; the wrapper around the encode records its
-- start and end), the write actually changed what a single-snapshot encode produces (before <>
-- after), and the write's effect is visible afterwards. The mechanism is witnessed directly too: a
-- quiescent encode scans the relation exactly once. The independent-reader half, pyarrow reading the
-- same racy files back and asserting id = tag on every row, is bench/archive_parquet_snapshot.sh,
-- which also runs this file against a mutant that puts the per-column statements back
-- (bench/mutations/mutate.py: parquet_per_column_statements).
select plan(18);

create extension if not exists dblink;

create schema t15;

-- The fixture. id and tag carry the same value on every row, so a misalignment between any two
-- columns reads back as id <> tag; ts leads the primary key, so the range encoder orders by it. The
-- payload is ~544 bytes, 32 of them random, so that with compression on the encode takes seconds
-- rather than milliseconds.
--
-- The range the encoder reads, [00:10:00, 01:30:00), is INTERIOR to the data on purpose: rows 1..599
-- sit below it and 5400..6000 above. A bound past either end of a column's histogram makes the
-- planner probe the index for the actual extreme (get_actual_variable_range) every time a statement
-- with that predicate is planned, and those probes count in pg_stat_user_tables.idx_scan, which would
-- turn the "scanned exactly once" witness below into a count of planner probes. The row the second
-- session inserts sits exactly ON the lower bound with id 0, so it is inside the range and sorts
-- first in it.
create table t15.snap (
  ts      timestamptz not null,
  id      bigint      not null,
  payload text        not null,
  tag     bigint      not null,
  primary key (ts, id)
);
insert into t15.snap
select '2024-01-01'::timestamptz + (g || ' seconds')::interval, g,
       md5(random()::text) || repeat(md5(g::text), 16), g
  from generate_series(1, 6000) g;
vacuum analyze t15.snap;

-- Every file this test produces lands here, by label, so the assertions compare files, not counts.
create table t15.enc (label text primary key, started_at timestamptz, ended_at timestamptz, bytes bytea);

-- The encode under race runs in the second session through one of these, so its own start and end
-- are recorded by the same transaction that ran it.
create function t15.timed_range(p_compress boolean)
returns table (started_at timestamptz, ended_at timestamptz, bytes bytea)
language plpgsql as $$
declare s timestamptz; b bytea;
begin
  s := clock_timestamp();
  b := archive._pq_to_parquet_range('t15.snap', 'ts', '2024-01-01 00:10:00', '2024-01-01 01:30:00', p_compress);
  return query select s, clock_timestamp(), b;
end $$;

create function t15.timed_plain(p_compress boolean)
returns table (started_at timestamptz, ended_at timestamptz, bytes bytea)
language plpgsql as $$
declare s timestamptz; b bytea;
begin
  s := clock_timestamp();
  b := archive._pq_to_parquet('t15.snap', p_compress);
  return query select s, clock_timestamp(), b;
end $$;

-- ---------------------------------------------------------------------------
-- Part A: archive._pq_to_parquet_range, a concurrent INSERT that sorts first
-- ---------------------------------------------------------------------------

-- The quiescent encode before the write. It doubles as the calibration run for the race's delay and
-- as the scan-count witness. pg_stat_user_tables is sampled in a later transaction than the work it
-- measures (counters flush at transaction end; each top-level statement of this file is its own
-- transaction, and pg_stat_force_next_flush() makes the flush immediate rather than best-effort).
select pg_stat_force_next_flush();
select seq_scan + idx_scan as scans_a0 from pg_stat_user_tables where relid = 't15.snap'::regclass \gset
select clock_timestamp() as cal_start \gset
insert into t15.enc (label, bytes)
select 'range_before', archive._pq_to_parquet_range('t15.snap', 'ts', '2024-01-01 00:10:00', '2024-01-01 01:30:00', true);
select round((0.4 * extract(epoch from clock_timestamp() - :'cal_start'::timestamptz))::numeric, 3) as delay \gset
select pg_stat_force_next_flush();

select is(
  (select seq_scan + idx_scan from pg_stat_user_tables where relid = 't15.snap'::regclass) - :scans_a0,
  1::bigint,
  'range: one encode scans the relation exactly once -- one statement, one snapshot, however many columns');

select dblink_connect('enc_range', 'dbname=' || current_database());
select dblink_send_query('enc_range', 'select * from t15.timed_range(true)');
select pg_sleep(:delay);
select clock_timestamp() as w_lo \gset
insert into t15.snap values ('2024-01-01 00:10:00', 0, repeat('w', 544), 0);
select clock_timestamp() as w_hi \gset
insert into t15.enc (label, started_at, ended_at, bytes)
select 'range_racy', started_at, ended_at, bytes
  from dblink_get_result('enc_range') as t(started_at timestamptz, ended_at timestamptz, bytes bytea);
select dblink_disconnect('enc_range');

select diag(format('range: encode ran %s .. %s (%s s); the insert committed between %s and %s (delay %s s)',
  started_at, ended_at, round(extract(epoch from ended_at - started_at)::numeric, 2), :'w_lo', :'w_hi', :delay))
  from t15.enc where label = 'range_racy';

select ok(
  (select :'w_lo'::timestamptz > started_at and :'w_hi'::timestamptz < ended_at from t15.enc where label = 'range_racy'),
  'LIVENESS: the insert committed strictly inside the racy encode''s window');

select is(
  (select id from t15.snap where ts >= '2024-01-01 00:10:00' and ts < '2024-01-01 01:30:00' order by ts, id limit 1), 0::bigint,
  'LIVENESS: the inserted row is inside the range and first in the range encoder''s order');

insert into t15.enc (label, bytes)
select 'range_after', archive._pq_to_parquet_range('t15.snap', 'ts', '2024-01-01 00:10:00', '2024-01-01 01:30:00', true);

select isnt(
  (select md5(bytes) from t15.enc where label = 'range_before'),
  (select md5(bytes) from t15.enc where label = 'range_after'),
  'LIVENESS: the insert changes what a single-snapshot encode produces, so matching one of them is not vacuous');

select ok(
  (select bytes from t15.enc where label = 'range_racy')
    in ((select bytes from t15.enc where label = 'range_before'),
        (select bytes from t15.enc where label = 'range_after')),
  'range: the racy file is byte-identical to a single-snapshot encode -- the insert is wholly in or wholly out, never in some columns and not others');

select diag('range: the racy file matches the encode taken ' || case
  when r.bytes = b.bytes then 'BEFORE the insert (the snapshot preceded the commit)'
  when r.bytes = a.bytes then 'AFTER the insert (the snapshot followed the commit)'
  else 'NEITHER: its columns come from different snapshots' end)
  from t15.enc r, t15.enc b, t15.enc a
 where r.label = 'range_racy' and b.label = 'range_before' and a.label = 'range_after';

-- ---------------------------------------------------------------------------
-- Part B: archive._pq_to_parquet (heap order), a concurrent UPDATE that moves the first row
-- ---------------------------------------------------------------------------

-- The whole-relation encoder writes rows in ctid order, so an INSERT cannot expose it the same way:
-- the new row lands at the end of the heap, past the count the page header was sized to, and a
-- reader simply never sees it (a silent omission, but not a misalignment). An UPDATE of the first
-- row writes its new version wherever there is room, which in a heap this full is a later page, so
-- in ctid order the row goes from first to last, and on the pre-fix code every column read after
-- the commit is shifted by one row against every column read before it.
select pg_stat_force_next_flush();
select seq_scan + idx_scan as scans_b0 from pg_stat_user_tables where relid = 't15.snap'::regclass \gset
insert into t15.enc (label, bytes) select 'plain_before', archive._pq_to_parquet('t15.snap', true);
select pg_stat_force_next_flush();

select is(
  (select seq_scan + idx_scan from pg_stat_user_tables where relid = 't15.snap'::regclass) - :scans_b0,
  1::bigint,
  'plain: one encode scans the relation exactly once');

select is(
  (select id from t15.snap order by ctid limit 1), 1::bigint,
  'LIVENESS: before the update, row 1 is first in heap order');

select dblink_connect('enc_plain', 'dbname=' || current_database());
select dblink_send_query('enc_plain', 'select * from t15.timed_plain(true)');
select pg_sleep(:delay);
select clock_timestamp() as w_lo \gset
update t15.snap set payload = payload || repeat('!', 300) where id = 1;
select clock_timestamp() as w_hi \gset
insert into t15.enc (label, started_at, ended_at, bytes)
select 'plain_racy', started_at, ended_at, bytes
  from dblink_get_result('enc_plain') as t(started_at timestamptz, ended_at timestamptz, bytes bytea);
select dblink_disconnect('enc_plain');

select diag(format('plain: encode ran %s .. %s (%s s); the update committed between %s and %s',
  started_at, ended_at, round(extract(epoch from ended_at - started_at)::numeric, 2), :'w_lo', :'w_hi'))
  from t15.enc where label = 'plain_racy';

select ok(
  (select :'w_lo'::timestamptz > started_at and :'w_hi'::timestamptz < ended_at from t15.enc where label = 'plain_racy'),
  'LIVENESS: the update committed strictly inside the racy encode''s window');

select isnt(
  (select id from t15.snap order by ctid limit 1), 1::bigint,
  'LIVENESS: the update moved row 1 out of first place in heap order');

insert into t15.enc (label, bytes) select 'plain_after', archive._pq_to_parquet('t15.snap', true);

select isnt(
  (select md5(bytes) from t15.enc where label = 'plain_before'),
  (select md5(bytes) from t15.enc where label = 'plain_after'),
  'LIVENESS: the update changes what a single-snapshot encode produces');

select ok(
  (select bytes from t15.enc where label = 'plain_racy')
    in ((select bytes from t15.enc where label = 'plain_before'),
        (select bytes from t15.enc where label = 'plain_after')),
  'plain: the racy file is byte-identical to a single-snapshot encode -- the moved row is in one place, not two');

select diag('plain: the racy file matches the encode taken ' || case
  when r.bytes = b.bytes then 'BEFORE the update'
  when r.bytes = a.bytes then 'AFTER the update'
  else 'NEITHER: its columns come from different snapshots' end)
  from t15.enc r, t15.enc b, t15.enc a
 where r.label = 'plain_racy' and b.label = 'plain_before' and a.label = 'plain_after';

-- ---------------------------------------------------------------------------
-- Part C: archive._encode_upload_parquet -- the file and rows_archived come from the same snapshot
-- ---------------------------------------------------------------------------

-- The archive_fn transport used to count rows_archived in a statement of its own, after the encode,
-- so under a concurrent write it matched neither the file nor the child. A managed table with the
-- same shape as the fixture, an insert that sorts first in the monolith's [0, 10000) range, and the
-- uploaded object fetched straight back from MinIO rather than trusted from the ledger.
create table public.a15 (id bigint primary key, payload text not null, tag bigint not null);
insert into public.a15
select g, md5(random()::text) || repeat(md5(g::text), 16), g from generate_series(1, 6000) g;
call pgpm.transmute('public.a15', 'id', 10000::bigint);
select mk_archive_config('a15', true);   -- compress on: that is the window

create function t15.timed_upload()
returns table (started_at timestamptz, ended_at timestamptz, s3_key text, rows_archived bigint)
language plpgsql as $$
declare s timestamptz; r record;
begin
  s := clock_timestamp();
  select * into r from archive._encode_upload_parquet('public.a15', '0', '10000', true);
  return query select s, clock_timestamp(), r.s3_key, r.rows_archived;
end $$;

-- pgsql-http hands binary content back as text; text_to_bytea reverses that byte for byte.
create function t15.fetch_object(p_parent regclass, p_key text) returns bytea
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
end $$;

insert into t15.enc (label, bytes)
select 'upload_before', archive._pq_to_parquet_range('public.a15', 'id', '0', '10000', true);

create table t15.upload (started_at timestamptz, ended_at timestamptz, s3_key text, rows_archived bigint);
select dblink_connect('enc_upload', 'dbname=' || current_database());
select dblink_send_query('enc_upload', 'select * from t15.timed_upload()');
select pg_sleep(:delay);
select clock_timestamp() as w_lo \gset
insert into public.a15 values (0, repeat('w', 544), 0);
select clock_timestamp() as w_hi \gset
insert into t15.upload
select * from dblink_get_result('enc_upload') as t(started_at timestamptz, ended_at timestamptz, s3_key text, rows_archived bigint);
select dblink_disconnect('enc_upload');

select diag(format('strategy: encode+upload ran %s .. %s (%s s); the insert committed between %s and %s; rows_archived = %s',
  started_at, ended_at, round(extract(epoch from ended_at - started_at)::numeric, 2), :'w_lo', :'w_hi', rows_archived))
  from t15.upload;

select ok(
  (select :'w_lo'::timestamptz > started_at and :'w_hi'::timestamptz < ended_at from t15.upload),
  'LIVENESS: the insert committed strictly inside the strategy encode''s window');

select is(
  (select count(*) from public.a15 where id = 0), 1::bigint,
  'LIVENESS: the inserted row is in the managed table');

insert into t15.enc (label, bytes)
select 'upload_racy', t15.fetch_object('public.a15', s3_key) from t15.upload;

insert into t15.enc (label, bytes)
select 'upload_after', archive._pq_to_parquet_range('public.a15', 'id', '0', '10000', true);

select isnt(
  (select md5(bytes) from t15.enc where label = 'upload_before'),
  (select md5(bytes) from t15.enc where label = 'upload_after'),
  'LIVENESS: the insert changes what a single-snapshot encode of the managed table produces');

select ok(
  (select bytes from t15.enc where label = 'upload_racy')
    in ((select bytes from t15.enc where label = 'upload_before'),
        (select bytes from t15.enc where label = 'upload_after')),
  'strategy: the uploaded object is byte-identical to a single-snapshot encode');

-- Self-contained on purpose: `rows_archived = case when racy = before then 6000 else 6001 end` would
-- pass against the defect (racy matches neither, and the separate count(*) did see 6001).
select ok(
  (select (r.bytes = b.bytes and u.rows_archived = 6000) or (r.bytes = a.bytes and u.rows_archived = 6001)
     from t15.upload u, t15.enc r, t15.enc b, t15.enc a
    where r.label = 'upload_racy' and b.label = 'upload_before' and a.label = 'upload_after'),
  'strategy: rows_archived is the row count of the snapshot the file was encoded from -- 6000 with the insert out, 6001 with it in -- not a later count(*)');

-- ---------------------------------------------------------------------------
-- Part D: the bytea wrapper and the counted encoder agree
-- ---------------------------------------------------------------------------

-- archive._pq_to_parquet_range keeps its bytea signature for the callers that only want the file
-- (scripts/verify_parquet_range.py, the memory guards); archive._pq_to_parquet_range_counted is the
-- same encode reporting the row count of the snapshot it encoded, for the transport's ledger row.
select is(
  md5(archive._pq_to_parquet_range('t15.snap', 'ts', '2024-01-01 00:10:00', '2024-01-01 01:30:00', false)),
  (select md5(c.p_file) from archive._pq_to_parquet_range_counted('t15.snap', 'ts', '2024-01-01 00:10:00', '2024-01-01 01:30:00', false) c),
  'archive._pq_to_parquet_range returns exactly the file archive._pq_to_parquet_range_counted encodes');

select is(
  (select c.p_num_rows from archive._pq_to_parquet_range_counted('t15.snap', 'ts', '2024-01-01 00:10:00', '2024-01-01 01:30:00', false) c),
  (select count(*) from t15.snap where ts >= '2024-01-01 00:10:00' and ts < '2024-01-01 01:30:00'),
  'and the counted encoder reports the number of rows the file holds');

select * from finish();

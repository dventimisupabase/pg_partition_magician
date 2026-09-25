-- The archive_fn transports named an uploaded object after the DIGITS of the chunk's lo,
-- regexp_replace(p_lo, '[^0-9]', '', 'g'), which strips the sign (and, on a numeric control column,
-- the decimal point) from the id kind's native value (issue #502). Chunk lo -10000 and chunk lo 10000
-- of one table therefore shared one object key: a single maintain() tick uploaded the second over the
-- first, both ledger rows recorded the same s3_key as archived, and retire() would have dropped the
-- [-10000, 0) partition with its rows gone from the store.
--
-- Both transports now take the stem from archive._object_stem(control_kind, lo), which keeps an id
-- kind's numeric text whole (`-10000`, `10.5`) and keeps the digits-only form for a timestamptz text,
-- which was never ambiguous and is the key shape every existing time-kind bucket already holds.
--
-- The fixture is the issue's own and asymmetric on purpose (10000 rows in [-10000, 0), 10 rows in
-- [10000, 20000)), so a clobbered object cannot pass an identity check by accident. Every negative is
-- paired with a witness that its condition was present: both partitions exist and hold exactly the
-- rows named, both candidate keys are cleared and witnessed absent before the tick (the bucket
-- outlives a test database, and a stale object from an earlier run at the same key would otherwise
-- satisfy a read-back), and the tick wrote a ledger row for each partition.
select plan(23);

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

-- DELETE the key, then report the GET status: 404 means the tick below starts from an empty key.
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

-- The ids an NDJSON object holds, in order: identity, not a count.
create function t16.fetch_ids(p_parent regclass, p_key text) returns bigint[]
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then raise exception 'GET % failed: HTTP %', p_key, v_resp.status; end if;
  return (select array_agg((l::jsonb ->> 'id')::bigint order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v_resp.content, e'\n') l where l <> '');
end;
$$;

-- An object's bytes. http_response.content is text, but the extension fills it by reinterpreting the
-- body's bytes rather than re-encoding them, and text_to_bytea reverses that reinterpretation, so a
-- binary Parquet object comes back byte-for-byte (the same read tests/archive/db/13 relies on).
create function t16.fetch_object(p_parent regclass, p_key text) returns bytea
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then raise exception 'GET % failed: HTTP %', p_key, v_resp.status; end if;
  return text_to_bytea(v_resp.content);
end;
$$;

-- ======================= PART A: pgpm.archive_to_s3_ndjson =======================

-- ids -10000..-1 land in the monolith [-10000, 0); ids 10000..10009 in the premade [10000, 20000).
-- A frontier row at 45000 with retain 5000 puts the horizon at 40000, so both are eligible in one tick.
create table public.negk (id bigint primary key, payload text);
insert into public.negk select g, 'neg' from generate_series(-10000, -1) g;
call pgpm.transmute('public.negk', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into public.negk select g, 'pos' from generate_series(10000, 10009) g;
insert into public.negk values (45000, 'frontier');

select mk_archive_config('negk', false);
update pgpm.config set retain_batch = 0, archive_batch = null where parent_table = 'public.negk'::regclass;
select pgpm.set_archive_fn('public.negk', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);

select is(
  (select array_agg(lo::bigint order by lo::bigint) from pgpm.part
    where parent_table = 'public.negk'::regclass and lo::bigint in (-10000, 10000)),
  array[-10000, 10000]::bigint[],
  'LIVENESS: pgpm built a partition at lo -10000 and one at lo 10000');

select ok(
  (select array_agg(id order by id) from public.negk where id < 0)
    = (select array_agg(g::bigint) from generate_series(-10000, -1) g),
  'LIVENESS: exactly ids -10000..-1 sit in [-10000, 0)');

select is(
  (select array_agg(id order by id) from public.negk where id between 10000 and 19999),
  (select array_agg(g::bigint) from generate_series(10000, 10009) g),
  'LIVENESS: exactly ids 10000..10009 sit in [10000, 20000)');

-- Both keys the tick could write: the one the two chunks used to share, and the negative chunk's own.
select is(t16.clear_object('public.negk', 'negk/negk_10000.ndjson'), 404,
  'LIVENESS: no object at negk/negk_10000.ndjson before the tick');
select is(t16.clear_object('public.negk', 'negk/negk_-10000.ndjson'), 404,
  'LIVENESS: no object at negk/negk_-10000.ndjson before the tick');

call pgpm.maintain('public.negk');

select is(
  (select array_agg(lo::bigint order by lo::bigint) from pgpm.archive_ledger
    where parent_table = 'public.negk'::regclass and lo::bigint in (-10000, 10000)),
  array[-10000, 10000]::bigint[],
  'LIVENESS: the tick recorded a ledger row for [-10000, 0) and one for [10000, 20000)');

-- THE DEFECT: two different chunks must not share one object key.
select isnt(
  (select s3_key from pgpm.archive_ledger where parent_table = 'public.negk'::regclass and lo = '-10000'),
  (select s3_key from pgpm.archive_ledger where parent_table = 'public.negk'::regclass and lo = '10000'),
  'ndjson: the [-10000, 0) and [10000, 20000) ledger rows name two different objects');

-- And the object the [-10000, 0) row points at must hold THAT partition's rows, by identity.
create temp table t16_neg as
  select t16.fetch_ids('public.negk',
    (select s3_key from pgpm.archive_ledger where parent_table = 'public.negk'::regclass and lo = '-10000')) as ids;
select diag(format('ndjson: the object at the [-10000, 0) key holds %s ids, first %s, last %s',
                   coalesce(array_length(ids, 1), 0), ids[1], ids[array_length(ids, 1)]))
  from t16_neg;
select ok(
  (select ids from t16_neg) = (select array_agg(g::bigint) from generate_series(-10000, -1) g),
  'ndjson: the object recorded for [-10000, 0) holds exactly ids -10000..-1, not the rows that overwrote it');

select is(
  t16.fetch_ids('public.negk',
    (select s3_key from pgpm.archive_ledger where parent_table = 'public.negk'::regclass and lo = '10000')),
  (select array_agg(g::bigint) from generate_series(10000, 10009) g),
  'ndjson: the object recorded for [10000, 20000) holds exactly ids 10000..10009');

-- ======================= PART B: pgpm.archive_to_s3_parquet =======================

-- The same shape through the other transport (the issue names both sites). Smaller on the negative
-- side, 1000 rows, because the Parquet writer is pure PL/pgSQL; still 100 to 1 against the 10 rows in
-- [10000, 20000), so the two objects cannot be confused by size.
create table public.negkp (id bigint primary key, payload text);
insert into public.negkp select g, 'neg' from generate_series(-1000, -1) g;
call pgpm.transmute('public.negkp', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into public.negkp select g, 'pos' from generate_series(10000, 10009) g;
insert into public.negkp values (45000, 'frontier');

select mk_archive_config('negkp', false);
update pgpm.config set retain_batch = 0, archive_batch = null where parent_table = 'public.negkp'::regclass;
select pgpm.set_archive_fn('public.negkp', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);

select is(
  (select array_agg(lo::bigint order by lo::bigint) from pgpm.part
    where parent_table = 'public.negkp'::regclass and lo::bigint in (-10000, 10000)),
  array[-10000, 10000]::bigint[],
  'LIVENESS: pgpm built a partition at lo -10000 and one at lo 10000 for the Parquet table');

select ok(
  (select array_agg(id order by id) from public.negkp where id < 0)
    = (select array_agg(g::bigint) from generate_series(-1000, -1) g),
  'LIVENESS: exactly ids -1000..-1 sit in the Parquet table''s [-10000, 0)');

select is(
  (select array_agg(id order by id) from public.negkp where id between 10000 and 19999),
  (select array_agg(g::bigint) from generate_series(10000, 10009) g),
  'LIVENESS: exactly ids 10000..10009 sit in the Parquet table''s [10000, 20000)');

select is(t16.clear_object('public.negkp', 'negkp/negkp_10000.parquet'), 404,
  'LIVENESS: no object at negkp/negkp_10000.parquet before the tick');
select is(t16.clear_object('public.negkp', 'negkp/negkp_-10000.parquet'), 404,
  'LIVENESS: no object at negkp/negkp_-10000.parquet before the tick');

call pgpm.maintain('public.negkp');

select is(
  (select array_agg(lo::bigint order by lo::bigint) from pgpm.archive_ledger
    where parent_table = 'public.negkp'::regclass and lo::bigint in (-10000, 10000)),
  array[-10000, 10000]::bigint[],
  'LIVENESS: the tick recorded a ledger row for the Parquet table''s [-10000, 0) and [10000, 20000)');

select isnt(
  (select s3_key from pgpm.archive_ledger where parent_table = 'public.negkp'::regclass and lo = '-10000'),
  (select s3_key from pgpm.archive_ledger where parent_table = 'public.negkp'::regclass and lo = '10000'),
  'parquet: the [-10000, 0) and [10000, 20000) ledger rows name two different objects');

-- The object at the [-10000, 0) key is the 1000-row file, not the 10-row file that used to overwrite it.
create temp table t16_pq as
  select octet_length(t16.fetch_object('public.negkp',
           (select s3_key from pgpm.archive_ledger where parent_table = 'public.negkp'::regclass and lo = '-10000'))) as neg_bytes,
         octet_length(t16.fetch_object('public.negkp',
           (select s3_key from pgpm.archive_ledger where parent_table = 'public.negkp'::regclass and lo = '10000'))) as pos_bytes;
select diag(format('parquet: the [-10000, 0) object is %s bytes, the [10000, 20000) object %s bytes', neg_bytes, pos_bytes))
  from t16_pq;
select ok((select neg_bytes > pos_bytes from t16_pq),
  'parquet: the object recorded for [-10000, 0) is the larger, 1000-row file, not the 10-row file that shared its key');

-- ======================= PART C: the stem itself, and the key shape it produces =======================

select is(archive._object_stem('id', '-10000'), '-10000',
  'an id kind keeps the sign of a negative lo in the object stem');
select is(archive._object_stem('id', '10.5'), '10.5',
  'an id kind on a numeric control keeps the decimal point: 10.5 and 105 are different chunks');
select is(archive._object_stem('id', '10000'), '10000',
  'a non-negative id stem is unchanged from the key shape existing buckets hold');
select is(archive._object_stem('time', '2024-01-01 00:00:00+00'), '2024010100000000',
  'a time kind keeps the digits-only key shape existing buckets hold');

select is(
  (select s3_key from pgpm.archive_ledger where parent_table = 'public.negk'::regclass and lo = '-10000'),
  'negk/negk_-10000.ndjson',
  'the ndjson key is <prefix><parent>_<stem>.ndjson, with the stem carrying the sign');
select is(
  (select s3_key from pgpm.archive_ledger where parent_table = 'public.negkp'::regclass and lo = '-10000'),
  'negkp/negkp_-10000.parquet',
  'the parquet key is <prefix><parent>_<stem>.parquet, with the stem carrying the sign');

select * from finish();

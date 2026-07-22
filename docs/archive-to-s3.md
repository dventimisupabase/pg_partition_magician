# Archive partitions to S3 before retention drops them

A complete, working `pre_drop` hook that copies a partition's rows to AWS S3 (or any S3-compatible
store) before `retain()` drops it, and blocks the drop when the copy fails. This is a **worked example
of a user-supplied hook**, not part of pg_partition_magician: copy it, edit the constants, and own it.
The [guide](guide.md#pre-drop-hooks) introduces the hook mechanism; `hook_register` in the
[reference](reference.md#hook_register) has the full contract.

The function below was verified end-to-end, twice, driven by the real `retain()` path each time:
against MinIO's full AWS Signature Version 4 enforcement (a 50,000-row partition archived and dropped;
an endpoint outage blocking the drop with the failure logged and surfaced; the paced backlog draining
to zero after recovery, empty partitions included), and against a live Supabase project archiving to
[Supabase Storage's S3-compatible endpoint](https://supabase.com/docs/guides/storage/s3/authentication)
(same lifecycle, plus a real S3 rejection: a PUT to a missing bucket came back HTTP 404 with the S3 XML
error captured verbatim in the `retain_hook_fail` log, and the drop deferred). Storage's endpoint also
carries a path prefix (`/storage/v1/s3`), which is why the path-style branch below splits the host and
the URI prefix apart instead of assuming a bare host.

## The moving parts

- **The [`http` extension](https://github.com/pramsey/pgsql-http)** (on Supabase: `http`, "RESTful
  Client") makes the PUT. It is synchronous libcurl in the calling backend, which is exactly what a
  `pre_drop` hook needs: the real HTTP status comes back in the same call, so the hook can decide,
  before the drop, whether the copy actually succeeded. `pg_net` cannot do this job, twice over: it
  supports no PUT and only JSON bodies, and it is asynchronous by design (its background worker cannot
  even see the queued request until the enqueuing transaction commits, which is after the drop already
  happened).
- **`pgcrypto`** provides `digest`/`hmac` for AWS Signature Version 4, translated straight from the
  published recipe. No AWS SDK, no external worker.
- **[Vault](https://supabase.com/docs/guides/database/vault)** holds the AWS credentials encrypted at
  rest; the hook decrypts them only at call time. On vanilla Postgres without Vault, substitute your
  own secrets mechanism for the two `vault.decrypted_secrets` lookups.
- **`config.retain_batch = 1`** paces retention to one partition's hook + drop per maintenance tick.
  The upload is synchronous inside `retain()`'s transaction, so the cap is what keeps a backlog of
  aged-out partitions from turning one tick into one long transaction. See
  [`retain`](reference.md#retain).

## Store the credentials

Once, as a privileged role:

```sql
select vault.create_secret('AKIAIOSFODNN7EXAMPLE',                     's3_archive_access_key_id');
select vault.create_secret('wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 's3_archive_secret_access_key');
```

The role that runs maintenance (on the pg_cron path, the job's owner) needs `select` on
`vault.decrypted_secrets` for the hook to read them back.

## The hook function

Everything lives in a dedicated `archive` schema, not `public`: on Supabase, `public` is typically
exposed through the Data API, which serves `public` functions as RPC (and PostgreSQL grants
`EXECUTE` to `PUBLIC` on new functions by default). PostgREST only serves schemas you explicitly
expose, so a dedicated schema keeps the archival machinery dark.

```sql
create extension if not exists http;
create extension if not exists pgcrypto;
create schema if not exists archive;

-- Export the partition's rows to S3 as NDJSON, synchronously, and raise if the upload did not
-- succeed (so retain() keeps the partition and retries next tick).
create or replace function archive.to_s3(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  -- deployment constants: edit these four
  c_bucket   text := 'my-archive-bucket';
  c_region   text := 'us-east-1';
  c_prefix   text := 'events/';   -- key prefix inside the bucket ('' for none)
  c_endpoint text := null;        -- null = AWS S3; an URL for S3-compatible, path prefix and all
                                  -- (e.g. 'https://<ref>.storage.supabase.co/storage/v1/s3')

  v_key_id text; v_secret text; v_nsp name; v_control name; v_payload text;
  v_key text; v_host text; v_uri text; v_url text;
  v_amz_date text; v_date text; v_payload_hash text; v_scope text;
  v_signed_headers text := 'content-type;host;x-amz-content-sha256;x-amz-date';
  v_ctype text := 'application/x-ndjson';
  v_canonical text; v_sts text; v_kbin bytea; v_sig text; v_auth text;
  v_resp http_response;
begin
  -- credentials from Vault, decrypted only here, never stored in plaintext
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = 's3_archive_access_key_id';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 's3_archive_secret_access_key';
  if v_key_id is null or v_secret is null then
    raise exception 'archive.to_s3: credentials missing from vault (s3_archive_access_key_id / s3_archive_secret_access_key)';
  end if;

  -- the partition's rows as newline-delimited JSON, ordered by the control column (round-trips any
  -- column type; sidesteps CSV quoting). The child still exists: pre_drop runs before the DROP.
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select control_column into v_control from pgpm.config where parent_table = p_parent;
  execute format('select coalesce(string_agg(row_to_json(t)::text, e''\n'' order by t.%I), '''') from %I.%I t',
                 v_control, v_nsp, p_child)
    into v_payload;

  -- the object key: child names are [a-z0-9_], so no URL-encoding is needed; keep c_prefix that clean too
  v_key := c_prefix || p_child || '.ndjson';
  if c_endpoint is null then
    v_host := c_bucket || '.s3.' || c_region || '.amazonaws.com';   -- virtual-hosted style
    v_uri  := '/' || v_key;
    v_url  := 'https://' || v_host || v_uri;
  else
    -- path style (MinIO, Supabase Storage, et al.). The endpoint may carry a path prefix
    -- (e.g. Supabase Storage's /storage/v1/s3): the Host header wants only the host, while the
    -- canonical URI must include that prefix, so split them apart.
    v_host := regexp_replace(c_endpoint, '^https?://([^/]+).*$', '\1');
    v_uri  := regexp_replace(c_endpoint, '^https?://[^/]+', '') || '/' || c_bucket || '/' || v_key;
    v_url  := c_endpoint || '/' || c_bucket || '/' || v_key;
  end if;

  -- AWS Signature Version 4, straight from the published recipe
  v_amz_date     := to_char(now() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"');
  v_date         := substr(v_amz_date, 1, 8);
  v_payload_hash := encode(digest(convert_to(v_payload, 'UTF8'), 'sha256'), 'hex');
  v_scope        := v_date || '/' || c_region || '/s3/aws4_request';
  v_canonical    := 'PUT' || e'\n' || v_uri || e'\n' || e'\n'       -- method, URI, (empty) query string
                 || 'content-type:' || v_ctype || e'\n'             -- canonical headers, alphabetical
                 || 'host:' || v_host || e'\n'
                 || 'x-amz-content-sha256:' || v_payload_hash || e'\n'
                 || 'x-amz-date:' || v_amz_date || e'\n'
                 || e'\n' || v_signed_headers || e'\n' || v_payload_hash;
  v_sts          := 'AWS4-HMAC-SHA256' || e'\n' || v_amz_date || e'\n' || v_scope || e'\n'
                 || encode(digest(convert_to(v_canonical, 'UTF8'), 'sha256'), 'hex');
  v_kbin := hmac(convert_to(v_date, 'UTF8'),        convert_to('AWS4' || v_secret, 'UTF8'), 'sha256');
  v_kbin := hmac(convert_to(c_region, 'UTF8'),      v_kbin, 'sha256');
  v_kbin := hmac(convert_to('s3', 'UTF8'),          v_kbin, 'sha256');
  v_kbin := hmac(convert_to('aws4_request', 'UTF8'), v_kbin, 'sha256');
  v_sig  := encode(hmac(convert_to(v_sts, 'UTF8'), v_kbin, 'sha256'), 'hex');
  v_auth := 'AWS4-HMAC-SHA256 Credential=' || v_key_id || '/' || v_scope
         || ', SignedHeaders=' || v_signed_headers || ', Signature=' || v_sig;

  -- the http extension's default timeout is 5s; give a partition-sized upload room
  perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '300000');

  select * into v_resp from http((
    'PUT', v_url,
    array[ http_header('x-amz-date', v_amz_date),
           http_header('x-amz-content-sha256', v_payload_hash),
           http_header('authorization', v_auth) ],
    v_ctype, v_payload)::http_request);

  -- a non-2xx means the copy is NOT safely in S3: raise, so retain() keeps the partition and retries
  if v_resp.status not between 200 and 299 then
    raise exception 'archive.to_s3: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
  end if;
end;
$$;
```

A retried upload is naturally safe: a PUT to the same key overwrites, so a hook that succeeded on S3
but failed to report (or a partition retried after a partial outage) never duplicates or corrupts the
archive.

## Register and pace it

```sql
select pgpm.hook_register('public.events', 'pre_drop', 'archive.to_s3(regclass,name,text,text)');
update pgpm.config set retain_batch = 1 where parent_table = 'public.events'::regclass;
```

That is the whole installation. On the scheduled path (`pgpm.schedule()`), each maintenance tick now
archives and drops at most one aged-out partition; a backlog paces across ticks,
`status().retain_backlog` counting it down.

## When S3 is down

The hook raises (curl's or S3's error, verbatim), and `retain()` does **not** drop that partition: the
failure is logged (`retain_hook_fail`, with the error in `method`) and retried next tick. With
`retain_batch = 1` the cap attempts oldest-first, so a failing head defers the whole backlog behind it;
the signature to watch for is a **flat `retain_backlog` with climbing `retain_hook_failures`**:

```sql
select retain_backlog, retain_hook_failures from pgpm.status() where parent = 'public.events'::regclass;
select method from pgpm.log where action = 'retain_hook_fail' order by id desc limit 1;
```

Once the outage clears, the next ticks drain the backlog one partition per tick, no intervention
needed. See the runbook's
[retention entry](runbook.md#storage-is-not-dropping-despite-a-retention-policy).

## Honest limits

- **The payload is one in-memory `text` value.** `string_agg` assembles the whole partition and one
  `http()` call sends it: no streaming, no S3 multipart. Postgres caps a `text` value at 1GB, and the
  practical ceiling (memory, timeout) is well below that. This fits the intended shape, a fine
  `partition_step` whose partitions are tens-to-hundreds of MB. That ceiling is a scope choice for
  this illustration, not a limit of the technique: the
  [multipart variant below](#when-one-put-is-not-enough-the-multipart-variant) streams a partition of
  any size in bounded memory.
- **The upload runs inside `retain()`'s transaction.** That is what makes the failure guarantee work,
  and it is why `retain_batch = 1` matters: without it, one call carries every aged-out partition's
  upload back-to-back in one transaction.
- **Watch the timeout.** The `http` extension defaults to 5 seconds per request; the
  `http_set_curlopt('CURLOPT_TIMEOUT_MS', ...)` above sizes it for a partition-scale upload. A hook
  that times out just defers the drop to the next tick, like any other failure.
- **Object keys are not URL-encoded.** Child names are `[a-z0-9_]` so nothing needs encoding; if you
  change `c_prefix`, keep it to unreserved URL characters.
- **On Supabase, extensions install into the `extensions` schema.** If `http_put`/`http` and
  `pgcrypto` functions are not on your `search_path`, schema-qualify them (e.g. `extensions.http(...)`)
  or `set search_path` in the function definition.
- **Two Supabase ceilings, discovered during live verification.** Supabase Storage enforces the
  project's upload file size limit (**default 50MB**) on the S3 protocol too, per whole object,
  multipart included: an archive bigger than the limit fails with `HTTP 413` / `EntityTooLarge` (the
  hook raises, the drop defers, loudly) until you raise the limit in the Dashboard under **Storage ->
  Files -> Settings**. And `statement_timeout` is **2 minutes** there (a server configuration-file
  setting, so it applies over the pooler and direct connections alike): the whole upload runs inside
  one statement, so that is this hook's wall-clock ceiling on Supabase; override with a session
  `set statement_timeout = ...` if a partition legitimately needs longer, or use the
  [archive assistant](archive-assistant.md), whose per-part statements each only need to fit one part in
  the window.

## When one PUT is not enough: the multipart variant

The single-PUT hook above holds the whole partition in one `text` value. This variant replaces it
(same name, same signature, same registration) with one that holds **at most one part in memory**:
it keyset-paginates the partition on the control column, ships each ~8MiB accumulation as an S3
multipart part, and completes the upload at the end. Small and empty partitions short-circuit to the
plain single PUT, so nothing gets slower at the low end. It splits into three functions -- a
percent-encoder, one shared SigV4 signer (initiate, part, complete, and abort all sign the same way;
the multipart requests just add a canonical query string), and the hook:

```sql
create schema if not exists archive;

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

-- The hook. Small partitions (one part's worth or less) take a plain single PUT; bigger ones
-- stream through S3 multipart, holding at most one part in memory at a time.
create or replace function archive.to_s3(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  -- deployment constants: edit these four
  c_bucket   text := 'my-archive-bucket';
  c_region   text := 'us-east-1';
  c_prefix   text := 'events/';
  c_endpoint text := null;        -- null = AWS S3; an URL for S3-compatible, path prefix and all
                                  -- (e.g. 'https://<ref>.storage.supabase.co/storage/v1/s3')

  c_part_bytes  int := 8 * 1024 * 1024;   -- target part size (S3 minimum: 5MiB, except the last part)
  c_fetch_rows  int := 20000;             -- rows per keyset fetch while filling a part
  v_ctype text := 'application/x-ndjson';

  v_key_id text; v_secret text; v_nsp name; v_control name; v_ctltype text; v_key text;
  v_part_payload text; v_chunk text; v_cursor text; v_done boolean := false;
  v_upload_id text; v_part int := 0; v_etag text; v_parts_xml text := '';
  v_resp http_response; h http_header;
begin
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = 's3_archive_access_key_id';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 's3_archive_secret_access_key';
  if v_key_id is null or v_secret is null then
    raise exception 'archive.to_s3: credentials missing from vault (s3_archive_access_key_id / s3_archive_secret_access_key)';
  end if;

  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select control_column into v_control from pgpm.config where parent_table = p_parent;
  select a.atttypid::regtype::text into v_ctltype
    from pg_attribute a where a.attrelid = p_parent and a.attname = v_control;
  v_key := c_prefix || p_child || '.ndjson';

  -- stream the partition part by part: keyset-paginate on the control column, appending
  -- c_fetch_rows-sized chunks of NDJSON until the part reaches c_part_bytes, then ship it.
  v_part_payload := '';
  v_cursor := null;
  <<parts>>
  loop
    while not v_done and octet_length(v_part_payload) < c_part_bytes loop
      execute format(
        'select coalesce(string_agg(j, e''\n'' order by k), ''''), (array_agg(k order by k desc))[1]::text
           from (select row_to_json(t)::text as j, t.%I as k from %I.%I t
                  where $1 is null or t.%I > $1::%s
                  order by t.%I limit $2) s',
        v_control, v_nsp, p_child, v_control, v_ctltype, v_control)
        into v_chunk, v_cursor using v_cursor, c_fetch_rows;
      if v_chunk = '' then v_done := true;
      else v_part_payload := v_part_payload || v_chunk || e'\n';   -- line-terminated, so parts concatenate cleanly
      end if;
    end loop;

    -- the partition ended exactly on a part boundary: nothing left to ship
    exit parts when v_done and v_part > 0 and v_part_payload = '';

    -- everything fit in the first part: a plain single PUT, no multipart bookkeeping to manage
    if v_part = 0 and v_done then
      v_resp := archive.s3_signed_request('PUT', c_endpoint, c_bucket, c_region, v_key, '',
                                         v_ctype, v_part_payload, v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive.to_s3: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      return;
    end if;

    -- first oversized part: initiate the multipart upload (the UploadId comes back as XML)
    if v_part = 0 then
      v_resp := archive.s3_signed_request('POST', c_endpoint, c_bucket, c_region, v_key, 'uploads=',
                                         v_ctype, '', v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive.to_s3: initiate multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      v_upload_id := (xpath('//*[local-name()=''UploadId'']/text()', v_resp.content::xml))[1]::text;
    end if;

    v_part := v_part + 1;
    v_resp := archive.s3_signed_request('PUT', c_endpoint, c_bucket, c_region, v_key,
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
  v_resp := archive.s3_signed_request('POST', c_endpoint, c_bucket, c_region, v_key,
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
      perform archive.s3_signed_request('DELETE', c_endpoint, c_bucket, c_region, v_key,
                                       'uploadId=' || archive.s3_url_encode(v_upload_id),
                                       'text/plain', '', v_key_id, v_secret);
    exception when others then null;
    end;
  end if;
  raise;
end;
$$;
```

What changes, honestly:

- **Memory is bounded; transaction duration is not.** Multipart fixes the 1GB `text` cap and the
  memory ceiling, but the whole upload still runs inside `retain()`'s transaction, and a bigger
  feasible partition means a longer-open snapshot (held vacuum horizon) while it uploads. S3's own
  limits (10,000 parts) put the protocol ceiling around 80GB at this part size; the polite ceiling
  is far lower and set by how long you are willing to hold a transaction open. To bound that hold
  to one part's network time, entirely in-database, see the
  [archive assistant](archive-assistant.md) (a committing scanner procedure plus `pgpm.retire`); past
  that, hand the work to an external worker with a real AWS SDK.
- **A failed upload is aborted, not leaked.** An incomplete multipart upload is invisible in
  listings but accrues storage. On any failure after initiation, the hook's exception handler sends
  `AbortMultipartUpload` before re-raising (so `retain()` still keeps the partition and retries).
  Belt and braces: also set a bucket lifecycle rule (`AbortIncompleteMultipartUpload`) for the day
  even the abort cannot reach S3.
- **The retry is still naturally safe.** Each retry is a fresh multipart upload under the same key;
  completion is atomic on S3's side, so a reader of the bucket never sees a half-written object.
- **`CompleteMultipartUpload` can fail inside an HTTP 200.** S3's one famous quirk: the complete
  call can return status 200 with an `<Error>` XML body, so the hook checks both.

This exact variant (constants aside) was verified through the real `retain()` path against both
MinIO and a live Supabase project archiving to Supabase Storage's S3-compatible endpoint, same
scenario on each: ~26MiB partitions archived as 3-part multipart uploads (ETags carrying the `-3`
part count) with every row account-checked across part boundaries (150,000 contiguous ids per
object, no lost or doubled line at any seam); an empty partition taking the single-PUT fast path
(bare-MD5 ETag); a simulated network failure during part 2 blocking the drop, with the abort
confirmed on the store (`ListMultipartUploads` showing zero incomplete uploads left behind); and
the retried partition re-archiving completely on the next tick. The two stores returned
**identical composite ETags** for the same partitions: the part boundaries are deterministic, so
the per-part MD5s match wherever the object lands.

## A columnar variant: Parquet instead of NDJSON

Both hooks above write NDJSON. A Parquet archive is directly queryable by DuckDB, Athena,
Redshift Spectrum, Spark, Trino, and Snowflake with no separate conversion step -- but on
Supabase there is currently no in-database extension that emits it (pg_parquet is no longer
available there; pg_duckdb, pg_lake, and pg_mooncake never were). This variant closes that gap
without any extension: it hand-rolls a Parquet file, Thrift compact-protocol footer and all, in
the same PL/pgSQL-plus-`pgcrypto`-plus-`http` toolbox as the hooks above. See
[pg_partition_magician#199](https://github.com/dventimisupabase/pg_partition_magician/issues/199)
for the fuller design discussion; this is that issue's "minimal-viable Parquet" rung, wired into
a real `pre_drop` hook.

**Scope, deliberately narrow.** One row group, one uncompressed PLAIN-encoded data page per
column, and six types: `int4`, `int8`, `float8`, `boolean`, `text` (UTF8), and
`timestamp`/`timestamptz` (`TIMESTAMP_MICROS`, via `extract(epoch from ...)`, which sidesteps ever
needing to know Postgres's internal 2000-01-01 epoch). Nullable columns are supported: a flat,
non-nested schema only ever needs `max_definition_level = 1`, so a nullable column's definition
levels are a single bit-packed run (a present/null bitmap per Data page v1's RLE/bit-packed-hybrid
encoding), 4-byte-length-prefixed ahead of the values, which themselves contain only the non-null
rows. Field IDs, encodings, and enum values throughout come directly from the canonical
`apache/parquet-format` `parquet.thrift` and `Encodings.md`, not from memory (worth calling out
specifically here: the level encoding's header is a *plain* ULEB128 varint, unrelated to the
zigzag varint the Thrift compact-protocol footer uses elsewhere on this page, easy to conflate
since both are just called "varint"). Iceberg is
out of scope: it needs a second binary format (Avro, for manifests) plus a catalog commit
protocol, neither of which reduces to a single PL/pgSQL function the way a flat Parquet file does.

**This holds the vacuum horizon like the hooks above, not like the archive assistant.** The
encoder reads every column of a partition via `array_agg(col order by ctid)`, with no `COMMIT` in
between -- each column's array has to come from the same snapshot as every other column's, or a
concurrent write between two column reads could misalign rows across columns. That means one
in-memory value, one upload, exactly the shape (and the same ceiling) as the single-PUT hook at
the top of this page: no attempt is made here to preserve the
[archive assistant](archive-assistant.md)'s per-part-committing, bounded-horizon-hold design --
Parquet's footer needs every row group's byte offsets, known only once its data is built, so a
streaming, row-group-per-slice writer that commits between slices would be a materially bigger
rewrite than reusing the assistant's existing pattern. Consider this the Parquet analogue of
`archive.to_s3`, not of `archive.partition`.

**A binary payload needs one new piece: a bytea-native request signer.** `archive.s3_signed_request`
above hashes its payload via `digest(convert_to(p_payload, 'UTF8'), 'sha256')`, which requires the
payload to be well-formed text in the server encoding. A Parquet file is binary -- its
Thrift-encoded footer alone guarantees stray `0x00` and high-bit-set bytes -- so `convert_to()`
raises `invalid byte sequence for encoding "UTF8"` on a real payload (confirmed: it does, on
exactly a literal `0x00`). `archive.s3_signed_request_bytea` below hashes the raw `bytea` directly
(no encoding involved) and crosses to `text` only once, at the network boundary, via the `http`
extension's `bytea_to_text()` -- confirmed from its C source to be a raw `memcpy` reinterpretation
of the same bytes, not a re-encode. That crossing was verified directly: a Parquet payload PUT
through it and fetched back from MinIO came back byte-for-byte identical, both before and after
adding SigV4 signing to the request.

```sql
create schema if not exists archive;   -- if not already created for the hooks above

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

create or replace function archive._pq_build_page_header(p_num_values int4, p_data_len int4) returns bytea
language plpgsql immutable as $$
declare
  dph bytea := archive._pq_build_data_page_header(p_num_values);
  buf bytea;
begin
  buf := archive._pq_write_i32(0, 1, 0);                    -- type = DATA_PAGE
  buf := buf || archive._pq_write_i32(1, 2, p_data_len);     -- uncompressed_page_size
  buf := buf || archive._pq_write_i32(2, 3, p_data_len);     -- compressed_page_size (codec = UNCOMPRESSED)
  buf := buf || archive._pq_write_struct(3, 5, dph);         -- data_page_header
  buf := buf || archive._pq_stop();
  return buf;
end;
$$;

create or replace function archive._pq_build_column_metadata(
    p_ptype int4, p_colname text, p_num_values bigint,
    p_total_uncompressed bigint, p_data_page_offset bigint
) returns bytea
language plpgsql immutable as $$
declare
  buf bytea;
begin
  buf := archive._pq_write_i32(0, 1, p_ptype);                                              -- type
  buf := buf || archive._pq_write_list_i32(1, 2, array[0]);                                 -- encodings = [PLAIN]
  buf := buf || archive._pq_write_list_binary(2, 3, array[convert_to(p_colname,'UTF8')]);   -- path_in_schema
  buf := buf || archive._pq_write_i32(3, 4, 0);                                            -- codec = UNCOMPRESSED
  buf := buf || archive._pq_write_i64(4, 5, p_num_values);                                  -- num_values
  buf := buf || archive._pq_write_i64(5, 6, p_total_uncompressed);                          -- total_uncompressed_size
  buf := buf || archive._pq_write_i64(6, 7, p_total_uncompressed);                          -- total_compressed_size
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
-- Column data extraction (server-side aggregation, ctid-ordered so every
-- column's array lines up on the same row order)
-- ---------------------------------------------------------------------------

-- p_nullable columns interleave nulls with real values (array_agg preserves NULLs in
-- position, so this is a single ctid-ordered pass either way); is_present[i] tracks which
-- rows had a value so the OPTIONAL path can prepend a definition-levels bitmap, while the
-- values-only payload always contains just the non-null values, in row order. For a NOT
-- NULL column every element is guaranteed non-null (Postgres enforces that at the table
-- level), so this collapses to the old unconditional-encode behavior byte-for-byte; only
-- p_nullable decides whether the definition-levels block gets prepended at all.
create or replace function archive._pq_encode_column_data(p_from_sql text, p_col text, p_pgtype text, p_nullable boolean) returns bytea
language plpgsql as $$
declare
  values_payload bytea := ''::bytea;
  is_present boolean[] := '{}';
  arr_i4 int4[]; arr_i8 int8[]; arr_f8 float8[]; arr_bool boolean[]; arr_text text[]; arr_ts timestamptz[];
  present_bools boolean[] := '{}';
  i int4; n int4;
begin
  if p_pgtype = 'int4' then
    execute format('select array_agg(%I::int4 order by ctid) from %s', p_col, p_from_sql) into arr_i4;
    n := coalesce(array_length(arr_i4,1),0);
    for i in 1..n loop
      is_present[i] := (arr_i4[i] is not null);
      if arr_i4[i] is not null then values_payload := values_payload || archive._pq_plain_int32(arr_i4[i]); end if;
    end loop;
  elsif p_pgtype = 'int8' then
    execute format('select array_agg(%I::int8 order by ctid) from %s', p_col, p_from_sql) into arr_i8;
    n := coalesce(array_length(arr_i8,1),0);
    for i in 1..n loop
      is_present[i] := (arr_i8[i] is not null);
      if arr_i8[i] is not null then values_payload := values_payload || archive._pq_plain_int64(arr_i8[i]); end if;
    end loop;
  elsif p_pgtype = 'float8' then
    execute format('select array_agg(%I::float8 order by ctid) from %s', p_col, p_from_sql) into arr_f8;
    n := coalesce(array_length(arr_f8,1),0);
    for i in 1..n loop
      is_present[i] := (arr_f8[i] is not null);
      if arr_f8[i] is not null then values_payload := values_payload || archive._pq_plain_double(arr_f8[i]); end if;
    end loop;
  elsif p_pgtype = 'bool' then
    execute format('select array_agg(%I::boolean order by ctid) from %s', p_col, p_from_sql) into arr_bool;
    n := coalesce(array_length(arr_bool,1),0);
    for i in 1..n loop
      is_present[i] := (arr_bool[i] is not null);
      if arr_bool[i] is not null then present_bools := present_bools || arr_bool[i]; end if;
    end loop;
    values_payload := archive._pq_plain_boolean_array(present_bools);
  elsif p_pgtype = 'text' then
    execute format('select array_agg(%I::text order by ctid) from %s', p_col, p_from_sql) into arr_text;
    n := coalesce(array_length(arr_text,1),0);
    for i in 1..n loop
      is_present[i] := (arr_text[i] is not null);
      if arr_text[i] is not null then values_payload := values_payload || archive._pq_plain_text(arr_text[i]); end if;
    end loop;
  elsif p_pgtype in ('timestamptz','timestamp') then
    execute format('select array_agg(%I::timestamptz order by ctid) from %s', p_col, p_from_sql) into arr_ts;
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

create or replace function archive._pq_to_parquet(p_relation regclass) returns bytea
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
  v_data bytea; v_page_header bytea; v_page_offset bigint;
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
    v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data));
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_data;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || archive._pq_build_column_chunk(
        archive._pq_build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset));
    v_schema_elements := v_schema_elements || archive._pq_build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i], v_col_nullable[i]);
  end loop;

  v_row_group := archive._pq_build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(archive._pq_build_schema_root(v_ncols), v_schema_elements);
  v_footer := archive._pq_build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  return v_body || v_footer || archive._pq_reverse_bytes(int4send(length(v_footer))) || v_magic;
end;
$$;

-- ---------------------------------------------------------------------------
-- Transport: a bytea-native SigV4 signer, and the pre_drop hook
-- ---------------------------------------------------------------------------
-- Why a separate signer from archive.s3_signed_request (archive-to-s3.md's multipart
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

-- The hook: single PUT, same shape and ceiling as archive.to_s3's basic (non-multipart)
-- variant -- one in-memory value, one call sends it. That is a deliberate, honest match, not
-- a shortcut: archive._pq_to_parquet reads every column via array_agg() with no COMMIT in
-- between (each column's array must come from the same snapshot as every other column's, or
-- concurrent writes between column reads could misalign rows across columns), so this holds
-- the vacuum horizon for the whole read+upload -- like the synchronous hook, not like the
-- per-part-committing archive assistant (archive-assistant.md). A streaming, row-group-per-slice
-- writer that preserves the assistant's bounded-horizon commit pattern is a bigger rewrite
-- (Parquet's footer needs every row group's byte offsets, known only once its data is built)
-- and is not attempted here; see the honest-limits note below.
create or replace function archive.to_s3_parquet(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  -- deployment constants: edit these four
  c_bucket   text := 'my-archive-bucket';
  c_region   text := 'us-east-1';
  c_prefix   text := 'events/';
  c_endpoint text := null;        -- null = AWS S3; an URL for S3-compatible, path prefix and all
                                  -- (e.g. 'https://<ref>.storage.supabase.co/storage/v1/s3')

  v_key_id text; v_secret text; v_key text; v_payload bytea; v_resp http_response;
begin
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = 's3_archive_access_key_id';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 's3_archive_secret_access_key';
  if v_key_id is null or v_secret is null then
    raise exception 'archive.to_s3_parquet: credentials missing from vault';
  end if;

  v_payload := archive._pq_to_parquet(p_child::regclass);
  v_key := c_prefix || p_child || '.parquet';

  v_resp := archive.s3_signed_request_bytea('PUT', c_endpoint, c_bucket, c_region, v_key, '',
                                            'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then
    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
  end if;
end;
$$;
```

## Register the Parquet hook

Same shape as the hooks above; only the function name changes:

```sql
select pgpm.hook_register('public.events', 'pre_drop', 'archive.to_s3_parquet(regclass,name,text,text)');
update pgpm.config set retain_batch = 1 where parent_table = 'public.events'::regclass;
```

## Verified end-to-end, through the real `retire()` path

Driven against a live `http`-extension Postgres instance and MinIO, through `pgpm.retire()` (the
same sanctioned drop path `retain()` uses), not a standalone call to the encoder:

- **Happy path**: a real partition (`transmute`d, `obtain`ed, 50 real rows) archived and dropped in
  one `retire()` call. The object fetched back from MinIO and read by both pyarrow and DuckDB
  (two independent Parquet implementations, agreeing) matched the source rows exactly -- same ids,
  same payloads, same order.
- **Backstop veto**: pointing the hook at a broken endpoint made `retire()` return `false` and
  leave the partition and its row in place, with `retain_hook_fail` logging the real S3 error
  verbatim (`HTTP 404`, `NoSuchBucket`) -- the same failure contract as `archive.to_s3` above.
- **Self-repair**: restoring the working endpoint and calling `retire()` again on the same
  partition archived and dropped it cleanly, no intervention beyond fixing the endpoint.

## Honest limits, for the Parquet variant

- **Same ceiling as the single-PUT hook, not the multipart one.** The payload is one in-memory
  `bytea` (Postgres's ~1GB cap, same practical ceiling as the `text` variant above); nothing here
  streams. Chunking the *already-built* Parquet `bytea` into fixed-size byte ranges for a
  multipart upload is mechanically straightforward (S3 multipart just concatenates bytes; it does
  not care that a byte-range boundary falls in the middle of a row group), but it was not built in
  this pass -- said plainly rather than implied.
- **Nullable columns supported, but only single-level (no nesting).** This schema is always flat
  (no repeated fields, no groups), so `max_definition_level` never needs to exceed 1 and the
  definition-levels bitmap stays a single bit-packed run per page. A nested/repeated schema would
  need more than this rung builds.
- **Six types.** `int4`, `int8`, `float8`, `boolean`, `text`, `timestamp`/`timestamptz`. Anything
  else (arrays, JSON/JSONB, `numeric`, composite types, `uuid`) is refused loudly by
  `archive._pq_to_parquet` rather than silently coerced; cast to a supported type in a view over
  the child, or extend the encoder, if you need one of these archived this way.
- **One row group, no dictionary encoding, no compression, no statistics.** All legal Parquet, all
  readable by every reader tested, none of it as compact as a tuned writer would produce. This is
  the minimal-viable rung, not the ambitious one; see #199 for pg_parquet/Iceberg as the extension-
  dependent alternative if that tradeoff matters more than the zero-dependency property does.
- **This hook's horizon-hold is bounded by partition size, which is emergent, not by a chosen
  file size.** If partitions grow large enough (or unevenly enough) that this matters, see
  [Chunked, cross-partition Parquet archival](archive-chunked-parquet.md), which decouples
  Parquet file boundaries from partition boundaries entirely so the hold is bounded by a target
  file size instead.

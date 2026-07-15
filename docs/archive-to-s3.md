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

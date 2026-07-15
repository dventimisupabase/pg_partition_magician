# Archive partitions to S3 before retention drops them

A complete, working `pre_drop` hook that copies a partition's rows to AWS S3 (or any S3-compatible
store) before `retain()` drops it, and blocks the drop when the copy fails. This is a **worked example
of a user-supplied hook**, not part of pg_partition_magician: copy it, edit the constants, and own it.
The [guide](guide.md#pre-drop-hooks) introduces the hook mechanism; `hook_register` in the
[reference](reference.md#hook_register) has the full contract.

The function below was verified end-to-end against MinIO's full AWS Signature Version 4 enforcement,
driven by the real `retain()` path: a 50,000-row partition archived and dropped; an outage (endpoint
down) blocking the drop with the failure logged and surfaced; and the paced backlog draining to zero
after recovery, empty partitions included.

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

```sql
create extension if not exists http;
create extension if not exists pgcrypto;

-- Export the partition's rows to S3 as NDJSON, synchronously, and raise if the upload did not
-- succeed (so retain() keeps the partition and retries next tick).
create or replace function public.archive_to_s3(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  -- deployment constants: edit these four
  c_bucket   text := 'my-archive-bucket';
  c_region   text := 'us-east-1';
  c_prefix   text := 'events/';   -- key prefix inside the bucket ('' for none)
  c_endpoint text := null;        -- null = AWS S3; an URL (e.g. 'http://minio:9000') for S3-compatible

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
    raise exception 'archive_to_s3: credentials missing from vault (s3_archive_access_key_id / s3_archive_secret_access_key)';
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
    v_host := regexp_replace(c_endpoint, '^https?://', '');         -- path style (MinIO et al.)
    v_uri  := '/' || c_bucket || '/' || v_key;
    v_url  := c_endpoint || v_uri;
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
    raise exception 'archive_to_s3: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
  end if;
end;
$$;
```

A retried upload is naturally safe: a PUT to the same key overwrites, so a hook that succeeded on S3
but failed to report (or a partition retried after a partial outage) never duplicates or corrupts the
archive.

## Register and pace it

```sql
select pgpm.hook_register('public.events', 'pre_drop', 'public.archive_to_s3(regclass,name,text,text)');
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
  `partition_step` whose partitions are tens-to-hundreds of MB; for bigger partitions, have the hook
  notify an external worker with a real AWS SDK instead of uploading in-line.
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

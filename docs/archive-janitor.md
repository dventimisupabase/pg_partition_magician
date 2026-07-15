# The archive janitor: bounded vacuum-horizon holds, janitor-owned drops

A standing scanner that archives aged partitions to S3 **with per-part commits**, so the vacuum
horizon is held for at most one part's network time instead of a whole partition's upload, and then
drops each partition itself through [`pgpm.retire`](reference.md#retire). This is the variant of
[Archive partitions to S3](archive-to-s3.md) for when that page's synchronous hook holds its
transaction open longer than you like -- big partitions, slow links, or a database whose vacuum you
will not gamble with. It reuses that page's `s3_url_encode` and `s3_signed_request` functions
(deploy the multipart section's SQL first); everything here is user-land, like every hook: pgpm
ships none of it.

## Why: statements hold snapshots

Any code executing inside Postgres executes inside a statement, a statement holds a registered
snapshot, and the backend's oldest registered snapshot pins the xmin horizon that autovacuum may
clean up to -- unconditionally, even while the statement is only waiting on the network. The
synchronous hook therefore pins the horizon for a whole partition's read **plus upload**. A
`PROCEDURE` that `COMMIT`s between statements cannot get that to zero (there is no way to run
PL/pgSQL between statements), but it can bound it: read one part (a disk-speed moment), commit the
snapshot away, PUT one part (one part's network time), commit again. The bound is `c_part_bytes`
over your bandwidth, tunable down to S3's 5MiB part minimum.

Measured, same ~110MB partition, same ~1s wall-clock, against MinIO: the synchronous hook's backend
showed **one** `backend_xmin` for its entire run (the horizon pinned start to finish); the janitor's
backend showed **eleven distinct, advancing values in eleven samples** (the horizon free to move
between every part). Zero horizon cost during network time takes an external worker -- that remains
the top rung -- but the janitor gets the windows down to seconds, entirely in-database.

## The division of labor

- **The scanner procedure does the work**: find retention-eligible partitions, archive the
  unarchived (or changed) ones part by part, then `pgpm.retire()` each -- the claim-guarded
  sanctioned drop, safe alongside `retain()` and other janitors.
- **The ledger records the fact**: one row per archived partition (`key`, `ETag`, `rows_archived`),
  written by the archiver at the moment the store confirmed the object. Never job history: a cron
  run's "succeeded" is evidence about the mechanism, not the guarantee.
- **The gate hook owns the veto**: registered as an ordinary `pre_drop` hook, it defers any drop of
  a partition that is unarchived or has changed since archiving. Because `retire()` runs the hooks
  on every drop path, the gate fires for the janitor's own drops (defense in depth) and keeps
  `config.retain` safe to leave set as a further-out backstop: if the janitor wedges, scheduled
  retention defers loudly instead of destroying unarchived data.

## The ledger and the gate

```sql
-- the ledger: one row per archived partition, written by the archiver at the moment it verified
-- the upload. The drop gate consults THIS, never job history.
create table if not exists public.archived (
  parent_table  regclass    not null,
  child_name    name        not null,
  s3_key        text        not null,
  etag          text,
  rows_archived bigint      not null,
  archived_at   timestamptz not null default now(),
  primary key (parent_table, child_name)
);

-- the veto: raises (deferring the drop) unless the partition is archived AND the archive still
-- matches the live partition. Runs on EVERY drop path (retire() runs the hooks), so it passes
-- trivially right after the janitor archives, and it blocks retain()'s backstop from ever
-- dropping unarchived or changed data. NOTE the contract is a row-count comparison: it catches
-- late-arriving/backdated rows (the realistic mutation of aged time-series data) but not a
-- same-count mutation (an UPDATE, or an insert+delete pair); aged partitions are assumed
-- effectively append-only, as in most retention workloads.
create or replace function public.archive_gate(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare v_nsp name; v_rows bigint; v_live bigint;
begin
  select rows_archived into v_rows from public.archived
   where parent_table = p_parent and child_name = p_child;
  if v_rows is null then
    raise exception 'archive_gate: % is not archived yet; deferring the drop', p_child;
  end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  execute format('select count(*) from %I.%I', v_nsp, p_child) into v_live;
  if v_live is distinct from v_rows then
    raise exception 'archive_gate: % changed since it was archived (% rows live, % archived); deferring for re-archive',
      p_child, v_live, v_rows;
  end if;
end;
$$;
```

The gate compares **row counts**, so it catches the realistic mutation of aged data (a backdated or
late-arriving row) but not a same-count mutation (an `UPDATE`, or an insert+delete pair). Aged
partitions are assumed effectively append-only, as in most retention workloads; if yours are not,
extend the ledger with a content checksum.

## The archiver

```sql
-- the work: archive ONE partition, holding the vacuum horizon for at most one part-window at a
-- time. A PROCEDURE, not a function: it COMMITs after every statement that held a snapshot (each
-- part's read, each network call), and procedure-local variables (the keyset cursor, the
-- UploadId, the ETag list) survive those commits. PL/pgSQL forbids transaction control inside a
-- block with an EXCEPTION clause, so this procedure has NO handler and cannot abort-on-exit;
-- instead it CLEANS UP ON ENTRY (aborting any stale in-flight upload for its key, which also
-- covers crashed runs) and relies on a bucket lifecycle rule as the final backstop.
create or replace procedure public.archive_partition(p_parent regclass, p_child name)
language plpgsql as $$
declare
  -- deployment constants: edit these four
  c_bucket   text := 'my-archive-bucket';
  c_region   text := 'us-east-1';
  c_prefix   text := 'events/';
  c_endpoint text := null;        -- null = AWS S3; an URL for S3-compatible, path prefix and all

  c_part_bytes int := 8 * 1024 * 1024;   -- per-part size = the horizon-hold bound: one part's network time
  c_fetch_rows int := 20000;
  v_ctype text := 'application/x-ndjson';

  v_key_id text; v_secret text; v_nsp name; v_control name; v_ctltype text; v_key text;
  v_part_payload text; v_chunk text; v_cursor text; v_done boolean := false;
  v_upload_id text; v_part int := 0; v_etag text; v_parts_xml text := '';
  v_rows bigint := 0; v_n bigint; v_stale text;
  v_resp http_response; h http_header;
begin
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = 's3_archive_access_key_id';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 's3_archive_secret_access_key';
  if v_key_id is null or v_secret is null then
    raise exception 'archive_partition: credentials missing from vault';
  end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select control_column into v_control from pgpm.config where parent_table = p_parent;
  select a.atttypid::regtype::text into v_ctltype
    from pg_attribute a where a.attrelid = p_parent and a.attname = v_control;
  v_key := c_prefix || p_child || '.ndjson';
  commit;   -- nothing above needs to stay open

  -- cleanup-on-entry: abort any in-flight multipart upload a failed or crashed prior run left
  -- behind for this key (invisible in listings, billed until aborted)
  v_resp := public.s3_signed_request('GET', c_endpoint, c_bucket, c_region, '',
                                     'prefix=' || public.s3_url_encode(v_key) || '&uploads=',
                                     'application/xml', '', v_key_id, v_secret);
  for v_stale in
    select unnest(xpath('//*[local-name()=''Upload'']/*[local-name()=''UploadId'']/text()', v_resp.content::xml))::text
  loop
    perform public.s3_signed_request('DELETE', c_endpoint, c_bucket, c_region, v_key,
                                     'uploadId=' || public.s3_url_encode(v_stale),
                                     'text/plain', '', v_key_id, v_secret);
  end loop;
  commit;

  -- stream the partition: read one part (snapshot held for a disk-speed moment, then COMMITted
  -- away), PUT it (snapshot held for one part's network time, then COMMITted away), repeat.
  v_part_payload := '';
  v_cursor := null;
  <<parts>>
  loop
    while not v_done and octet_length(v_part_payload) < c_part_bytes loop
      execute format(
        'select coalesce(string_agg(j, e''\n'' order by k), ''''), (array_agg(k order by k desc))[1]::text, count(*)
           from (select row_to_json(t)::text as j, t.%I as k from %I.%I t
                  where $1 is null or t.%I > $1::%s
                  order by t.%I limit $2) s',
        v_control, v_nsp, p_child, v_control, v_ctltype, v_control)
        into v_chunk, v_cursor, v_n using v_cursor, c_fetch_rows;
      if v_chunk = '' then v_done := true;
      else v_part_payload := v_part_payload || v_chunk || e'\n'; v_rows := v_rows + v_n;
      end if;
      commit;   -- release the read snapshot before any network time
    end loop;

    exit parts when v_done and v_part > 0 and v_part_payload = '';

    if v_part = 0 and v_done then
      -- everything fit in one part: plain single PUT, no multipart bookkeeping
      v_resp := public.s3_signed_request('PUT', c_endpoint, c_bucket, c_region, v_key, '',
                                         v_ctype, v_part_payload, v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive_partition: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      foreach h in array v_resp.headers loop
        if lower(h.field) = 'etag' then v_etag := h.value; end if;
      end loop;
      exit parts;
    end if;

    if v_part = 0 then
      v_resp := public.s3_signed_request('POST', c_endpoint, c_bucket, c_region, v_key, 'uploads=',
                                         v_ctype, '', v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive_partition: initiate multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      v_upload_id := (xpath('//*[local-name()=''UploadId'']/text()', v_resp.content::xml))[1]::text;
      commit;
    end if;

    v_part := v_part + 1;
    v_resp := public.s3_signed_request('PUT', c_endpoint, c_bucket, c_region, v_key,
                                       'partNumber=' || v_part || '&uploadId=' || public.s3_url_encode(v_upload_id),
                                       v_ctype, v_part_payload, v_key_id, v_secret);
    if v_resp.status not between 200 and 299 then
      raise exception 'archive_partition: part % of % failed: HTTP % %', v_part, p_child, v_resp.status, left(v_resp.content, 200);
    end if;
    v_etag := null;
    foreach h in array v_resp.headers loop
      if lower(h.field) = 'etag' then v_etag := h.value; end if;
    end loop;
    v_parts_xml := v_parts_xml || format('<Part><PartNumber>%s</PartNumber><ETag>%s</ETag></Part>', v_part, v_etag);
    v_part_payload := '';
    commit;   -- the horizon-hold window ends here; vacuum may advance before the next part
    exit parts when v_done;
  end loop;

  if v_part > 0 then
    v_resp := public.s3_signed_request('POST', c_endpoint, c_bucket, c_region, v_key,
                                       'uploadId=' || public.s3_url_encode(v_upload_id),
                                       'application/xml',
                                       '<CompleteMultipartUpload>' || v_parts_xml || '</CompleteMultipartUpload>',
                                       v_key_id, v_secret);
    if v_resp.status not between 200 and 299 or v_resp.content like '%<Error>%' then
      raise exception 'archive_partition: complete multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
    end if;
    v_etag := null;
    v_etag := (xpath('//*[local-name()=''ETag'']/text()', v_resp.content::xml))[1]::text;
  end if;

  -- the ledger row: written only now, after the store confirmed the object. A crash between the
  -- complete and this insert just re-archives next scan (a PUT to the same key overwrites; the
  -- cleanup-on-entry finds nothing in flight because the upload completed).
  insert into public.archived (parent_table, child_name, s3_key, etag, rows_archived)
  values (p_parent, p_child, v_key, v_etag, v_rows)
  on conflict (parent_table, child_name)
    do update set s3_key = excluded.s3_key, etag = excluded.etag,
                  rows_archived = excluded.rows_archived, archived_at = now();
  commit;
end;
$$;
```

Two PL/pgSQL rules shape this procedure. Procedure-local variables **survive `COMMIT`**, which is
what lets the keyset cursor, the UploadId, and the ETag list ride across the per-part commits with
no staging table. And transaction control is **forbidden inside a block with an `EXCEPTION`
clause**, so a committing procedure cannot abort-on-exit the way the synchronous hook does; instead
it cleans up on entry (which also covers crashed runs, which no exit handler ever could) and leans
on a bucket lifecycle rule (`AbortIncompleteMultipartUpload`) as the final backstop.

## The scanner

```sql
-- the scanner: one standing pg_cron job. Finds every retention-eligible partition of every
-- managed table, archives the unarchived (or stale) ones, and retires each through
-- pgpm.retire() -- the claim-guarded sanctioned drop, which also runs the gate (defense in
-- depth: a janitor bug that reached retire() with a bad archive would still be vetoed).
create or replace procedure public.archive_scan()
language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_ncast text;
  v_work  record; v_targets jsonb := '[]';
  v_rows bigint; v_live bigint; v_nsp name;
begin
  -- session-level advisory lock: pg_cron happily overlaps runs of the same job, and a second
  -- scanner mid-upload would double-archive. Session locks survive the COMMITs below.
  if not pg_try_advisory_lock(hashtext('pgpm-archiver')) then return; end if;

  -- materialize the work list first (loop-with-COMMIT over a live cursor is legal since PG11,
  -- but a fixed list is simpler to reason about; eligibility is re-checked by retire() anyway)
  for cfg in select * from pgpm.config where retain is not null loop
    v_boundary := pgpm._retain_boundary(cfg);
    v_ncast    := pgpm._native_type(cfg.control_kind);
    for v_work in execute format(
      'select child_name from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s order by lo::%s',
      cfg.parent_table::text, v_ncast, v_boundary, v_ncast, v_ncast)
    loop
      v_targets := v_targets || jsonb_build_array(jsonb_build_object('parent', cfg.parent_table::text, 'child', v_work.child_name));
    end loop;
  end loop;
  commit;

  for v_work in select (t->>'parent')::regclass as parent, (t->>'child')::name as child
                  from jsonb_array_elements(v_targets) t
  loop
    -- archive when there is no fresh ledger row (missing, or stale: the live count moved)
    select a.rows_archived into v_rows from public.archived a
     where a.parent_table = v_work.parent and a.child_name = v_work.child;
    select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = v_work.parent;
    execute format('select count(*) from %I.%I', v_nsp, v_work.child) into v_live;
    commit;
    if v_rows is null or v_rows is distinct from v_live then
      call public.archive_partition(v_work.parent, v_work.child);
    end if;
    perform pgpm.retire(v_work.parent, v_work.child);
    commit;
  end loop;

  perform pg_advisory_unlock(hashtext('pgpm-archiver'));
end;
$$;
```

The eligibility scan uses `pgpm._retain_boundary` and `pgpm._native_type` -- internal but stable
helpers (the same ones `retain()` uses); inline the horizon arithmetic if you would rather not
reference them. Concurrency comes in layers: the session-level advisory lock keeps pg_cron from
overlapping two scanners (pg_cron happily starts a run while the previous one is still going), and
even without it, `retire()`'s `FOR UPDATE SKIP LOCKED` claim means racing janitors could
double-*archive* (wasted work, safe: a PUT to the same key overwrites) but never double-*drop*.

## Install

```sql
select pgpm.hook_register('public.events', 'pre_drop', 'public.archive_gate(regclass,name,text,text)');
select cron.schedule('pgpm-archiver', '* * * * *', 'call public.archive_scan()');
select pgpm.schedule();   -- the usual maintenance, now the further-out backstop
```

Unlike the synchronous hook, this needs **no `retain_batch`**: the gate is a count lookup, so even
an unbounded `retain()` pass over an archived backlog is quick. The knob that matters here is
`c_part_bytes`, the horizon-hold bound.

## Failure semantics, verified

The exact SQL above (deployment constants aside) was driven end-to-end against MinIO's SigV4
enforcement:

- **Happy path**: one `archive_scan()` call archived five eligible partitions (a ~26MiB one as a
  3-part multipart upload, four empties via the single-PUT fast path) and retired all five, with the
  gate passing on each retire. A ~110MB partition archived as a 10-part upload, account-checked at
  600,000 contiguous rows.
- **Backstop veto**: an eligible-but-unarchived partition made `retain()` drop nothing, logging
  `archive_gate: ... is not archived yet` -- the flat-`retain_backlog`, climbing-
  `retain_hook_failures` wedge signature.
- **Stale veto and self-repair**: a row backdated into an archived-but-not-yet-retired partition
  made the gate defer with `changed since it was archived (5001 rows live, 5000 archived)`; the next
  `archive_scan()` re-archived (overwriting the same key) and retired it. The archiver owns the
  repair; the gate owns the veto (a raising hook's writes roll back, so it could not durably flag
  anything anyway).
- **Crash cleanup**: a simulated network failure during part 2 killed the scan mid-partition,
  leaving one invisible in-flight upload on the store; the next scan's cleanup-on-entry aborted it
  (confirmed by `ListMultipartUploads`: zero in-flight), then re-archived and retired the partition.
- **The horizon measurement** quoted above: 1 distinct `backend_xmin` (synchronous hook) versus 11
  advancing values (janitor), same payload, same duration.

The same scenario then ran on a live Supabase project against
[Supabase Storage's S3-compatible endpoint](https://supabase.com/docs/guides/storage/s3/authentication):
the full matrix again (happy path with the same deterministic composite ETags, both vetoes,
self-repair, crash cleanup confirmed via `ListMultipartUploads`), plus the horizon measurement at
full scale over a real network: a ~110MB partition archived as a 10-part upload in ~20s with **20
distinct advancing `backend_xmin` values in 27 samples**, versus the synchronous hook's **one pinned
value** for its entire equal-sized run.

## Supabase ceilings, discovered the honest way

Two platform limits surfaced during the live verification; both apply to any of these archival
patterns on Supabase, and both fail loudly:

- **Storage enforces the project's upload file size limit on the S3 protocol too** -- default
  **50MB**, counted against the whole object, so a multipart upload is rejected mid-flight
  (`HTTP 413`, `EntityTooLarge`, on whichever part crosses the line; boundary-verified: a 49MB PUT
  passes, a 51MB PUT fails). The hook raises, the drop defers, nothing is lost -- but archives
  bigger than the limit never succeed until you raise it: Dashboard, **Storage -> Files ->
  Settings**, "Upload file size limit". The janitor's cleanup-on-entry reclaims the rejected
  upload's parts on the next scan.
- **`statement_timeout` is 2 minutes on Supabase** (set in the server's configuration file, so it
  applies over the pooler and direct connections alike). The *synchronous hook* runs a whole
  partition's upload inside one statement, so that is its hard wall-clock ceiling there; a session
  `set statement_timeout = ...` overrides it (configuration-file settings yield to session GUCs),
  e.g. in the pg_cron job command. The janitor barely notices: each of its statements only has to
  fit one part's read or upload inside the window.

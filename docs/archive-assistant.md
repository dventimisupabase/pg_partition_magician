# The archive assistant: bounded vacuum-horizon holds, assistant-owned drops

A standing scanner that archives aged partitions to S3 **with per-part commits**, so the vacuum
horizon is held for at most one part's network time instead of a whole partition's upload, and then
drops each partition itself through [`pgpm.retire`](reference.md#retire). This is the variant of
[Archive partitions to S3](archive-to-s3.md) for when that page's synchronous hook holds its
transaction open longer than you like -- big partitions, slow links, or a database whose vacuum you
will not gamble with. It reuses that page's `archive.s3_url_encode` and `archive.s3_signed_request` functions
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
showed **one** `backend_xmin` for its entire run (the horizon pinned start to finish); the assistant's
backend showed **eleven distinct, advancing values in eleven samples** (the horizon free to move
between every part). Zero horizon cost during network time takes an external worker -- that remains
the top rung -- but the assistant gets the windows down to seconds, entirely in-database.

## The division of labor

- **The scanner procedure does the work**: find retention-eligible partitions, archive the
  unarchived (or changed) ones part by part, then `pgpm.retire()` each -- the claim-guarded
  sanctioned drop, safe alongside `retain()` and other assistants.
- **The ledger records the fact**: one row per archived range (`lo`/`hi`, `key`, `ETag`,
  `rows_archived`), written by the archiver at the moment the store confirmed the object. Never job
  history: a cron run's "succeeded" is evidence about the mechanism, not the guarantee.
- **The gate hook owns the veto**: registered as an ordinary `pre_drop` hook, it defers any drop of
  a partition that is unarchived or has changed since archiving. Because `retire()` runs the hooks
  on every drop path, the gate fires for the assistant's own drops (defense in depth) and keeps
  `config.retain` safe to leave set as a further-out backstop: if the assistant wedges, scheduled
  retention defers loudly instead of destroying unarchived data.

## The ledger and the gate

Everything on this page (and its companion) lives in a dedicated `archive` schema, **not** in
`public`: on Supabase, `public` is typically exposed through the Data API, which would make the
ledger readable over REST and every function callable as RPC (PostgreSQL grants `EXECUTE` to
`PUBLIC` on new functions by default). Archival machinery has no business being API-visible;
PostgREST only serves schemas you explicitly expose, so a dedicated schema keeps it dark.

```sql
create schema if not exists archive;

-- the ledger: one row per archived range, written by the archiver at the moment it verified the
-- upload. The drop gate consults THIS, never job history. A partition's own bounds are already a
-- native-grid [lo, hi) range -- the same shape a cross-partition, byte-budget-aligned archiver
-- (docs/archive-chunked-parquet.md) needs for a range that spans part of one partition or several
-- -- so this table is shared by both: `lo` is the primary key (ranges never overlap, by either
-- archiver's own invariant), and `child_name` is an optional convenience column, populated only
-- when the archived range happens to equal exactly one partition's bounds, so a name-based lookup
-- stays a cheap equality check instead of a bounds-membership query.
create table if not exists archive.ledger (
  parent_table  regclass    not null,
  lo            text        not null,   -- native-grid text, same convention as pgpm.config lo/hi
  hi            text        not null,
  child_name    name,                   -- populated iff [lo, hi) is exactly one partition's bounds
  s3_key        text        not null,
  etag          text,
  rows_archived bigint      not null,
  archived_at   timestamptz not null default now(),
  primary key (parent_table, lo)
);
create index on archive.ledger (parent_table, hi desc);   -- cheap max(hi) for range-based readers
```

The **watermark** for a managed parent `P` is `max(hi)` over its ledger rows: everything below it
is guaranteed durably archived (uploaded, confirmed, ledgered). Nothing here stores a separate
cursor -- the watermark is *derived* from the ledger on every read, so there is no second piece of
state that could drift out of sync with what was actually archived. That guarantee only holds if
the ledger's coverage is contiguous and gap-free from wherever it starts; `archive.partition`
(below) enforces that on the write side, so the watermark can stay a cheap `max()` on the read side
instead of a real contiguity scan.

The gate itself raises (deferring the drop) unless `[p_lo, p_hi)` is durably archived and still
matches the live rows. It runs on EVERY drop path (`retire()` runs the hooks), so it passes
trivially right after archiving and blocks `retain()`'s backstop from ever dropping unarchived or
changed data. Two parts:

1. **Fast path**: `p_hi <= watermark(p_parent)`, derived, no scan. False means `[p_lo, p_hi)` is
   not fully archived yet -- defer.
2. **Defense in depth**: for every ledger row overlapping `[p_lo, p_hi)`, recount that row's
   *entire* range live and compare to its recorded `rows_archived`. A mismatch anywhere defers the
   drop, even if the actual stray landed in a sibling partition sharing the same ledger row --
   intentionally conservative, and it fails safe rather than silently dropping something that
   changed.

The contract is a row-count comparison: it catches late-arriving/backdated rows (the realistic
mutation of aged time-series data) but not a same-count mutation (an `UPDATE`, or an insert+delete
pair); aged partitions are assumed effectively append-only, as in most retention workloads.

The recount alone is not quite enough, and the gap matters: a naive comparison against a ledger
row's *original* `rows_archived` breaks the moment two partitions covered by the same row are
dropped in separate `retire()` calls -- the normal case once a range spans more than one partition,
since `retain_batch` paces drops one at a time. Drop the first partition, and the second's *later*
check would recount the row's live range and find fewer rows than the original `rows_archived` --
the first partition's rows are legitimately gone now -- which is indistinguishable from a real
stray under a static comparison, and would wedge the second drop forever. The fix: once a row's
recount passes and a partition's drop is about to proceed, decrement that row's `rows_archived` by
exactly the overlap between the partition being dropped and the row's range (never more, for a
partition spanning more than one row), so the next check compares against what is *actually still
expected to be live*, not a number frozen at archive time. This is safe as a `pre_drop` hook side
effect: `pgpm.retire()` runs its hooks and the `DROP` inside one subtransaction (the `EXCEPTION`
block is an implicit savepoint), so a failed drop rolls the decrement back with everything else,
and `FOR UPDATE` on the ledger rows serializes concurrent `retire()` calls racing on partitions that
share a row.

```sql
-- the derived watermark: kind-aware (numeric for id, timestamptz otherwise, matching
-- pgpm.config.control_kind), so a plain lexicographic max on the stored text never runs.
create or replace function archive._file_watermark(p_parent regclass) returns text
language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_wm text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._file_watermark: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select max(hi::%s)::text from archive.ledger where parent_table = %L::regclass',
                 v_ncast, p_parent::text) into v_wm;
  return v_wm;
end;
$$;

create or replace function archive.file_gate(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; v_wm text; v_nsp name; v_rel name;
  r record; v_overlap_live bigint; v_ov_lo text; v_ov_hi text; v_child_overlap bigint;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive.file_gate: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  -- fast path: derived, no scan
  v_wm := archive._file_watermark(p_parent);
  if v_wm is null or pgpm._native_gt(cfg.control_kind, p_hi, v_wm) then
    raise exception 'archive.file_gate: % (hi %) is not yet fully covered by the ledger watermark (%); deferring the drop',
      p_child, p_hi, coalesce(v_wm, '<none>');
  end if;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- defense in depth: every ledger row overlapping [p_lo, p_hi), whole-range recounted
  for r in
    execute format(
      'select lo, hi, rows_archived from archive.ledger
        where parent_table = %L::regclass and hi::%s > %L::%s and lo::%s < %L::%s
        for update',
      p_parent::text, v_ncast, p_lo, v_ncast, v_ncast, p_hi, v_ncast)
  loop
    execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                   v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, r.lo),
                   cfg.control_column, pgpm._encode(cfg.control_kind, r.hi))
      into v_overlap_live;
    if v_overlap_live is distinct from r.rows_archived then
      raise exception 'archive.file_gate: file % [%, %) changed since it was archived (% rows live, % archived); deferring for re-archive',
        (select s3_key from archive.ledger where parent_table = p_parent and lo = r.lo),
        r.lo, r.hi, v_overlap_live, r.rows_archived;
    end if;

    -- keep rows_archived in lockstep: subtract exactly the overlap between the partition about
    -- to be dropped and this row's range (a partition can span more than one row; each gets only
    -- its own slice subtracted).
    v_ov_lo := case when pgpm._native_gt(cfg.control_kind, p_lo, r.lo) then p_lo else r.lo end;
    v_ov_hi := case when pgpm._native_gt(cfg.control_kind, r.hi, p_hi) then p_hi else r.hi end;
    execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                   v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, v_ov_lo),
                   cfg.control_column, pgpm._encode(cfg.control_kind, v_ov_hi))
      into v_child_overlap;
    update archive.ledger set rows_archived = rows_archived - v_child_overlap
      where parent_table = p_parent and lo = r.lo;
  end loop;
end;
$$;
```

## The archiver

```sql
-- the work: archive ONE partition, holding the vacuum horizon for at most one part-window at a
-- time. A PROCEDURE, not a function: it COMMITs after every statement that held a snapshot (each
-- part's read, each network call), and procedure-local variables (the keyset cursor, the
-- UploadId, the ETag list) survive those commits. PL/pgSQL forbids transaction control inside a
-- block with an EXCEPTION clause, so this procedure has NO handler and cannot abort-on-exit;
-- instead it CLEANS UP ON ENTRY (aborting any stale in-flight upload for its key, which also
-- covers crashed runs) and relies on a bucket lifecycle rule as the final backstop.
create or replace procedure archive.partition(p_parent regclass, p_child name)
language plpgsql as $$
declare
  -- deployment constants: edit these four
  c_bucket   text := 'my-archive-bucket';
  c_region   text := 'us-east-1';
  c_prefix   text := 'events/';
  c_endpoint text := null;        -- null = AWS S3; an URL for S3-compatible, path prefix and all
                                  -- (e.g. 'https://<ref>.storage.supabase.co/storage/v1/s3')

  c_part_bytes int := 8 * 1024 * 1024;   -- per-part size = the horizon-hold bound: one part's network time
  c_fetch_rows int := 20000;
  v_ctype text := 'application/x-ndjson';

  v_key_id text; v_secret text; v_nsp name; v_control name; v_ctltype text; v_key text;
  v_part_payload text; v_chunk text; v_cursor text; v_done boolean := false;
  v_upload_id text; v_part int := 0; v_etag text; v_parts_xml text := '';
  v_rows bigint := 0; v_n bigint; v_stale text; v_lo text; v_hi text;
  v_reledger boolean; v_expected_lo text;
  v_resp http_response; h http_header;
begin
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = 's3_archive_access_key_id';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 's3_archive_secret_access_key';
  if v_key_id is null or v_secret is null then
    raise exception 'archive.partition: credentials missing from vault';
  end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select control_column into v_control from pgpm.config where parent_table = p_parent;
  select lo, hi into v_lo, v_hi from pgpm.part where parent_table = p_parent and child_name = p_child;

  -- forward-only guard: archive.file_gate's fast path trusts the ledger's watermark to mean
  -- "everything below this is archived" -- true only if coverage is gap-free from wherever the
  -- ledger starts. archive._chunk_one (docs/archive-chunked-parquet.md) enforces that by
  -- construction, always extending the watermark forward; this procedure takes an arbitrary
  -- child name, so it enforces the same contract explicitly. A re-archive of an already-ledgered
  -- partition (the stale-veto self-repair path) is exempt -- it overwrites its own existing row,
  -- not extending the frontier.
  select exists(select 1 from archive.ledger where parent_table = p_parent and lo = v_lo) into v_reledger;
  if not v_reledger then
    select coalesce(archive._file_watermark(p_parent), (select min(lo) from pgpm.part where parent_table = p_parent))
      into v_expected_lo;
    if v_lo is distinct from v_expected_lo then
      raise exception 'archive.partition: % [lo %] is out of order -- % is next expected to archive lo %; archive partitions in ascending lo order (archive.scan always does) so the shared ledger stays gap-free for archive.file_gate''s fast path',
        p_child, v_lo, p_parent, coalesce(v_expected_lo, '<none>');
    end if;
  end if;

  select a.atttypid::regtype::text into v_ctltype
    from pg_attribute a where a.attrelid = p_parent and a.attname = v_control;
  v_key := c_prefix || p_child || '.ndjson';
  commit;   -- nothing above needs to stay open

  -- cleanup-on-entry: abort any in-flight multipart upload a failed or crashed prior run left
  -- behind for this key (invisible in listings, billed until aborted)
  v_resp := archive.s3_signed_request('GET', c_endpoint, c_bucket, c_region, '',
                                     'prefix=' || archive.s3_url_encode(v_key) || '&uploads=',
                                     'application/xml', '', v_key_id, v_secret);
  for v_stale in
    select unnest(xpath('//*[local-name()=''Upload'']/*[local-name()=''UploadId'']/text()', v_resp.content::xml))::text
  loop
    perform archive.s3_signed_request('DELETE', c_endpoint, c_bucket, c_region, v_key,
                                     'uploadId=' || archive.s3_url_encode(v_stale),
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
      v_resp := archive.s3_signed_request('PUT', c_endpoint, c_bucket, c_region, v_key, '',
                                         v_ctype, v_part_payload, v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive.partition: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      foreach h in array v_resp.headers loop
        if lower(h.field) = 'etag' then v_etag := h.value; end if;
      end loop;
      exit parts;
    end if;

    if v_part = 0 then
      v_resp := archive.s3_signed_request('POST', c_endpoint, c_bucket, c_region, v_key, 'uploads=',
                                         v_ctype, '', v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive.partition: initiate multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      v_upload_id := (xpath('//*[local-name()=''UploadId'']/text()', v_resp.content::xml))[1]::text;
      commit;
    end if;

    v_part := v_part + 1;
    v_resp := archive.s3_signed_request('PUT', c_endpoint, c_bucket, c_region, v_key,
                                       'partNumber=' || v_part || '&uploadId=' || archive.s3_url_encode(v_upload_id),
                                       v_ctype, v_part_payload, v_key_id, v_secret);
    if v_resp.status not between 200 and 299 then
      raise exception 'archive.partition: part % of % failed: HTTP % %', v_part, p_child, v_resp.status, left(v_resp.content, 200);
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
    v_resp := archive.s3_signed_request('POST', c_endpoint, c_bucket, c_region, v_key,
                                       'uploadId=' || archive.s3_url_encode(v_upload_id),
                                       'application/xml',
                                       '<CompleteMultipartUpload>' || v_parts_xml || '</CompleteMultipartUpload>',
                                       v_key_id, v_secret);
    if v_resp.status not between 200 and 299 or v_resp.content like '%<Error>%' then
      raise exception 'archive.partition: complete multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
    end if;
    v_etag := null;
    v_etag := (xpath('//*[local-name()=''ETag'']/text()', v_resp.content::xml))[1]::text;
  end if;

  -- the ledger row: written only now, after the store confirmed the object. A crash between the
  -- complete and this insert just re-archives next scan (a PUT to the same key overwrites; the
  -- cleanup-on-entry finds nothing in flight because the upload completed). Keyed by the
  -- partition's own lo (its native-grid [lo, hi) bounds), with child_name populated since this
  -- range is exactly one partition -- the shared archive.ledger table (see "The ledger and the
  -- gate" above) also serves docs/archive-chunked-parquet.md's cross-partition ranges, which have
  -- no single child_name to record.
  insert into archive.ledger (parent_table, lo, hi, child_name, s3_key, etag, rows_archived)
  values (p_parent, v_lo, v_hi, p_child, v_key, v_etag, v_rows)
  on conflict (parent_table, lo)
    do update set hi = excluded.hi, child_name = excluded.child_name,
                  s3_key = excluded.s3_key, etag = excluded.etag,
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

Picking which partition to archive next is its own step, `archive._next_range_partition_aligned`,
factored out so [the chunker](archive-chunked-parquet.md#the-chunker)'s own boundary rule
(`archive._next_range_byte_budget`) can sit alongside it with a matching shape (`(p_parent)` in,
`(lo, hi, child_name)` or no rows out) -- nothing downstream of the range (the read-and-upload, the
ledger write, the retire) depends on which rule picked it.

```sql
-- picks the assistant's next range: the first attached, retention-eligible partition (in lo
-- order) whose ledger row is missing or stale (the live count no longer matches what was
-- recorded). Returns no rows once every eligible partition already has a fresh ledger row --
-- unlike the chunker's boundary rule, this one DOES revisit already-covered ranges, because a
-- partition-aligned range can still be attached (and still mutable) long after it was archived,
-- where a chunked file's range is retention-eligible-or-gone by the time it would be reconsidered.
create or replace function archive._next_range_partition_aligned(p_parent regclass)
returns table(lo text, hi text, child_name name)
language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_ncast text; v_nsp name;
  v_part record; v_rows bigint; v_live bigint;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._next_range_partition_aligned: % is not managed', p_parent; end if;
  v_boundary := pgpm._retain_boundary(cfg);
  v_ncast := pgpm._native_type(cfg.control_kind);
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  for v_part in execute format(
    'select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, v_boundary, v_ncast, v_ncast)
  loop
    select a.rows_archived into v_rows from archive.ledger a
     where a.parent_table = p_parent and a.child_name = v_part.child_name;
    execute format('select count(*) from %I.%I', v_nsp, v_part.child_name) into v_live;
    if v_rows is null or v_rows is distinct from v_live then
      lo := v_part.lo; hi := v_part.hi; child_name := v_part.child_name;
      return next;
      return;
    end if;
  end loop;
end;
$$;
```

```sql
-- the scanner: one standing pg_cron job. Archives every retention-eligible partition of every
-- managed table that needs it, then retires every retention-eligible partition through
-- pgpm.retire() -- the claim-guarded sanctioned drop, which also runs the gate (defense in
-- depth: an assistant bug that reached retire() with a bad archive would still be vetoed). Two
-- passes, not interleaved per partition: archiving drains archive._next_range_partition_aligned
-- until it has nothing left to report, THEN the retire sweep attempts every eligible partition --
-- not just the ones archived just now, so a partition that was already correctly archived but
-- didn't retire last cycle (its own drop deferred by something unrelated) still gets retried here,
-- since the picker above would no longer surface it as needing (re-)archiving.
create or replace procedure archive.scan()
language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_ncast text;
  v_work  record; v_targets jsonb := '[]';
  v_lo text; v_hi text; v_child name; v_iter int;
begin
  -- session-level advisory lock: pg_cron happily overlaps runs of the same job, and a second
  -- scanner mid-upload would double-archive. Session locks survive the COMMITs below.
  if not pg_try_advisory_lock(hashtext('pgpm-archiver')) then return; end if;

  for cfg in select * from pgpm.config where retain is not null loop
    v_iter := 0;
    loop
      select t.lo, t.hi, t.child_name into v_lo, v_hi, v_child
        from archive._next_range_partition_aligned(cfg.parent_table) t;
      exit when v_child is null;
      call archive.partition(cfg.parent_table, v_child);
      commit;
      v_iter := v_iter + 1;
      if v_iter > 1000000 then raise exception 'archive.scan: safety limit'; end if;
    end loop;
  end loop;

  -- materialize the retire-sweep work list (loop-with-COMMIT over a live cursor is legal since
  -- PG11, but a fixed list is simpler to reason about; eligibility is re-checked by retire() anyway)
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
even without it, `retire()`'s `FOR UPDATE SKIP LOCKED` claim means racing assistants could
double-*archive* (wasted work, safe: a PUT to the same key overwrites) but never double-*drop*.

## Install

```sql
select pgpm.hook_register('public.events', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select cron.schedule('pgpm-archiver', '* * * * *', 'call archive.scan()');
select pgpm.schedule();   -- the usual maintenance, now the further-out backstop
```

Unlike the synchronous hook, this needs **no `retain_batch`**: the gate is a count lookup, so even
an unbounded `retain()` pass over an archived backlog is quick. The knob that matters here is
`c_part_bytes`, the horizon-hold bound.

## Failure semantics, verified

The exact SQL above (deployment constants aside) was driven end-to-end against MinIO's SigV4
enforcement:

- **Happy path**: one `archive.scan()` call archived five eligible partitions (a ~26MiB one as a
  3-part multipart upload, four empties via the single-PUT fast path) and retired all five, with the
  gate passing on each retire. A ~110MB partition archived as a 10-part upload, account-checked at
  600,000 contiguous rows.
- **Backstop veto**: an eligible-but-unarchived partition made `retain()` drop nothing, logging
  `archive.file_gate: ... is not yet fully covered by the ledger watermark` -- the
  flat-`retain_backlog`, climbing-`retain_hook_failures` wedge signature.
- **Stale veto and self-repair**: a row backdated into an archived-but-not-yet-retired partition
  made the gate defer with `changed since it was archived (5001 rows live, 5000 archived)`; the next
  `archive.scan()` re-archived (overwriting the same ledger row) and retired it. The archiver owns
  the repair; the gate owns the veto (a raising hook's writes roll back, so it could not durably
  flag anything anyway).
- **Crash cleanup**: a simulated network failure during part 2 killed the scan mid-partition,
  leaving one invisible in-flight upload on the store; the next scan's cleanup-on-entry aborted it
  (confirmed by `ListMultipartUploads`: zero in-flight), then re-archived and retired the partition.
- **The horizon measurement** quoted above: 1 distinct `backend_xmin` (synchronous hook) versus 11
  advancing values (assistant), same payload, same duration.

The same scenario then ran on a live Supabase project against
[Supabase Storage's S3-compatible endpoint](https://supabase.com/docs/guides/storage/s3/authentication):
the full matrix again (happy path with the same deterministic composite ETags, both vetoes,
self-repair, crash cleanup confirmed via `ListMultipartUploads`), plus the horizon measurement at
full scale over a real network: a ~110MB partition archived as a 10-part upload in ~20s with **20
distinct advancing `backend_xmin` values in 27 samples**, versus the synchronous hook's **one pinned
value** for its entire equal-sized run.

The happy path, backstop veto, and stale veto + self-repair above were all re-verified against the
unified `archive.ledger` table and shared `archive.file_gate` (#217, #218): `archive.partition`
resolves its partition's own `[lo, hi)` from `pgpm.part`, the forward-only guard passes silently on
in-order archiving and on re-archiving an already-ledgered (stale) partition, and a second managed
table archived concurrently through [the chunker](archive-chunked-parquet.md) produced no key
collisions or lookup cross-talk between the two tables' rows in the same ledger.

`archive.file_gate` was not a safe drop-in for the retired `archive.gate` on the first attempt,
and the gap was caught live, not reasoned about: `archive.gate` looked up one partition by
`child_name`, independent of anything else in the ledger, so it could never be fooled by another
row. `archive.file_gate`'s fast path instead trusts a single per-parent watermark (`max(hi)` over
*all* ledger rows) to mean "everything below this is archived" -- true only if the ledger's
coverage is gap-free. Archiving a later partition directly via `archive.partition` while an
earlier one stayed unarchived (skipping it, bypassing `archive.scan`'s own in-order sweep) pushed
the watermark past the earlier partition's `hi`; `pgpm.retire()` on that earlier, still-unarchived
partition then **dropped it with no error and no log entry**, because the fast path's watermark
check passed and the defense-in-depth loop found zero ledger rows overlapping its range (a
touching-but-not-overlapping half-open range) to recount. The fix is the forward-only guard in
`archive.partition` above: it refuses to write a ledger row out of order (unless the row is a
legitimate re-archive of an already-ledgered partition), which is exactly the discipline
`archive._chunk_one` already keeps by construction. The same out-of-order sequence was re-run
against the fixed procedure and now fails fast with `archive.partition: ... is out of order`
instead of silently corrupting the ledger's contiguity.

Extracting `archive._next_range_partition_aligned` (#219) restructured `archive.scan()` into two
passes -- archive everything that needs it, then retire everything eligible -- rather than the
original single pass interleaving an archive-or-not decision with a retire attempt for each
partition in turn. Re-verified against the same fixture set: a scan with several eligible
partitions archived and retired all of them exactly as before; a partition archived directly (not
through `archive.scan()`) and left un-retired, simulating a drop deferred on some earlier cycle for
a reason unrelated to archiving, was correctly *not* re-archived (its ledger row was already fresh,
so the picker no longer surfaces it) but still retired by the unchanged retire sweep -- the
guarantee the two-pass split had to preserve, since the picker's job is now only "does this need a
fresh archive," not "does this need a retire attempt." The stale-veto self-repair path and the
forward-only guard were both re-run through the new picker-driven call path with identical results.

## Supabase ceilings, discovered the honest way

Two platform limits surfaced during the live verification; both apply to any of these archival
patterns on Supabase, and both fail loudly:

- **Storage enforces the project's upload file size limit on the S3 protocol too** -- default
  **50MB**, counted against the whole object, so a multipart upload is rejected mid-flight
  (`HTTP 413`, `EntityTooLarge`, on whichever part crosses the line; boundary-verified: a 49MB PUT
  passes, a 51MB PUT fails). The hook raises, the drop defers, nothing is lost -- but archives
  bigger than the limit never succeed until you raise it: Dashboard, **Storage -> Files ->
  Settings**, "Upload file size limit". The assistant's cleanup-on-entry reclaims the rejected
  upload's parts on the next scan.
- **`statement_timeout` is 2 minutes on Supabase** (set in the server's configuration file, so it
  applies over the pooler and direct connections alike). The *synchronous hook* runs a whole
  partition's upload inside one statement, so that is its hard wall-clock ceiling there; a session
  `set statement_timeout = ...` overrides it (configuration-file settings yield to session GUCs),
  e.g. in the pg_cron job command. The assistant barely notices: each of its statements only has to
  fit one part's read or upload inside the window.

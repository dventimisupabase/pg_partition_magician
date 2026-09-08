-- Operator utility, not a pgpm feature: archives every currently write-blocked,
-- not-yet-archive-covered partition of a managed table in exactly one call each -- one file per
-- partition -- bypassing config.archive_byte_budget/archive_batch's chunker entirely.
--
-- WHY THIS EXISTS. pgpm.maintain()'s automatic archiver (pgpm._archive_step) paces itself by
-- estimating how many rows fit config.archive_byte_budget and archiving that many per tick, which
-- is the right default (a large partition archived as one giant operation risks statement_timeout),
-- but sizing that budget to land on "one file per partition" requires measuring the table's real
-- per-row compression ratio and multiplying by its row count -- fiddly, and easy to get wrong in
-- either direction (too small: many small files; too large: back to the statement_timeout risk the
-- chunker exists to avoid). This sidesteps the sizing problem: instead of tuning a byte budget and
-- hoping it lands on the partition's actual size, it calls the table's configured archive_fn
-- directly on each eligible partition's own [lo, hi) -- one partition, one call, one file -- and
-- leaves only statement_timeout to size (see below).
--
-- SAFE TO RE-RUN, AND SAFE ALONGSIDE maintain(). Each partition resumes from wherever
-- pgpm.archive_ledger's coverage of it already left off (the same watermark
-- pgpm._next_archive_chunk itself reads), not always from the partition's own lo -- so if
-- maintain()'s own byte-budget chunker already made partial progress on a partition (normal, not a
-- conflict), this picks up from there instead of re-archiving already-covered rows or hitting
-- archive_ledger's (parent_table, lo) primary key. A partition with nothing left to archive is
-- silently skipped, so calling this repeatedly (e.g. once per session while draining a backlog) is
-- always safe.
--
-- STATEMENT_TIMEOUT IS THE ONE THING LEFT TO SIZE, AND IT'S ON YOU: pgpm never manages
-- statement_timeout itself. Each partition is archived in its own transaction (committed
-- immediately after) specifically so statement_timeout applies per partition, not to the whole
-- loop's sum -- but you still have to set it, from a real measured single-partition archive time,
-- not a guess. A partition too large to finish inside it (or too large for Parquet's own ~1 GiB
-- bytea ceiling -- the whole file is built in memory before upload) will report a partial result
-- via RAISE WARNING and needs another pass, or a smaller-than-"whole-partition" approach instead
-- (config.archive_byte_budget's ordinary chunking).
--
-- Requires pgpm_core (any version that ships pgpm._run_archive_strategy/_is_write_blocked/
-- _archive_fully_covered/_native_type -- these predate this script, not new in any particular
-- release). Not part of pgpm_core/install.sql and never will be without a real feature proposal
-- and its own issue/PR -- this is scratch space for an operator to paste into a session and run,
-- not a shipped, versioned function.
--
-- Usage:
--   \i scripts/archive_partition_whole.sql          -- defines the procedure, once per session
--   set statement_timeout = '...';                  -- sized from a real measured single-partition archive time
--   call pgpm_archive_partition_whole('myschema.mytable'::regclass);

create or replace procedure pgpm_archive_partition_whole(p_parent regclass)
language plpgsql as $$
declare
  cfg pgpm.config;
  r record;
  v_resume_lo text;
  v_ncast text;
  v_result pgpm.archive_result;
  v_ok_count int := 0;
  v_partial_count int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then
    raise exception 'pg_partition_magician: % is not managed', p_parent;
  end if;
  if cfg.archive_fn is null then
    raise notice '% has no archive_fn configured -- nothing to do', p_parent;
    return;
  end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  for r in
    select p.child_name, p.lo, p.hi
      from pgpm.part p
     where p.parent_table = p_parent
       and p.attached
       and pgpm._is_write_blocked(p_parent, p.child_name)
       and not pgpm._archive_fully_covered(p_parent, p.child_name)
     order by p.lo
  loop
    -- resume from wherever this child's ledger coverage already left off, the same watermark
    -- _next_archive_chunk itself reads -- NOT always the child's own lo. maintain()'s own
    -- byte-budget chunker may already have made partial progress on this child (archive_ledger's
    -- primary key is (parent_table, lo), so re-inserting at the child's original lo when a prior
    -- chunk already used it is a hard conflict, not just wasted work).
    execute format('select max(hi::%s)::text from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L',
                   v_ncast, p_parent::text, r.child_name)
      into v_resume_lo;
    v_resume_lo := coalesce(v_resume_lo, r.lo);

    raise notice 'archiving % [%, %) in one call...', r.child_name, v_resume_lo, r.hi;

    v_result := pgpm._run_archive_strategy(p_parent, r.child_name, v_resume_lo, r.hi);

    insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, etag, rows_archived)
    values (p_parent, v_resume_lo, v_result.covered_hi, r.child_name, v_result.s3_key, v_result.etag, v_result.rows_archived);

    if v_result.covered_hi is distinct from r.hi then
      v_partial_count := v_partial_count + 1;
      raise warning '  % only partially covered (requested hi %, got %) -- probably hit statement_timeout or a size limit; needs another pass',
        r.child_name, r.hi, v_result.covered_hi;
    else
      v_ok_count := v_ok_count + 1;
      raise notice '  -> % rows, s3_key=%', v_result.rows_archived, v_result.s3_key;
    end if;

    commit;   -- fresh statement_timeout window for the next partition
  end loop;

  raise notice 'done: % partition(s) fully archived in one file each, % partial (see warnings above)',
    v_ok_count, v_partial_count;
end;
$$;

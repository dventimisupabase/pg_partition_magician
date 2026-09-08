-- Operator utility, not a pgpm feature: archives the OLDEST currently write-blocked,
-- not-yet-archive-covered partition of a managed table in exactly one call -- one file for that
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
-- directly on the partition's own [lo, hi) -- one partition, one call, one file -- and leaves only
-- statement_timeout to size (see below).
--
-- ONE PARTITION PER CALL, DELIBERATELY -- NOT A LOOP OVER THE WHOLE BACKLOG. An earlier version of
-- this script looped over every eligible partition inside one PROCEDURE, committing between each,
-- on the theory that the commit would give each partition its own fresh statement_timeout window.
-- That theory is wrong, verified directly: statement_timeout is enforced cumulatively across a
-- whole top-level CALL, and does NOT reset at an internal COMMIT (proved with a 3-segment,
-- 1.5s-each test procedure under a 2s statement_timeout -- it failed at 2.0s total, not 4.5s, even
-- though each individual segment was well under the timeout on its own). A procedure that loops
-- over N partitions internally is exactly as exposed to statement_timeout as if it had no commits
-- at all; the commits only protect against OTHER things (a long-held lock, an aborted transaction
-- losing more than necessary), not against the timeout accumulating.
--
-- The actual fix: this is a FUNCTION that processes exactly the single oldest eligible partition
-- and returns. To drain a backlog of several partitions, call it repeatedly -- each invocation is a
-- genuinely separate top-level statement, and only a separate top-level statement actually gets a
-- fresh statement_timeout clock. Options for repeating it:
--   - by hand: run the SELECT again, read the returned status, repeat until it says nothing is left.
--   - psql's \watch, which re-issues a query as a new statement each time (waits for one to finish
--     before starting the next, so calls never overlap):
--       select pgpm_archive_next_partition_whole('myschema.mytable'::regclass) \watch 5
--   - a shell loop invoking `psql -c "select ..."` repeatedly -- each psql invocation is its own
--     connection, trivially a fresh statement_timeout each time.
--
-- SAFE TO RE-RUN, AND SAFE ALONGSIDE maintain(). Resumes from wherever pgpm.archive_ledger's
-- coverage of the chosen partition already left off (the same watermark pgpm._next_archive_chunk
-- itself reads), not always from the partition's own lo -- so if maintain()'s own byte-budget
-- chunker already made partial progress on it (normal, not a conflict), this picks up from there
-- instead of re-archiving already-covered rows or hitting archive_ledger's (parent_table, lo)
-- primary key. Returns a plain status message when nothing is eligible, rather than an error, so
-- repeated calls are always safe to make (e.g. from \watch) without checking state first.
--
-- STATEMENT_TIMEOUT IS THE ONE THING LEFT TO SIZE, AND IT'S ON YOU: pgpm never manages
-- statement_timeout itself. Size it from a real measured single-partition archive time, not a
-- guess. A partition too large to finish inside it (or too large for Parquet's own ~1 GiB bytea
-- ceiling -- the whole file is built in memory before upload) reports a partial result and needs
-- another call, or a smaller-than-"whole-partition" approach instead (config.archive_byte_budget's
-- ordinary chunking).
--
-- Requires pgpm_core (any version that ships pgpm._run_archive_strategy/_is_write_blocked/
-- _archive_fully_covered/_native_type -- these predate this script, not new in any particular
-- release). Not part of pgpm_core/install.sql and never will be without a real feature proposal
-- and its own issue/PR -- this is scratch space for an operator to paste into a session and run,
-- not a shipped, versioned function.
--
-- Usage:
--   \i scripts/archive_partition_whole.sql          -- defines the function, once per session
--   set statement_timeout = '...';                  -- sized from a real measured single-partition archive time
--   select pgpm_archive_next_partition_whole('myschema.mytable'::regclass);   -- repeat until it says nothing is left

create or replace function pgpm_archive_next_partition_whole(p_parent regclass)
returns text language plpgsql as $$
declare
  cfg pgpm.config;
  r record;
  v_resume_lo text;
  v_ncast text;
  v_result pgpm.archive_result;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then
    raise exception 'pg_partition_magician: % is not managed', p_parent;
  end if;
  if cfg.archive_fn is null then
    return format('%s has no archive_fn configured -- nothing to do', p_parent);
  end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  select p.child_name, p.lo, p.hi into r
    from pgpm.part p
   where p.parent_table = p_parent
     and p.attached
     and pgpm._is_write_blocked(p_parent, p.child_name)
     and not pgpm._archive_fully_covered(p_parent, p.child_name)
   order by p.lo
   limit 1;

  if not found then
    return format('nothing eligible left to archive for %s', p_parent);
  end if;

  -- resume from wherever this child's ledger coverage already left off, the same watermark
  -- _next_archive_chunk itself reads -- NOT always the child's own lo.
  execute format('select max(hi::%s)::text from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L',
                 v_ncast, p_parent::text, r.child_name)
    into v_resume_lo;
  v_resume_lo := coalesce(v_resume_lo, r.lo);

  v_result := pgpm._run_archive_strategy(p_parent, r.child_name, v_resume_lo, r.hi);

  insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, etag, rows_archived)
  values (p_parent, v_resume_lo, v_result.covered_hi, r.child_name, v_result.s3_key, v_result.etag, v_result.rows_archived);

  if v_result.covered_hi is distinct from r.hi then
    return format('%s: PARTIAL only (requested hi %s, got %s) -- probably hit statement_timeout or a size limit; call again',
      r.child_name, r.hi, v_result.covered_hi);
  end if;

  return format('%s: fully archived in one file (%s rows, s3_key=%s)',
    r.child_name, v_result.rows_archived, coalesce(v_result.s3_key, '<none>'));
end;
$$;

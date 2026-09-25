-- Uninstall pg_partition_magician.
--
-- Removes the MANAGER, not your data.
--
-- Removed:
--   * schema pgpm and everything in it: config, part, log, the registry tables, every
--     function and view, the version record
--   * every pg_cron job pgpm scheduled (matched by the pgpm prefix)
--   * the pgpm_write_block triggers on frozen children (their function lives in pgpm,
--     so the schema drop takes them)
--   * regrain's change capture, which lives in the PARENT's schema and so is out of the
--     schema drop's reach: the per-parent delta table <rel>_pgpm_regrain_delta (with its
--     identity sequence and index), the trigger function <rel>_pgpm_regrain_capture(),
--     and the pgpm_regrain_capture row trigger it drives on a child being regrained
--
-- Left in place, on purpose:
--   * every transmuted table, still a partitioned table under its original name, with
--     all of its partitions (the monolith, the forward grid, any fine children a regrain
--     built, the DEFAULT) and every row. Nothing pgpm made survives in your schema
--     except those relations.
--
-- The one thing this script cannot undo is a conversion abandoned between transmute's
-- phases: its pgpm_monolith_bound CHECK rejects writes outside the recorded range, and
-- the claim that records it (pgpm.transmute_inflight) goes away with the schema. Run
-- `select pgpm.transmute_abort('schema.table')` for any such table BEFORE this script.
--
-- Run with: psql --single-transaction -f pgpm_core/uninstall.sql

-- Unschedule every pgpm cron job (matched by prefix so this stays correct as the
-- cron surface evolves). Best-effort and tolerant of missing pg_cron / privileges.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname) from cron.job where jobname like 'pgpm%';
  end if;
exception
  when undefined_table then null;
  when undefined_function then null;
  when insufficient_privilege then null;
end;
$$;

-- Drop regrain's change capture from every managed parent's schema. The delta table and its
-- trigger function are deliberately persistent per parent (a completed regrain keeps them for the
-- next one), and nothing in them depends on pgpm: the function's body names only the delta table.
-- So the schema drop below leaves all three, and a trigger left on a child mid-regrain keeps
-- appending to a delta table nothing will ever drain. untransmute drops the same two objects the
-- same way; this is the other exit. The names come from pgpm._regrain_capture_names, the single
-- derivation every caller uses, which is why this block has to run BEFORE the schema drop.
do $$
declare r record; v_nsp name; v_delta name; v_fn name;
begin
  for r in select parent_table from pgpm.config loop
    begin
      select nsp, delta, fn into v_nsp, v_delta, v_fn from pgpm._regrain_capture_names(r.parent_table);
      -- A parent dropped without untransmute has no relation to derive the names from (the lookup
      -- returns nulls, and %I refuses a null). Its partitions went with it, and the trigger with
      -- them, so what it may have left is an inert table and function this script cannot name.
      if v_nsp is null then continue; end if;
      -- Existence is checked first only to spare the operator a "does not exist, skipping" notice
      -- for every parent that never regrained. The trigger depends on the function, so the cascade
      -- is what removes it; the delta table depends on nothing.
      if to_regprocedure(format('%I.%I()', v_nsp, v_fn)) is not null then
        execute format('drop function if exists %I.%I() cascade', v_nsp, v_fn);
      end if;
      if to_regclass(format('%I.%I', v_nsp, v_delta)) is not null then
        execute format('drop table if exists %I.%I', v_nsp, v_delta);
      end if;
    exception
      -- Best-effort per parent, like the cron block above: one parent's trouble must not stop the
      -- uninstall or the sweep of the other parents. Only the condition this script can actually
      -- meet is caught, so anything else still surfaces. The capture objects are owned by whoever
      -- ran the regrain (under cron that is the scheduling role), and the role running this script
      -- may not be allowed to drop them; say what is left rather than leaving it silently.
      when insufficient_privilege then
        raise warning 'pg_partition_magician: could not drop the regrain change capture of % (%). Left behind: table %.%, function %.%() and any pgpm_regrain_capture trigger it drives. Drop them as their owner.',
          r.parent_table, sqlerrm, v_nsp, v_delta, v_nsp, v_fn;
    end;
  end loop;
exception
  -- undefined_table: pgpm.config is already gone, so this is a re-run; `drop schema if exists`
  --   below makes a re-run a no-op, and this block has to as well.
  -- undefined_function: an install that predates regrain change capture has no
  --   pgpm._regrain_capture_names, and nothing for this block to remove.
  when undefined_table then null;
  when undefined_function then null;
end;
$$;

drop schema if exists pgpm cascade;

#!/usr/bin/env python3
"""Reintroduce a known defect into pgpm_core/install.sql, so a guard can be shown to catch it.

A guard that passes proves nothing on its own: it might pass because the defect is gone, or because it
never observed anything. This repo has produced the second kind six times, so every guard under
bench/ has a mutation here that puts its defect back, and bench/discriminate.sh asserts the guard FAILS
against it. A guard that stays green on its own mutant is not a guard.

Each mutation states the exact number of sites it expects to change and REFUSES to write a mutant if
the count is off. That matters more than it looks: a mutation whose pattern has drifted out of date
would silently produce a clean copy of install.sql, the guard would pass against it, and
discriminate.sh would report "does not discriminate" for a guard that is in fact fine. Failing loudly
on a stale pattern is the same liveness-witness discipline the guards themselves follow.

Usage: mutate.py <name> <src install.sql> <dst path>
       mutate.py --list [--track=NAME]
"""
import re
import sys

# Each boundary is a BOUNDARY comment block, a `commit;`, and (usually) the set_config that re-applies
# lock_timeout, since `set local` does not survive a COMMIT. Matching the whole block keeps the mutant
# readable rather than leaving orphaned comments explaining a commit that is no longer there.
BOUNDARY_RE = re.compile(
    r"^  -- BOUNDARY \(#(?:279|265)\).*?\n  commit;\n(?:  perform set_config\('lock_timeout'.*?\n)?",
    re.MULTILINE | re.DOTALL,
)

# _create_partition's two boundaries. Removing them collapses the three phases back into one
# transaction, which is the pre-#280 shape exactly.


# Put the inline VALIDATE back where #265 removed it. Anchored on the comment block that replaced it, so
# a stale pattern fails loudly rather than yielding an unmutated copy.
RESTORE_MARKER = "    -- The VALIDATE deliberately does NOT happen here (#265)."
# retire()'s identity check, whole (#407 widened by #428). Shared by three mutations that each take a
# different bite out of it, so the exact text lives in one place: a block this long, duplicated, is a
# block that drifts in one copy and silently stops matching in the other -- and a mutation that
# stops matching is one mutate.py refuses to build, which reads as a broken guard rather than a
# stale pattern until someone goes and looks.
RETIRE_IDENTITY_BLOCK = """  if r.retiring_oid is not null or r.child_oid is not null then
    v_now := to_regclass(format('%I.%I', v_nsp, p_child));
    v_why := concat_ws(' and ',
      case when r.retiring_oid is not null and v_now::oid is distinct from r.retiring_oid
           then format('not the oid %s this retirement dispatched a detach for', r.retiring_oid) end,
      case when r.child_oid is not null and v_now::oid is distinct from r.child_oid
           then format('not the oid %s recorded for this partition when it was created', r.child_oid) end);
    if v_why <> '' then
      if r.retiring_oid is not null then
        perform pgpm._idle_detach_job(pgpm._detach_cmd(p_parent, v_nsp, p_child));
      end if;
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_retain_identity', r.lo, r.hi,
                format('%I.%I is oid %s now, %s; refusing to detach or drop it',
                       v_nsp, p_child, coalesce(v_now::oid::text, 'nothing'), v_why));
      return false;
    end if;
  end if;
"""

# _install_write_block's identity check (#429), and the whole of _remove_write_block, which is
# deliberately NOT anchored. Both live here as constants for the same reason the retire block does.
WRITE_BLOCK_IDENTITY_BLOCK = """  select p.lo, p.hi, p.child_oid into r
    from pgpm.part p where p.parent_table = p_parent and p.child_name = p_child;
  if found and r.child_oid is not null then
    v_now := to_regclass(format('%I.%I', v_nsp, p_child));
    if v_now is not null and v_now::oid <> r.child_oid then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_write_block_identity', r.lo, r.hi,
                format('%I.%I is oid %s now, not the oid %s recorded for this partition when it was created; refusing to write-block it',
                       v_nsp, p_child, v_now::oid::text, r.child_oid));
      return;
    end if;
  end if;

"""

REMOVE_WRITE_BLOCK_FN = """create or replace function pgpm._remove_write_block(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  execute format('drop trigger if exists pgpm_write_block on %I.%I', v_nsp, p_child);
end;
$$;
"""

# from_hypertable_cutover's two lock-then-verify halves (#422), each mutated separately so a guard
# failure names which one went missing.
HT_CUTOVER_SOURCE_VERIFY = """  execute format('lock table %s in access exclusive mode', p_hypertable::text);
  if to_regclass(format('%I.%I', v_nsp, v_rel)) is distinct from p_hypertable then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) resolved % .% at the start, but that name is oid % now -- something renamed or replaced the source while the cutover was preparing; refusing to drop a relation it did not identify. Re-run the cutover once the name is settled.',
      p_hypertable, quote_ident(v_nsp), quote_ident(v_rel),
      coalesce(to_regclass(format('%I.%I', v_nsp, v_rel))::oid::text, 'nothing');
  end if;

"""

HT_CUTOVER_DEST_VERIFY = """  execute format('lock table %s in access exclusive mode', v_dest_oid::text);
  if to_regclass(format('%I.%I', v_nsp, v_dest)) is distinct from v_dest_oid then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) found destination % .% as oid % at the start, but that name is oid % now -- something replaced the copy while the cutover was preparing; refusing to rename an unverified relation into %.',
      p_hypertable, quote_ident(v_nsp), quote_ident(v_dest), v_dest_oid::oid,
      coalesce(to_regclass(format('%I.%I', v_nsp, v_dest))::oid::text, 'nothing'), quote_ident(v_rel);
  end if;
"""
# The cutover's conservation check, whole (#460): the source counted under the lock, compared with the
# destination's carried-in count, and the refusal. Deleting it is the pre-#460 cutover exactly: the
# catch-up runs, nothing compares the two sides, and the DROP goes ahead on a destination that is short.
HT_CUTOVER_CONSERVATION = """  execute format('select count(*) from %I.%I', v_nsp, v_rel) into v_src_n;
  if v_src_n <> v_dest_n then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) refusing to swap: the source holds % rows but the destination would hold % after the % catch-up, a difference of %. %',
      p_hypertable, v_src_n, v_dest_n, case when v_track then 'change-tracking' else 'append-only' end,
      abs(v_src_n - v_dest_n),
      case when v_track
        then 'A write reached the source without firing the change-capture trigger (session_replication_role = replica, or the trigger disabled), so the delta never saw it. Nothing was dropped and the source is whole. Make every writer fire triggers, then re-run from_hypertable_copy with p_track_changes => true.'
        else format('Rows arrived during the online window with a control value at or below the copy watermark (out-of-order appends, a backfill, or an update or delete of a copied row), which the append-only catch-up cannot see. Nothing was dropped and the source is whole. Re-run from_hypertable_copy(%L, %L, p_track_changes => true), which needs a primary key or unique constraint; on a keyless table, pause writes to the source for the copy instead.',
                    p_hypertable::text, p_control)
      end;
  end if;
"""
# The under-lock append-only catch-up's keyed branch, by its condition alone. Six spaces of indentation
# pick the UNDER-LOCK `if` (inside `if v_watermark is not null then`) and not the pre-lock key-column
# build, which sits at four; the count check below refuses to build the mutant if that ever changes.
HT_CATCHUP_KEYED_BRANCH = "      if v_akey is not null then\n"

RESTORE_INLINE = """    if v_readded and not v_is_part then
      begin
        execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
        update pgpm.dropped_fk set validated_at = now() where id = r.id;
      exception when others then null;
      end;
    end if;
    -- The VALIDATE deliberately does NOT happen here (#265)."""

# regrain_step's swap-time residual reconcile (#447): the loop as fixed, the pre-#447 bounded form, and
# the pre-drop check that follows the loop. Constants because two mutations share the loop swap and only
# one of them removes the check; the difference between them is the point.
REGRAIN_SWAP_DRAIN_LOOP = """  loop
    exit when pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_hi, greatest(v_batch, 1000)) = 0;
  end loop;
"""

REGRAIN_SWAP_DRAIN_LOOP_BOUNDED = """  for v_i in 1 .. 100 loop
    exit when pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_hi, greatest(v_batch, 1000)) = 0;
  end loop;
"""

REGRAIN_SWAP_PENDING_CHECK = """  v_delta_n := pgpm._regrain_delta_count(p_parent, v_lo, v_hi);
  if v_delta_n > 0 then
    raise exception 'pg_partition_magician: internal error regraining % -- % captured change(s) in [%, %) are still pending after the swap''s residual reconcile; refusing to drop the source with changes unapplied. The swap rolls back whole: the source stays attached and the next tick reconciles the backlog before swapping.',
      v_child_name, v_delta_n, v_lo, v_hi;
  end if;
"""
# untransmute's lock-and-recheck (#443), matched from its marker comment through the end of its `if`,
# so the mutant reads as the pre-#443 function rather than as a comment describing a lock that is not
# there. Anchored on the marker rather than the code so a rewording of the explanation fails loudly
# here instead of quietly leaving the lock in place.
UNTRANSMUTE_RECHECK_RE = re.compile(
    r"^  -- THE GATE, AGAIN, UNDER THE LOCK \(#443\)\..*?\n  end if;\n\n",
    re.MULTILINE | re.DOTALL,
)

# name -> (guard it must break, why this is the right defect, [(find, replace, expected_count)])
# #344's hoist: the new parent's CREATE TABLE ... PARTITION BY RANGE, identity, owner, grants,
# RLS, policies and comments, moved to run BEFORE either rename so none of it adds to the outage.
TRANSMUTE_CUTOVER_HOIST = """  -- #344: everything below that only touches the NEW parent -- not the original/monolith relation -- runs
  -- BEFORE either rename, under a staging name (v_staging, collision-checked earlier alongside the
  -- orphan-name guard). None of it needs the original table's lock: CREATE TABLE ... LIKE only takes
  -- ACCESS SHARE on p_parent (a rename changes no column/default/constraint, so building it from p_parent
  -- now is byte-for-byte the same as building it from the monolith name later), and everything after that
  -- targets the not-yet-visible staging relation. This is what shrinks the outage: previously all of it
  -- ran AFTER the rename, adding directly to how long the live table was unavailable.

  -- 5. create the partitioned parent under the STAGING name (no PK yet). INCLUDING CONSTRAINTS carries the
  -- user's CHECK constraints onto the parent so every partition (the monolith, the DEFAULT, and future
  -- forward children) enforces them -- without it, only the monolith would. LIKE also copies the transient
  -- pgpm_monolith_bound CHECK (already validated on p_parent by phase 2), which must NOT constrain the
  -- parent (it would reject any row at/after B), so drop it from the parent immediately; the monolith keeps
  -- its own copy for the metadata-only attach below, dropped separately afterward.
  execute format('create table %I.%I (like %s including defaults including generated including storage including constraints) partition by range (%I)',
                 v_nsp, v_staging, p_parent::text, p_control);
  v_parent := format('%I.%I', v_nsp, v_staging)::regclass;
  execute format('alter table %s drop constraint if exists pgpm_monolith_bound', v_parent::text);

  -- 6. re-establish identity on the parent, in the SAME form it had (#308). The kind is not cosmetic:
  -- ALWAYS rejects an insert that supplies the column, BY DEFAULT accepts it, so re-adding an ALWAYS
  -- column BY DEFAULT silently starts accepting writes the operator's schema was written to refuse.
  -- The %s carries a keyword, not user input: v_idkinds comes from pg_attribute.attidentity, which
  -- Postgres constrains to 'a' or 'd'.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('alter table %s alter column %I add generated %s as identity',
                     v_parent::text, v_idcols[v_i],
                     case when v_idkinds[v_i] = 'a' then 'always' else 'by default' end);
    end loop;
  end if;

  -- 7b (moved before the renames -- #344). Replay everything captured at 0b onto the staging parent,
  -- EXCEPT triggers: that is the one step that needs the LIVE name in place, not just the right OID (see
  -- 0b), so it stays below, after both renames.
  execute format('alter table %s owner to %I', v_parent::text, v_owner);

  -- Grants. aclexplode turns relacl into (grantor, grantee, privilege, grantable) rows; a NULL relacl
  -- means the owner's implicit defaults, which the OWNER TO above already restores. grantee = 0 is
  -- PUBLIC, which has no role name.
  for v_g in
    select a.grantee, a.privilege_type, a.is_grantable
      from pg_class c, aclexplode(c.relacl) a where c.oid = p_parent and c.relacl is not null
  loop
    execute format('grant %s on %s to %s%s', v_g.privilege_type, v_parent::text,
                   case when v_g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(v_g.grantee)) end,
                   case when v_g.is_grantable then ' with grant option' else '' end);
  end loop;
  -- COLUMN-level grants, which relacl does not carry at all: they live in pg_attribute.attacl.
  for v_g in
    select att.attname, a.grantee, a.privilege_type, a.is_grantable
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = p_parent and att.attnum > 0 and not att.attisdropped and att.attacl is not null
  loop
    execute format('grant %s (%I) on %s to %s%s', v_g.privilege_type, v_g.attname, v_parent::text,
                   case when v_g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(v_g.grantee)) end,
                   case when v_g.is_grantable then ' with grant option' else '' end);
  end loop;

  -- RLS. FORCE matters as much as ENABLE: without it the table owner bypasses every policy, so an
  -- owner-run query would see all rows and the isolation would be silently absent for exactly the role
  -- most likely to be running reports.
  if v_rls then
    execute format('alter table %s enable row level security', v_parent::text);
  end if;
  if v_rls_force then
    execute format('alter table %s force row level security', v_parent::text);
  end if;
  -- Policies live on the PARENT and only on the parent (measured: a parent policy governs parent-routed
  -- reads into a partition, with no policy on the partition at all). Do not "fix" the apparent gap by
  -- scattering copies onto children; direct partition access needs grants that live on the parent anyway.
  for v_pol in
    select polname, polcmd, polpermissive,
           case when polroles = '{0}'::oid[] then 'public'
                else (select string_agg(quote_ident(rolname), ', ' order by rolname)
                        from pg_roles where oid = any(polroles)) end as roles,
           pg_get_expr(polqual, polrelid)      as qual,
           pg_get_expr(polwithcheck, polrelid) as withcheck
      from pg_policy where polrelid = p_parent
  loop
    execute format('create policy %I on %s as %s for %s to %s%s%s',
      v_pol.polname, v_parent::text,
      case when v_pol.polpermissive then 'permissive' else 'restrictive' end,
      case v_pol.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update'
                        when 'd' then 'delete' else 'all' end,
      v_pol.roles,
      case when v_pol.qual is not null then ' using (' || v_pol.qual || ')' else '' end,
      case when v_pol.withcheck is not null then ' with check (' || v_pol.withcheck || ')' else '' end);
  end loop;

  if v_comment is not null then
    execute format('comment on table %s is %L', v_parent::text, v_comment);
  end if;
  for v_colcom in
    select a.attname, col_description(p_parent, a.attnum) as c
      from pg_attribute a
     where a.attrelid = p_parent and a.attnum > 0 and not a.attisdropped
       and col_description(p_parent, a.attnum) is not null
  loop
    execute format('comment on column %s.%I is %L', v_parent::text, v_colcom.attname, v_colcom.c);
  end loop;

"""

# The "no commits in the sweep" defect, shared BY REFERENCE by the two mutations that model it: one
# for the reader-probe guard (bench/maintain_lock.sh) and one for the trace guard
# (bench/lock_trace.sh). Not copied, on purpose. This pattern's expected count has already drifted
# out of date three times as maintain() gained and lost boundaries; a second copy would have to be
# found and corrected each of those times, and the failure mode if it were missed is the bad one --
# one copy keeps matching while the other silently stops, leaving one guard verified and the other
# only apparently so.
MAINTAIN_NO_COMMITS_EDITS = [
    (BOUNDARY_RE, "", 5),
    ("    call pgpm.maintain(r.parent_table, v_status);\n    commit;\n",
     "    call pgpm.maintain(r.parent_table, v_status);\n", 1),
]

MUTATIONS = {
    "transmute_no_commits": (
        "bench/transmute_lock.sh",
        "Pre-#275 transmute: one transaction, so the ADD's ACCESS EXCLUSIVE is still held during the "
        "O(rows) validation scan.",
        [("  commit;   -- releases the ADD's ACCESS EXCLUSIVE before the scan; "
          "the claim row survives (it is committed)\n", "", 1)],
    ),
    "transmute_claim_advisory_reap": (
        "bench/transmute_claim_squat.sh",
        "Pre-#405 recovery paths: _transmute_reap and transmute_abort decide 'is this conversion still "
        "running?' by trying to TAKE the session advisory lock keyed on the table's oid, instead of "
        "asking whether the claim's recorded owner session is alive. That key carries no ACL and is "
        "computable by anyone, so a role that can merely CONNECT can hold it and make both paths read "
        "'still running' forever -- pinning a write-rejecting pgpm_monolith_bound on the operator's "
        "table with no automated or manual way back.",
        [
            ("    if pgpm._session_alive(r.owner_pid, r.owner_backend_start) then\n"
             "      continue;   -- still running; leave it alone\n"
             "    end if;\n",
             "    if not pg_try_advisory_lock(hashtextextended('pgpm_transmute:' || "
             "r.parent_table::oid::text, 0)) then\n"
             "      continue;   -- still running; leave it alone\n"
             "    end if;\n", 1),
            ("  if pgpm._session_alive(r.owner_pid, r.owner_backend_start) then\n"
             "    raise exception 'pg_partition_magician: cannot abort the transmute of % -- it is "
             "still running in another session', p_parent;\n"
             "  end if;\n",
             "  if not pg_try_advisory_lock(hashtextextended('pgpm_transmute:' || "
             "p_parent::oid::text, 0)) then\n"
             "    raise exception 'pg_partition_magician: cannot abort the transmute of % -- it is "
             "still running in another session', p_parent;\n"
             "  end if;\n", 1),
        ],
    ),
    "maintain_no_commits": (
        "bench/maintain_lock.sh",
        "Pre-#279 maintain_all: one transaction for the WHOLE sweep, so a step's ACCESS EXCLUSIVE for "
        "one table is held across every table after it, including the long regrain copy. Issue #347 "
        "moved obtain into its own procedure/job, so this mutant no longer touches it (maintain() has "
        "no obtain step to strip); the guard now drives a retain-drop on a throwaway table ahead of "
        "the regrain table in the sweep, so this needs ALL THREE of maintain()'s own 5 remaining "
        "internal boundaries (write-block, archive, retain, regrain, and the #265 one before "
        "FK-validate -- that one runs unconditionally every tick even with no incoming FK, so it is "
        "just as much a leak point as the #279 ones) AND maintain_all()'s outer per-parent commit "
        "stripped -- any ONE of those left in place still releases the lock before the next table's "
        "turn, which is exactly what made this mutant look non-discriminating the first three times "
        "the count/pattern here was updated.",
        # EVERY remaining boundary inside maintain(), not just the one before regrain -- same
        # discriminate.sh lesson as before, restated: removing only one still releases the lock a few
        # statements later, at the NEXT boundary or (failing that) the outer loop's own per-parent
        # commit, which the guard rightly does not object to.
        MAINTAIN_NO_COMMITS_EDITS,
    ),
    "maintain_no_commits_trace": (
        "bench/lock_trace.sh",
        "The SAME defect as maintain_no_commits, put back for the eBPF trace guard (#383). The two "
        "guards make the same claim about the same sweep and differ only in how they observe it -- "
        "one infers the lock's lifetime from whether a concurrent reader timed out, the other reads "
        "the acquire/release events off uprobes -- so the defect that must break them is one defect, "
        "and the edits are shared by reference rather than restated. It earns its own entry because "
        "discriminate.sh maps one mutation to one guard, and because a guard without a mutation of "
        "its own is unverified no matter how well its twin is covered.",
        MAINTAIN_NO_COMMITS_EDITS,
    ),
    "restore_fk_inline_validate": (
        "bench/restore_fk_lock.sh",
        "Pre-#265 restore_incoming_fks: the VALIDATE runs inline, in the same transaction as the ADD, so "
        "the ADD's SHARE ROW EXCLUSIVE on the managed parent is held across an O(referencing table) scan.",
        [(RESTORE_MARKER, RESTORE_INLINE, 1)],
    ),
    "retire_inline_detach": (
        "bench/retire_detach_lock.sh",
        "The tempting wrong fix for #268: retire() detaches the referenced partition ITSELF, with a "
        "plain (non-concurrent) DETACH. Functionally identical -- the partition ends up detached and "
        "then dropped, and every behavioural test still passes -- but it holds ACCESS EXCLUSIVE on the "
        "MANAGED PARENT for the whole O(referencing table) scan, so reads of the parent die with "
        "55P03. This is the defect the dispatch-to-cron machinery exists to avoid, and nothing but a "
        "lock probe can tell the two apart.",
        [("      v_reason := pgpm._dispatch_detach(p_parent, v_child);\n",
          "      execute format('alter table %s detach partition %I.%I',\n"
          "                     p_parent::text, v_nsp, p_child);\n"
          "      v_reason := null;\n", 1)],
    ),
    "retire_drop_unanchored_name": (
        "bench/retire_detach_substitution.sh",
        "Pre-#407 retire(): nothing checks that the partition's NAME still resolves to the relation "
        "whose detach was dispatched. Deleting the identity check is the whole defect, because the "
        "rest of the function already acts on p_child by name -- the retirement is carried on, and "
        "completed with a DROP, against whatever answers to that name when the tick comes round. "
        "The detach travels to pg_cron as text and is re-resolved in another session a tick or more "
        "later, with no lock held across the gap, so a relation substituted under the name in "
        "between is detached and then destroyed with no error anywhere. retiring_oid is left in "
        "place deliberately: the defect being modelled is 'the anchor is not consulted', not 'the "
        "anchor does not exist', and a mutant that dropped the column too would fail the test file "
        "on its liveness witnesses and look like a catch for the wrong reason.",
        [(RETIRE_IDENTITY_BLOCK, "", 1)],
    ),
    "retire_drop_child_oid_ignored": (
        "bench/retire_identity_unreferenced.sh",
        "Pre-#428 retire(): the identity check consults retiring_oid ONLY. That anchor is set inside "
        "the `if v_referenced` branch, as retire() dispatches a concurrent detach, so it is null for "
        "every partition nothing points a foreign key at -- which is the ordinary one-step path, and "
        "the one whose bare `drop table schema.child` has nothing else between it and the write "
        "block. Narrows the entry condition back to retiring_oid and removes the child_oid arm of "
        "the reason string, which together is exactly what #428 widened. child_oid itself is left in "
        "place: the defect being modelled is 'the anchor is not consulted on this path', not 'the "
        "anchor does not exist', and a mutant that dropped the column would fail the test file on "
        "its liveness witnesses and look like a catch for the wrong reason. Breaks part A of "
        "tests/103; part B still passes, which is what tells the two mutations apart.",
        [("  if r.retiring_oid is not null or r.child_oid is not null then\n",
          "  if r.retiring_oid is not null then\n", 1),
         ("           then format('not the oid %s this retirement dispatched a detach for', "
          "r.retiring_oid) end,\n"
          "      case when r.child_oid is not null and v_now::oid is distinct from r.child_oid\n"
          "           then format('not the oid %s recorded for this partition when it was created', "
          "r.child_oid) end);\n",
          "           then format('not the oid %s this retirement dispatched a detach for', "
          "r.retiring_oid) end);\n", 1)],
    ),
    "retire_identity_coalesced_anchors": (
        "bench/retire_identity_unreferenced.sh",
        "The plausible-but-wrong #428: fall back from retiring_oid to child_oid rather than checking "
        "both. It closes the gap #428 was filed for, so part A of tests/103 still passes -- which is "
        "the point of having this mutation as well as the other one. What it misses is that "
        "retiring_oid is ITSELF resolved by name, out of pg_inherits at dispatch time, so a "
        "substitution that landed before the dispatch is adopted BY that anchor; coalesce then picks "
        "the adopted one, the comparison passes forever, and the one anchor that still remembers the "
        "original is never consulted. Part B constructs exactly that state and must FAIL here. The "
        "reason string deliberately keeps the child_oid wording so part A's message assertion still "
        "passes: this mutant must be caught by part B alone, not by a message mismatch elsewhere.",
        [(RETIRE_IDENTITY_BLOCK,
          "  if coalesce(r.retiring_oid, r.child_oid) is not null then\n"
          "    v_now := to_regclass(format('%I.%I', v_nsp, p_child));\n"
          "    if v_now::oid is distinct from coalesce(r.retiring_oid, r.child_oid) then\n"
          "      if r.retiring_oid is not null then\n"
          "        perform pgpm._idle_detach_job(pgpm._detach_cmd(p_parent, v_nsp, p_child));\n"
          "      end if;\n"
          "      insert into pgpm.log (parent_table, action, lo, hi, method)\n"
          "        values (p_parent, 'fail_retain_identity', r.lo, r.hi,\n"
          "                format('%I.%I is oid %s now, not the oid %s recorded for this partition "
          "when it was created; refusing to detach or drop it',\n"
          "                       v_nsp, p_child, coalesce(v_now::oid::text, 'nothing'), "
          "coalesce(r.retiring_oid, r.child_oid)));\n"
          "      return false;\n"
          "    end if;\n"
          "  end if;\n", 1)],
    ),
    "archive_step_unanchored_name": (
        "bench/archive_identity_substitution.sh",
        "Pre-#421 _archive_step(): nothing checks that the candidate's NAME still resolves to the "
        "relation pgpm.part recorded for it. Deleting the identity check is the whole defect, "
        "because every step after it already acts on child_name by name -- _next_archive_chunk "
        "sizes the chunk from whatever answers to it, and the ledger row that follows records a "
        "coverage claim for a range those rows never came from. That ledger is retire()'s drop "
        "precondition via _archive_fully_covered, so the bogus claim does not merely put a wrong "
        "object in the bucket: it opens the gate and the next retain() tick DROPs the relation "
        "holding the name. No race is needed -- a rename is enough. child_oid and its select-list "
        "entry are left in place deliberately: the defect being modelled is 'the anchor is not "
        "consulted', not 'the anchor does not exist', and a mutant that dropped the column too "
        "would fail the test file on its liveness witnesses and look like a catch for the wrong "
        "reason.",
        [("    v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));\n"
          "    if r.child_oid is not null and v_now::oid is distinct from r.child_oid then\n"
          "      insert into pgpm.log (parent_table, action, lo, hi, method)\n"
          "        values (p_parent, 'fail_archive_identity', r.lo, r.hi,\n"
          "                format('%I.%I is oid %s now, not the oid %s recorded for this "
          "partition; refusing to archive it',\n"
          "                       v_nsp, r.child_name, coalesce(v_now::oid::text, 'nothing'), "
          "r.child_oid));\n"
          "      continue;\n"
          "    end if;\n\n", "", 1)],
    ),
    "write_block_unanchored_name": (
        "bench/write_block_identity.sh",
        "Pre-#429 _install_write_block(): it resolves p_child by NAME and issues CREATE TRIGGER "
        "against whatever comes back, with no assertion that the relation is the partition "
        "pgpm.part recorded. _enforce_write_blocks calls it for every attached child on every "
        "maintain() tick, so a relation that has taken a partition's name gets a pgpm trigger "
        "rejecting all of its INSERTs, UPDATEs and DELETEs -- DDL on a table pgpm was never handed, "
        "recorded nowhere in its own catalog. It is also what MAKES a substituted name an archive "
        "candidate, since _archive_step gates on _is_write_blocked, so this is upstream of #421's "
        "own refusal rather than redundant with it. Deletes the check only; child_oid stays, "
        "because the defect being modelled is 'the anchor is not consulted', not 'the anchor does "
        "not exist'.",
        [(WRITE_BLOCK_IDENTITY_BLOCK, "", 1)],
    ),
    "write_block_refuses_missing_relation": (
        "bench/write_block_identity.sh",
        "The tempting consistency fix: widen _install_write_block's check to `is distinct from`, so "
        "it also fires when the name resolves to NOTHING, matching retire() and _archive_step. It "
        "is wrong here and the asymmetry is deliberate. Those two fire on null because the next "
        "thing either would do is act on the relation; this one has no wrong relation to act on, "
        "and the null case already has accurate, tested handling -- the ::regclass cast raises, "
        "_enforce_write_blocks' per-child handler catches it, and skip_write_block carries the real "
        "error (issue #360). Making this fire instead reports 'something else holds the name' about "
        "a partition that was simply dropped, AND stops tests/94's poison raising at all, which "
        "quietly retires the loop-isolation coverage that whole file exists for. Part C of "
        "tests/104 is what catches it.",
        [("    if v_now is not null and v_now::oid <> r.child_oid then\n",
          "    if v_now::oid is distinct from r.child_oid then\n", 1),
         ("                       v_nsp, p_child, v_now::oid::text, r.child_oid));\n",
          "                       v_nsp, p_child, coalesce(v_now::oid::text, 'nothing'), "
          "r.child_oid));\n", 1)],
    ),
    "write_block_remove_anchored": (
        "bench/write_block_identity.sh",
        "The symmetrical-looking mistake #429 deliberately did NOT make: anchoring "
        "_remove_write_block as well as the install. It reads as consistency -- pgpm should not "
        "touch a relation it has not identified -- but the two directions are not equivalent. A "
        "pre-#429 pgpm installed this trigger on whatever held the name, so an install upgrading "
        "into the fix can already have one stranded on a relation it never managed, rejecting every "
        "write to it; an anchored removal then refuses to touch the very trigger pgpm itself "
        "wrongly created, and that relation stays read-only permanently with no pgpm-side recovery. "
        "Part B of tests/104 is the only thing that catches this, which is why it exists.",
        [(REMOVE_WRITE_BLOCK_FN,
          "create or replace function pgpm._remove_write_block(p_parent regclass, p_child name)\n"
          "returns void language plpgsql as $$\n"
          "declare v_nsp name; v_oid oid;\n"
          "begin\n"
          "  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = "
          "c.relnamespace where c.oid = p_parent;\n"
          "  select p.child_oid into v_oid from pgpm.part p\n"
          "   where p.parent_table = p_parent and p.child_name = p_child;\n"
          "  if v_oid is not null and to_regclass(format('%I.%I', v_nsp, p_child))::oid is distinct "
          "from v_oid then\n"
          "    return;\n"
          "  end if;\n"
          "  execute format('drop trigger if exists pgpm_write_block on %I.%I', v_nsp, p_child);\n"
          "end;\n"
          "$$;\n", 1)],
    ),
    "hypertable_cutover_unverified_source": (
        "bench/hypertable_cutover_identity.sh",
        "Pre-#422 from_hypertable_cutover(): it locks the SOURCE by the name it resolved at the top "
        "and never re-resolves it. LOCK TABLE freezes whatever a name means at lock time, so locking "
        "by name is only half the standard pattern; a rename landing in the window is acquired "
        "cleanly and the procedure goes on to DROP TABLE a relation it never identified. The window "
        "that matters is the index pre-builds -- deliberately outside the lock so the outage stays "
        "brief, and therefore the longest stretch in it -- which is exactly where part A of "
        "tests/timescale/db/17 lands its substitution. Restores the by-name lock verbatim; the "
        "destination half is left in place so a failure names which half went missing.",
        [(HT_CUTOVER_SOURCE_VERIFY,
          "  execute format('lock table %I.%I in access exclusive mode', v_nsp, v_rel);\n\n", 1)],
    ),
    "hypertable_cutover_unverified_dest": (
        "bench/hypertable_cutover_identity.sh",
        "The other half of the same swap: the destination is existence-checked at the top of the "
        "cutover and then renamed INTO the source's name at the bottom, with nothing verifying it is "
        "still the relation that check found -- and nothing locking it until the first index "
        "pre-build, which the pre-drain's per-batch commits release anyway. An unverified "
        "destination does not merely get dropped, it BECOMES the production table. Deletes only the "
        "destination lock-and-verify, leaving the source half, so part A still passes and only part "
        "B of tests/timescale/db/17 catches this.",
        [(HT_CUTOVER_DEST_VERIFY, "", 1)],
    ),
    "hypertable_catchup_strict_watermark": (
        "bench/hypertable_late_appends.sh",
        "Pre-#460 append-only catch-up on a KEYED table: control strictly greater than the copy watermark, "
        "no key anti-join. A row that lands during the online window with a control value EXACTLY equal to "
        "max(control) in the destination is never copied; the strict bound exists to avoid duplicating the "
        "copied row already at that value, and it throws the late one out with it. Sends the keyed branch "
        "down the keyless path (`if false`), which IS the old catch-up for every table, and leaves the "
        "conservation check in place. So in part A of tests/timescale/db/20 the check refuses the swap "
        "that part expects to SUCCEED (a raw ERROR, and the table is still a hypertable: 241 rows would "
        "have gone forward against 242), and part B's refusal names 241 where 242 is asserted. It fails "
        "on the lost row, never on a missing refusal -- that is the other mutation's job.",
        [(HT_CATCHUP_KEYED_BRANCH,
          "      if false then   -- MUTANT: the pre-#460 strict > on every table, keyed or not\n", 1)],
    ),
    "hypertable_cutover_no_conservation": (
        "bench/hypertable_late_appends.sh",
        "Pre-#460 from_hypertable_cutover(): nothing under the lock compares the source with the "
        "destination. Rows that arrived during the online window BELOW the watermark (out-of-order "
        "appends, backfills, the normal IoT shape) are invisible to the append-only catch-up, and the DROP "
        "TABLE went ahead on a destination that was short, with no error and no log row. Deletes the "
        "count comparison whole and leaves the keyed catch-up in place, so part A of "
        "tests/timescale/db/20 still passes and only parts B and C catch this -- through the refusal "
        "message, which is the only thing that separates a refusal from a cutover that wrongly ran on to "
        "its COMMIT inside throws_like.",
        [(HT_CUTOVER_CONSERVATION, "", 1)],
    ),
    "transmute_no_lock_timeout": (
        "bench/transmute_lock_timeout.sh",
        "Pre-#309 transmute: no lock_timeout on any phase, so it waits indefinitely for the ACCESS "
        "EXCLUSIVE the ADD and the RENAME need -- and a PENDING AccessExclusive blocks every request "
        "queued behind it, turning one slow query into an outage of the whole table. Strips only the "
        "per-phase set_config, leaving p_lock_timeout in the signature: the defect being modelled is "
        "'the timeout is not applied', not 'the parameter does not exist'. A mutant that dropped the "
        "parameter too would fail the guard's CALL with 42883 and look like a catch for the wrong "
        "reason.",
        # Phase 1's line is anchored on the statement that FOLLOWS it: these edits are plain substring
        # replacements, and the bare line is also a substring of the (more-indented) validation check
        # near the top of _transmute, which must survive -- the mutant should still reject a bad
        # p_lock_timeout, it just must not apply a good one.
        [("  perform set_config('lock_timeout', p_lock_timeout, true);\n"
          "  if not exists (select 1 from pg_constraint\n",
          "  if not exists (select 1 from pg_constraint\n", 1),
         ("  perform set_config('lock_timeout', p_lock_timeout, true);   -- `set local` did not survive the COMMIT\n",
          "", 2)],
    ),
    "transmute_cutover_late_build": (
        "bench/transmute_cutover_order.sh",
        "Pre-#344 transmute: the new parent's CREATE TABLE/identity/grants/RLS/policies/comments ran "
        "AFTER the rename, adding directly to the outage even though none of it touches the original "
        "table. Moves the exact hoisted block back to after both renames (right before the trigger "
        "replay, where the equivalent code sat before #344) -- the guard only asserts order against "
        "the FIRST rename, which relocating this one block alone already flips.",
        [(TRANSMUTE_CUTOVER_HOIST, "", 1),
         ("  -- 7b (triggers).", TRANSMUTE_CUTOVER_HOIST + "  -- 7b (triggers).", 1)],
    ),
    "untransmute_no_recheck_under_lock": (
        "bench/untransmute_race.sh",
        "Pre-#443 untransmute: the outside-rows check runs once, under ACCESS SHARE, and the DETACH and "
        "DROP that act on its answer take their ACCESS EXCLUSIVE later. A writer whose forward-partition "
        "insert is uncommitted at the check and committed before that lock is granted has its row "
        "dropped with the parent, and pgpm.log records the untransmute as a success. Removes the "
        "lock-and-recheck block only: the unlocked check and the READ COMMITTED precondition stay, so "
        "the mutant still refuses a row that was already committed (tests/27) and is caught by "
        "nothing but the race.",
        [(UNTRANSMUTE_RECHECK_RE, "", 1)],
    ),
    "regrain_no_delta_analyze": (
        "bench/regrain_perf.sh",
        "Pre-#272 regrain: the trigger-populated delta carries no row estimate, so the planner "
        "misplans a reconcile tick into a seq scan of the whole delta.",
        [("""  if (select coalesce(reltuples, -1) from pg_class where oid = format('%I.%I', v_nsp, v_delta)::regclass) <= 0 then
    perform pgpm._analyze(format('%I.%I', v_nsp, v_delta)::regclass);
  end if;
""", "", 1)],
    ),
    "upgrade_no_column_backfill": (
        "bench/upgrade_in_place.sh",
        "A column present in pgpm.config's `create table` body with no matching `add column if not "
        "exists` line: precisely the mistake install.sql's `add column if not exists` backfill lines "
        "exist to prevent. A FRESH "
        "install is unaffected, because it gets the column from the create table -- so the whole pgTAP "
        "suite stays green, installing fresh one database per file and never upgrading anything. Only a "
        "database that already had pgpm installed comes out of the upgrade missing the column, which is "
        "to say only the operators who are not evaluating it.",
        [("alter table pgpm.config add column if not exists obtain_retry_after timestamptz;\n", "", 1)],
    ),
    "upgrade_child_oid_backfill_noop": (
        "bench/upgrade_in_place.sh",
        "The upgrade recreates pgpm.part.child_oid and populates nothing (issue #421). Deletes only "
        "the backfill UPDATE for ATTACHED partitions, leaving the `add column if not exists` line "
        "and the standalone-regrain-child UPDATE in place -- so the catalog-shape assertion stays "
        "green and the column is there, null, for every partition an existing install already had. "
        "That is the whole defect: a null child_oid reads as unanchored by design, so the archive "
        "step's identity check silently does nothing on precisely the installs that have been "
        "running longest, and no fresh install anywhere in the suite can show it. What must FAIL "
        "here is the child_oid assertion by name; a mutant that dropped the column instead would "
        "fail the catalog hash and look like a catch for the wrong reason.",
        [("update pgpm.part p set child_oid = i.inhrelid\n"
          "  from pg_inherits i join pg_class c on c.oid = i.inhrelid\n"
          " where i.inhparent = p.parent_table and c.relname = p.child_name\n"
          "   and p.attached and p.child_oid is null;\n", "", 1)],
    ),
    "upgrade_degrade_list_drift": (
        "bench/upgrade_in_place.sh",
        "install.sql gains a backfilled column that bench/upgrade_in_place.sh's hardcoded DEGRADE_COLS "
        "does not name. Unlike every other mutation here the defect being modelled lives in the GUARD, "
        "not in the product, and the product is moved because that is the only way to reproduce it: the "
        "guard degrades an install by dropping the columns on that list, so a backfill line for a column "
        "it omits is exercised by nothing, and the guard goes on claiming it covers 'every column "
        "install.sql backfills'. Measured at 958156c the list was 15 entries against 25 backfill lines "
        "(issue #417) -- among the ten missing, the two pgpm.transmute_inflight owner columns that carry "
        "#405's claim that a crashed transmute stays reapable. Nothing reported it, because the only "
        "precondition ran the other way (every LISTED column must exist fresh), which catches a column "
        "the product dropped and never one it gained. What must FAIL here is the new opposite "
        "precondition, by name; a mutant that instead failed the fresh-oracle install would be a "
        "non-zero exit for the wrong reason, so keep the added column nullable and inert.",
        [("alter table pgpm.config add column if not exists archive_batch int default 1;\n",
          "alter table pgpm.config add column if not exists archive_batch int default 1;\n"
          "alter table pgpm.config add column if not exists mutant_unlisted_col int;\n", 1)],
    ),
    "frontier_data_only": (
        "bench/frontier_drought.sh",
        "Pre-#325: uuidv7's (and, since the text_time control kind, text_time's) forward frontier was "
        "plain max(control), decoded, with no clock in it at all. A table whose writes go quiet (a "
        "restored dump, a stale clone, a drought exceeding obtain x step) has that frontier stuck "
        "wherever the data ended while now() keeps moving -- obtain measures itself against its own "
        "past output, finds nothing to do, and every write past the stalled grid is refused, "
        "permanently and silently. Reverts BOTH sites for BOTH kinds: _frontier_native (what "
        "obtain/maintain/regrain_step use every tick) and _transmute's inline duplicate (what sets the "
        "monolith's initial bound, before pgpm.config exists to call the shared function). Fixing only "
        "one site, or only one kind, leaves the other stuck at the data-only value -- confirmed the hard "
        "way while adding text_time: generalizing _frontier_native without also generalizing the inline "
        "duplicate reproduced a 10-month gap with no partition at all, not just a stale frontier.",
        [
            ("  v_decoded := pgpm._decode(cfg.control_kind, v_max,\n"
             "                             cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);\n"
             "  -- #325: uuidv7 (and text_time, the same shape of thing) is a TIME grid fed by DATA. Left as plain\n"
             "  -- max(control), a table whose writes go quiet (a restored dump, a stale clone, a drought) has a\n"
             "  -- frontier stuck wherever the data ended while now() keeps moving -- obtain measures itself against\n"
             "  -- its own past output and finds nothing to do, so the grid stalls exactly where the drought began and\n"
             "  -- every write past it is refused, permanently and silently. greatest() with now() makes both kinds\n"
             "  -- self-healing the same way `time` already is: the grid can never fall further behind the clock than\n"
             "  -- one maintenance tick, drought or not. `id` is untouched below -- it has no clock, so its frontier\n"
             "  -- can only be where the data actually put it.\n"
             "  if cfg.control_kind in ('uuidv7', 'text_time') then\n"
             "    return greatest(v_decoded::timestamptz, now())::text;\n"
             "  end if;\n"
             "  return v_decoded;\n"
             "end;\n",
             "  return pgpm._decode(cfg.control_kind, v_max,\n"
             "                       cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);\n"
             "end;\n", 1),
            ("    if v_max_raw is null then\n"
             "      v_frontier_native := case when p_control_kind = 'id' then p_anchor else now()::text end;\n"
             "    elsif p_control_kind in ('uuidv7', 'text_time') then\n"
             "      -- #325: mirrors _frontier_native's greatest(decoded, now()) here too. pgpm.config does not exist\n"
             "      -- yet (see the note above), so this cannot just call the shared function -- and fixing only that\n"
             "      -- one would leave THIS bound stuck at the data-driven value, opening a gap between the\n"
             "      -- monolith's frozen upper edge and obtain's now()-anchored forward grid on the very next tick.\n"
             "      -- Confirmed the hard way while building text_time support: adding the kind to _frontier_native\n"
             "      -- but not here reproduces exactly that gap (an unfixed [2025-07,2025-10) monolith with the next\n"
             "      -- partition not starting until 2026-08 -- ten covered months missing entirely).\n"
             "      v_frontier_native := greatest(pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch)::timestamptz, now())::text;\n"
             "    else\n"
             "      v_frontier_native := pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);\n"
             "    end if;\n",
             "    v_frontier_native := coalesce(pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch),\n"
             "                                  case when p_control_kind = 'id' then p_anchor else now()::text end);\n",
             1),
        ],
    ),
    "regrain_swap_reconcile_bounded": (
        "bench/regrain_swap_reconcile.sh",
        "Pre-#447 regrain_step swap, exactly: after the DETACH the residual reconcile runs for at most "
        "100 passes of greatest(batch, 1000) keys, and the ATTACH loop, `drop table <source>` and "
        "`truncate <delta>` follow unconditionally, with nothing checking that the loop stopped because "
        "the delta was empty. The gate before the DETACH bounds only what had committed before it ran; a "
        "writer already holding a row in the source keeps the DETACH waiting and everything it commits "
        "during that wait lands in the delta after the gate, so past 100 * batch keys the rest went with "
        "the source, silently. tests/107 fails against this on its identity assertions after a swap that "
        "reported `swapped:10`: 20,001 late rows missing and one deleted row resurrected.",
        [(REGRAIN_SWAP_DRAIN_LOOP, REGRAIN_SWAP_DRAIN_LOOP_BOUNDED, 1),
         (REGRAIN_SWAP_PENDING_CHECK, "", 1)],
    ),
    "regrain_swap_reconcile_bounded_checked": (
        "bench/regrain_swap_reconcile.sh",
        "The 100-pass bound put back with the #447 pre-drop check left in place. Not a shape that ever "
        "shipped; it exists to prove the check is LIVE, which nothing else can: on correct code the loop "
        "runs until the delta is empty, so the check can never fire and a typo in its raise would only "
        "ever be found the day it was needed. Against this mutant tests/107 fails on the swap tick "
        "itself, which raises instead of dropping the source; against the pure pre-#447 mutant above it "
        "fails on the identity assertions after a swap that succeeded. The two failures being different "
        "is what tells the two layers apart.",
        [(REGRAIN_SWAP_DRAIN_LOOP, REGRAIN_SWAP_DRAIN_LOOP_BOUNDED, 1)],
    ),
    "regrain_no_outgoing_fk": (
        "bench/regrain_outgoing_fk_lock.sh",
        "Pre-#348 regrain_step: a fine child is created via `like ... including constraints`, "
        "which never copies a FOREIGN KEY, and nothing else gives it one. So the swap's ATTACH "
        "PARTITION forces PostgreSQL to validate the parent's outgoing FK for that partition from "
        "scratch, an O(rows) scan under whatever lock the swap already holds -- exactly what "
        "reached a production statement_timeout.",
        [("""      -- #348: give the fine child its own already-validated copy of every outgoing FK the parent
      -- has, the same trick the bound CHECK above uses. The child is still empty here (this runs
      -- before the first row is copied in below), so VALIDATE costs nothing -- exactly how an empty
      -- CHECK validates for free. Every row copied in afterward is checked at INSERT time by the
      -- ordinary FK machinery regardless, so this one-time, zero-row validation is the only one this
      -- constraint will ever need; by the swap's ATTACH (below), Postgres adopts it instead of
      -- re-scanning, the same adoption transmute already relies on for the monolith
      -- (install.sql:2841-2851). A NOT VALID outgoing FK on the parent is left alone (the
      -- convalidated filter skips it): that matches today's behavior for it exactly, and transmute
      -- already refuses a NOT VALID outgoing FK at conversion time, so this only matters if one was
      -- added directly to the parent afterward.
      for r in
        select conname, pg_get_constraintdef(oid) as def
          from pg_constraint
         where conrelid = p_parent and contype = 'f' and confrelid <> p_parent and conparentid = 0
           and convalidated
      loop
        execute format('alter table %I.%I add constraint %I %s not valid', v_nsp, v_sub_name, r.conname, r.def);
        execute format('alter table %I.%I validate constraint %I', v_nsp, v_sub_name, r.conname);
      end loop;
""", "", 1)],
    ),
    "obtain_backoff_ignores_headroom": (
        "bench/obtain_backoff_headroom.sh",
        "Pre-fix maintain_obtain: a lock-timeout deferral's obtain_retry_after back-off is honored however "
        "little forward grid is left. Harmless while a DEFAULT partition caught writes past the grid; since "
        "#288 such a write is refused, so a 30 s back-off that outlasts the lookahead turns one lost lock "
        "race into every writer aborting. Removes only the low-headroom bypass and leaves the back-off "
        "itself intact: the defect being modelled is 'the back-off ignores headroom', not 'there is no "
        "back-off'. A mutant that dropped the back-off entirely would fail the guard's ample-headroom "
        "assertion instead and look like a catch for the wrong reason.",
        [("  if not v_try then\n"
          "    begin\n"
          "      -- the first grid boundary past the frontier's own cell, and the top of attached coverage\n",
          "  if false then\n"
          "    begin\n"
          "      -- the first grid boundary past the frontier's own cell, and the top of attached coverage\n", 1)],
    ),
    "obtain_headroom_ignores_monolith": (
        "bench/obtain_backoff_headroom.sh",
        "The first cut of the low-headroom bypass (review on #386): headroom counted as attached partitions "
        "whose lo starts past the frontier's own cell. A monolith widened by transmute's p_bound_headroom "
        "covers several complete steps beyond the frontier, but its lo is far behind, so none of that room "
        "is counted and the back-off is bypassed every tick, retrying obtain's ACCESS EXCLUSIVE under "
        "contention while the table still has grid. Swaps the coverage walk back for that row count and "
        "leaves the bypass itself intact, so the guard's forward-grid assertions still pass and only the "
        "monolith-headroom one can catch it.",
        [("      -- the first grid boundary past the frontier's own cell, and the top of attached coverage\n"
          "      v_cell := pgpm._grid_next(cfg.control_kind, cfg.partition_step,\n"
          "                  pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,\n"
          "                                   pgpm._frontier_native(p_parent)));\n"
          "      execute format('select max(hi::%s)::text from pgpm.part where parent_table = %L::regclass and attached',\n"
          "                     pgpm._native_type(cfg.control_kind), p_parent::text) into v_top;\n"
          "      v_ahead := 0;\n"
          "      while v_top is not null and v_ahead < ceil(cfg.obtain / 2.0)\n"
          "            and not pgpm._native_gt(cfg.control_kind,\n"
          "                  pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_cell), v_top) loop\n"
          "        v_ahead := v_ahead + 1;\n"
          "        v_cell := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_cell);\n"
          "      end loop;\n",
          "      select count(*) into v_ahead\n"
          "        from pgpm.part p\n"
          "       where p.parent_table = p_parent and p.attached\n"
          "         and not pgpm._native_gt(cfg.control_kind,\n"
          "               pgpm._grid_next(cfg.control_kind, cfg.partition_step,\n"
          "                 pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,\n"
          "                                  pgpm._frontier_native(p_parent))),\n"
          "               p.lo);\n", 1)],
    ),
    "obtain_headroom_integer_division": (
        "bench/obtain_backoff_headroom.sh",
        "The low-headroom threshold written with integer division instead of ceil: `cfg.obtain / 2` rather "
        "than `ceil(cfg.obtain / 2.0)`. Invisible at even obtain (ceil(4/2) and 4/2 are both 2), which is why "
        "the guard and tests/100 both carry an obtain 3 case: ceil(3/2) is 2 but 3/2 is 1, so with exactly "
        "one complete step of headroom left the real rule bypasses the back-off and this mutant honors it, "
        "leaving the grid unextended while the frontier keeps advancing. Mutates both sites (the walk's "
        "bound and the decision) so the mutant is self-consistent rather than a half-applied defect.",
        [("ceil(cfg.obtain / 2.0)", "cfg.obtain / 2", 2)],
    ),
    "archive_lz77_hash_scratch": (
        "bench/archive_lz77_memory.sh",
        "Pre-#366 archive._pq_lz77_tokens: LZ77 candidate lookup materializes a per-position temp "
        "table (one row per byte of the ENTIRE input) plus a btree index, instead of the fixed-size "
        "in-place hash table -- O(input size) peak memory, measured at ~40x the input on a "
        "production-shaped fixture, instead of a flat ~64 MiB regardless of size. Also restores "
        "archive._pq_lz_pos_hashes, which the fixed code has no use for and this mutant depends on.",
        [(
            '''-- The LZ77 matcher shared by archive._pq_deflate_encode and archive._pq_deflate_encode_dynamic:
-- single most-recent candidate per 3-byte hash, greedy, window 32768, max match 258. Returns one
-- row per token in stream order: literal (is_match=false, val1=byte 0-255) or match
-- (is_match=true, val1=length, val2=distance).
--
-- #366: candidates come from a fixed-size, in-place hash table (v_table), not a per-position temp
-- table + btree index -- that materialized one row per byte of the ENTIRE input up front, ~40x the
-- input size in peak memory, and degraded further across repeated calls in one backend session
-- (archive_batch > 1). v_table is one int4 slot per possible 3-byte value (2^24 = 16,777,216
-- entries, ~64 MiB, initialized to -1 = "no entry"), holding only the MOST RECENT position seen
-- for that exact 3-byte value -- sized to the full hash domain, not just the 32768-byte window,
-- specifically so there are zero collisions and a lookup is exactly "the largest pos < v_pos with
-- this exact hash", matching what the old exhaustive index computed, byte for byte. A table sized
-- to the window instead (the conventional zlib-style choice) would collide different 3-byte values
-- into the same slot and could silently hide a real, older match behind a newer, unrelated one --
-- still valid DEFLATE, but not byte-identical to today's output.
--
-- The old temp table held an entry for every position 0..n-3 regardless of whether the main loop's
-- greedy skip-ahead (v_pos := v_pos + v_mlen) ever visited it. A hash table that only records
-- positions the loop actually LANDS ON would silently skip the ones a match jumps over, finding
-- fewer candidates than before and producing valid but not byte-identical output. So a match's
-- branch below backfills v_table for every position it consumes (v_pos..v_pos+v_mlen-1), in
-- ascending order so ties resolve to the largest position -- not just advancing past them.
create or replace function archive._pq_lz77_tokens(payload bytea)
returns table(is_match boolean, val1 int4, val2 int4)
language plpgsql as $$
declare
  n int4 := length(payload);
  v_pos int4 := 0;
  v_hash int4; v_candidate int4; v_mlen int4;
  v_table int4[] := array_fill(-1, array[16777216]);
  v_end int4; v_j int4; v_h int4;
begin
  while v_pos < n loop
    v_candidate := null;
    if v_pos <= n - 3 then
      v_hash := (get_byte(payload,v_pos)<<16) | (get_byte(payload,v_pos+1)<<8) | get_byte(payload,v_pos+2);
      v_candidate := v_table[v_hash + 1];
      if v_candidate = -1 or v_pos - v_candidate > 32768 then
        v_candidate := null;
      end if;
    end if;
    if v_candidate is not null then
      v_mlen := archive._pq_lz_match_len(payload, v_pos, v_candidate, least(258, n - v_pos));
    else
      v_mlen := 0;
    end if;

    if v_mlen >= 3 then
      is_match := true; val1 := v_mlen; val2 := v_pos - v_candidate;
      return next;
      -- backfill every position this match consumes, including v_pos's own (never written
      -- before the lookup above) -- see the header note on why skipped positions still need
      -- an entry.
      v_end := least(v_pos + v_mlen - 1, n - 3);
      for v_j in v_pos..v_end loop
        v_h := (get_byte(payload,v_j)<<16) | (get_byte(payload,v_j+1)<<8) | get_byte(payload,v_j+2);
        v_table[v_h + 1] := v_j;
      end loop;
      v_pos := v_pos + v_mlen;
    else
      is_match := false; val1 := get_byte(payload, v_pos); val2 := null;
      return next;
      if v_pos <= n - 3 then
        v_table[v_hash + 1] := v_pos;
      end if;
      v_pos := v_pos + 1;
    end if;
  end loop;

  return;
end;
$$;''',
            '''-- Same matching algorithm as archive._pq_deflate_encode's inline loop (single most-
-- recent candidate per 3-byte hash, precomputed over the whole buffer via
-- archive._pq_lz_pos_hashes, greedy, window 32768, max match 258) -- factored out so
-- archive._pq_deflate_encode_dynamic below can reuse it verbatim. Returns one row per
-- token in stream order: literal (is_match=false, val1=byte 0-255) or match
-- (is_match=true, val1=length, val2=distance).
create or replace function archive._pq_lz_pos_hashes(data bytea) returns table(pos int4, h int4)
language sql immutable as $$
  select i, (get_byte(data,i)<<16) | (get_byte(data,i+1)<<8) | get_byte(data,i+2)
  from generate_series(0, length(data)-3) i;
$$;

create or replace function archive._pq_lz77_tokens(payload bytea)
returns table(is_match boolean, val1 int4, val2 int4)
language plpgsql as $$
declare
  n int4 := length(payload);
  v_pos int4 := 0;
  v_hash int4; v_candidate int4; v_mlen int4;
begin
  drop table if exists archive_lz77_hash_scratch;
  create temp table archive_lz77_hash_scratch as select * from archive._pq_lz_pos_hashes(payload);
  create index on archive_lz77_hash_scratch (h, pos);

  while v_pos < n loop
    v_candidate := null;
    if v_pos <= n - 3 then
      v_hash := (get_byte(payload,v_pos)<<16) | (get_byte(payload,v_pos+1)<<8) | get_byte(payload,v_pos+2);
      select pos into v_candidate from archive_lz77_hash_scratch
       where h = v_hash and pos < v_pos and v_pos - pos <= 32768
       order by pos desc limit 1;
    end if;
    if v_candidate is not null then
      v_mlen := archive._pq_lz_match_len(payload, v_pos, v_candidate, least(258, n - v_pos));
    else
      v_mlen := 0;
    end if;

    if v_mlen >= 3 then
      is_match := true; val1 := v_mlen; val2 := v_pos - v_candidate;
      return next;
      v_pos := v_pos + v_mlen;
    else
      is_match := false; val1 := get_byte(payload, v_pos); val2 := null;
      return next;
      v_pos := v_pos + 1;
    end if;
  end loop;

  drop table archive_lz77_hash_scratch;
  return;
end;
$$;''',
            1,
        )],
    ),
    "archive_encode_array_agg_unnest": (
        "bench/archive_encode_memory.sh",
        "Pre-#368 archive._pq_encode_column_data (text/array_json branch): fetches the whole "
        "column into an array_agg, then re-aggregates it a SECOND time over unnest(...) with "
        "ordinality to derive is_present and the PLAIN-encoded payload -- two full-size copies of "
        "the column alive at overlapping times, instead of one dynamic query that aggregates both "
        "directly from the source relation. Measured at ~6x the raw column size in peak RSS "
        "instead of the fix's ~1.2x-2.8x.",
        [(
            """  elsif p_pgtype in ('text', 'array_json') then
    execute format(
      case when p_pgtype = 'array_json'
        then 'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
                     coalesce(string_agg(archive._pq_plain_text(array_to_json(%I)::text), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
                from %s'
        else 'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
                     coalesce(string_agg(archive._pq_plain_text(%I::text), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
                from %s'
      end,
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, values_payload;
""",
            """  elsif p_pgtype in ('text', 'array_json') then
    declare arr_text text[];
    begin
    execute format(
      case when p_pgtype = 'array_json'
        then 'select array_agg(array_to_json(%I)::text order by %s) from %s'
        else 'select array_agg(%I::text order by %s) from %s'
      end,
      p_col, v_order_q, v_from_q) into arr_text;
    select coalesce(array_agg(v is not null order by ord), '{}'::boolean[]),
           coalesce(string_agg(archive._pq_plain_text(v), ''::bytea order by ord) filter (where v is not null), ''::bytea)
      into is_present, values_payload
      from unnest(arr_text) with ordinality as u(v, ord);
    end;
""",
            1,
        )],
    ),
    "archive_deflate_six_arrays": (
        "bench/archive_deflate_memory.sh",
        "Pre-#370 archive._pq_deflate_encode / _pq_deflate_encode_dynamic: six parallel int4[] "
        "token-bookkeeping arrays in the dynamic encoder (one element per LZ77 token, retained "
        "for the whole call) plus a v_bytes int4[] appended one element per OUTPUT byte in BOTH "
        "encoders, hex-round-tripped at the end -- on poorly-compressible input (near one token "
        "per byte), these can reach Postgres's ~1GB single-allocation ceiling well before the raw "
        "payload does. Measured at ~1.23GB peak RSS on a 15MB near-random fixture instead of the "
        "fix's ~364MB, and this is exactly what production hit archiving a "
        "prompts.\"PromptRunLog\" chunk at archive_byte_budget=256MB.",
        [
            ('-- DEFLATE-encode `payload` as one final, fixed-Huffman block (RFC 1951 3.2.3/3.2.6). Consumes\n-- archive._pq_lz77_tokens\'s token stream -- the same LZ77 matcher the dynamic-Huffman path uses\n-- (see that function for the match-finding strategy, #366) -- rather than keeping a second, inline\n-- copy of the matching loop.\n--\n-- #370: emits fixed-size chunks via `return next` (pre-sized once, filled with set_byte, never\n-- grown -- archive._pq_plain_boolean_array\'s idiom) instead of appending one int4 per OUTPUT byte\n-- to a growing v_bytes int4[] and hex-round-tripping it at the end -- that old shape cost 4 bytes\n-- of int4[] storage per compressed byte, scaling with compressed OUTPUT size independent of #366\'s\n-- token-count fix. archive._pq_deflate_encode (below) does the final string_agg aggregate over\n-- this function\'s chunk stream, the same "return next, real aggregate downstream" shape\n-- archive._pq_lz77_tokens already uses for its own token stream.\ncreate or replace function archive._pq_deflate_encode_chunks(payload bytea)\nreturns table(chunk bytea)\nlanguage plpgsql as $$\ndeclare\n  v_tok record;\n  v_acc int4 := 0; v_acc_n int4 := 0;\n  v_chunk_size constant int4 := 8192;\n  v_chunk_empty constant bytea := decode(repeat(\'00\', v_chunk_size), \'hex\');\n  v_chunk bytea := v_chunk_empty;\n  v_chunk_pos int4 := 0;\n  v_code int4; v_nbits int4; v_rev int4;\n  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;\n  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;\n  v_dist int4; v_len int4; v_sym int4;\nbegin\n  -- block header: BFINAL=1, BTYPE=01 (fixed Huffman) -- raw, LSB-of-value-first (the OPPOSITE\n  -- convention from Huffman codes, which are MSB-of-the-code-first; RFC 1951 3.1.1 splits these\n  -- two conventions and it is easy to invert one for the other by accident).\n  v_acc := v_acc | (3 << v_acc_n); v_acc_n := v_acc_n + 3;\n  while v_acc_n >= 8 loop\n    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n    v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n  end loop;\n\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    if v_tok.is_match then\n      v_len := v_tok.val1;\n      v_dist := v_tok.val2;\n\n      -- length code (RFC 1951 3.2.5), inlined rather than a separate lookup function -- see the\n      -- section header note on OUT-parameter call overhead.\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      -- distance code (RFC 1951 3.2.5), inlined\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      -- length code\'s literal/length Huffman code (RFC 1951 3.2.6), inlined\n      v_sym := v_lcode;\n      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;\n      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;\n      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;\n      else v_code := 192+(v_sym-280); v_nbits := 8;\n      end if;\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop\n        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n      end loop;\n\n      if v_lextra_bits > 0 then\n        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;\n        while v_acc_n >= 8 loop\n          v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n          v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n          if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n        end loop;\n      end if;\n\n      -- distance code: fixed 5-bit Huffman, identity-mapped (RFC 1951 3.2.6)\n      v_rev := archive._pq_bit_reverse(v_dcode, 5);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 5;\n      while v_acc_n >= 8 loop\n        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n      end loop;\n\n      if v_dextra_bits > 0 then\n        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;\n        while v_acc_n >= 8 loop\n          v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n          v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n          if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n        end loop;\n      end if;\n    else\n      v_sym := v_tok.val1;\n      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;\n      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;\n      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;\n      else v_code := 192+(v_sym-280); v_nbits := 8;\n      end if;\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop\n        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n      end loop;\n    end if;\n  end loop;\n\n  -- end-of-block (symbol 256): 7-bit code, value 0\n  v_rev := archive._pq_bit_reverse(0, 7);\n  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 7;\n  while v_acc_n >= 8 loop\n    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n    v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n  end loop;\n  if v_acc_n > 0 then   -- pad final byte\n    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n  end if;\n\n  if v_chunk_pos > 0 then\n    chunk := substr(v_chunk, 1, v_chunk_pos); return next;\n  end if;\n  return;\nend;\n$$;\n\ncreate or replace function archive._pq_deflate_encode(payload bytea) returns bytea\nlanguage sql as $$\n  select coalesce((select string_agg(chunk, \'\'::bytea) from archive._pq_deflate_encode_chunks(payload)), \'\'::bytea);\n$$;\n', "-- DEFLATE-encode `payload` as one final, fixed-Huffman block (RFC 1951 3.2.3/3.2.6). Consumes\n-- archive._pq_lz77_tokens's token stream -- the same LZ77 matcher the dynamic-Huffman path uses\n-- (see that function for the match-finding strategy, #366) -- rather than keeping a second, inline\n-- copy of the matching loop.\ncreate or replace function archive._pq_deflate_encode(payload bytea) returns bytea\nlanguage plpgsql as $$\ndeclare\n  v_tok record;\n  v_acc int4 := 0; v_acc_n int4 := 0; v_bytes int4[] := '{}';\n  v_code int4; v_nbits int4; v_rev int4;\n  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;\n  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;\n  v_dist int4; v_len int4; v_sym int4;\nbegin\n  -- block header: BFINAL=1, BTYPE=01 (fixed Huffman) -- raw, LSB-of-value-first (the OPPOSITE\n  -- convention from Huffman codes, which are MSB-of-the-code-first; RFC 1951 3.1.1 splits these\n  -- two conventions and it is easy to invert one for the other by accident).\n  v_acc := v_acc | (3 << v_acc_n); v_acc_n := v_acc_n + 3;\n  while v_acc_n >= 8 loop\n    v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n  end loop;\n\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    if v_tok.is_match then\n      v_len := v_tok.val1;\n      v_dist := v_tok.val2;\n\n      -- length code (RFC 1951 3.2.5), inlined rather than a separate lookup function -- see the\n      -- section header note on OUT-parameter call overhead.\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      -- distance code (RFC 1951 3.2.5), inlined\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      -- length code's literal/length Huffman code (RFC 1951 3.2.6), inlined\n      v_sym := v_lcode;\n      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;\n      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;\n      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;\n      else v_code := 192+(v_sym-280); v_nbits := 8;\n      end if;\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop\n        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n      end loop;\n\n      if v_lextra_bits > 0 then\n        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;\n        while v_acc_n >= 8 loop\n          v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        end loop;\n      end if;\n\n      -- distance code: fixed 5-bit Huffman, identity-mapped (RFC 1951 3.2.6)\n      v_rev := archive._pq_bit_reverse(v_dcode, 5);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 5;\n      while v_acc_n >= 8 loop\n        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n      end loop;\n\n      if v_dextra_bits > 0 then\n        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;\n        while v_acc_n >= 8 loop\n          v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        end loop;\n      end if;\n    else\n      v_sym := v_tok.val1;\n      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;\n      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;\n      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;\n      else v_code := 192+(v_sym-280); v_nbits := 8;\n      end if;\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop\n        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n      end loop;\n    end if;\n  end loop;\n\n  -- end-of-block (symbol 256): 7-bit code, value 0\n  v_rev := archive._pq_bit_reverse(0, 7);\n  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 7;\n  while v_acc_n >= 8 loop\n    v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n  end loop;\n  if v_acc_n > 0 then v_bytes := array_append(v_bytes, v_acc & 255); end if;   -- pad final byte\n\n  return (select decode(string_agg(lpad(to_hex(x), 2, '0'), '' order by ord), 'hex')\n          from unnest(v_bytes) with ordinality as t(x, ord));\nend;\n$$;\n", 1),
            ('-- The full dynamic-Huffman (BTYPE=10) block encoder: tokenizes via\n-- archive._pq_lz77_tokens (pass 1, tallying the real litlen/distance symbol\n-- frequencies), builds a genuine per-block Huffman code for each alphabet\n-- (archive._pq_huffman_lengths/_canonical_codes -- pass 2), transmits both via the\n-- code-length meta-alphabet (archive._pq_clc_rle, Huffman-coded the same way), then\n-- re-tokenizes and emits the token stream under the new codes (pass 3). Same bit-\n-- accumulator convention as archive._pq_deflate_encode (LSB-first byte packing,\n-- Huffman codes bit-reversed via archive._pq_bit_reverse before packing since they\'re\n-- conventionally written MSB-first, raw fields/extra-bits pushed unreversed).\n--\n-- #370: pass 3 calls archive._pq_lz77_tokens a SECOND time and recomputes each token\'s\n-- length/distance code inline (duplicating pass 1\'s case blocks, the same way\n-- archive._pq_deflate_encode already computes-and-immediately-uses these per token without\n-- storing them) instead of replaying six parallel int4[] arrays (v_litlen_sym/_extra_val/\n-- _extra_bits, v_dist_sym/_extra_val/_extra_bits) that pass 1 used to fill, one element per\n-- LZ77 token. On poorly-compressible input (near one token per byte) those six arrays could\n-- exceed Postgres\'s ~1GB single-value ceiling well before the raw payload did -- exactly\n-- what production hit archiving a prompts."PromptRunLog" chunk. Re-running the matcher is a\n-- bounded, cheap cost since #366 made it O(1) memory and fast; this trades that for removing\n-- an O(token count) memory cost entirely. Also emits fixed-size chunks via `return next`,\n-- same as archive._pq_deflate_encode_chunks above, instead of a growing v_bytes int4[] --\n-- see that function\'s comment for why.\ncreate or replace function archive._pq_deflate_encode_dynamic_chunks(payload bytea)\nreturns table(chunk bytea)\nlanguage plpgsql as $$\ndeclare\n  v_tok record;\n  v_litlen_freq bigint[] := array_fill(0::bigint, array[286]);\n  v_dist_freq bigint[] := array_fill(0::bigint, array[30]);\n\n  v_litlen_lengths int4[]; v_litlen_codes int4[];\n  v_dist_lengths int4[]; v_dist_codes int4[];\n\n  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;\n  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;\n  v_len int4; v_dist int4;\n\n  v_acc int4 := 0; v_acc_n int4 := 0;\n  v_chunk_size constant int4 := 8192;\n  v_chunk_empty constant bytea := decode(repeat(\'00\', v_chunk_size), \'hex\');\n  v_chunk bytea := v_chunk_empty;\n  v_chunk_pos int4 := 0;\n\n  v_combined_lengths int4[];\n  v_litlen_hi int4; v_dist_hi int4;\n  v_hlit int4; v_hdist int4;\n  v_clc_sym int4[] := \'{}\'; v_clc_extra_val int4[] := \'{}\'; v_clc_extra_bits int4[] := \'{}\';\n  v_clc_freq bigint[] := array_fill(0::bigint, array[19]);\n  v_clc_lengths int4[]; v_clc_codes int4[];\n  v_clc_order int4[] := array[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];\n  v_hclen int4;\n  i int4; v_sym int4; v_code int4; v_nbits int4; v_rev int4;\nbegin\n  -- ---- pass 1: tokenize, tally frequencies only (#370: no per-token array storage) ----\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    if v_tok.is_match then\n      v_len := v_tok.val1; v_dist := v_tok.val2;\n\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      v_litlen_freq[v_lcode+1] := v_litlen_freq[v_lcode+1] + 1;\n      v_dist_freq[v_dcode+1] := v_dist_freq[v_dcode+1] + 1;\n    else\n      v_litlen_freq[v_tok.val1+1] := v_litlen_freq[v_tok.val1+1] + 1;\n    end if;\n  end loop;\n\n  v_litlen_freq[257] := v_litlen_freq[257] + 1;   -- symbol 256 (end-of-block), always present\n\n  if (select count(*) from unnest(v_dist_freq) f where f > 0) = 0 then\n    v_dist_freq[1] := 1;   -- RFC 1951 requires >=1 distance code even with zero matches\n  end if;\n\n  -- ---- pass 2: the real per-block Huffman codes ----\n  v_litlen_lengths := archive._pq_huffman_lengths(v_litlen_freq, 15);\n  v_litlen_codes := archive._pq_canonical_codes(v_litlen_lengths);\n  v_dist_lengths := archive._pq_huffman_lengths(v_dist_freq, 15);\n  v_dist_codes := archive._pq_canonical_codes(v_dist_lengths);\n\n  -- meta-alphabet: RLE the combined length sequence, then Huffman-code THAT\n  select max(gs) into v_litlen_hi from generate_series(1,286) gs where v_litlen_lengths[gs] > 0;\n  if v_litlen_hi < 257 then v_litlen_hi := 257; end if;\n  select max(gs) into v_dist_hi from generate_series(1,30) gs where v_dist_lengths[gs] > 0;\n  if v_dist_hi is null then v_dist_hi := 1; end if;\n\n  v_hlit := v_litlen_hi - 257;\n  v_hdist := v_dist_hi - 1;\n\n  v_combined_lengths := v_litlen_lengths[1:v_litlen_hi] || v_dist_lengths[1:v_dist_hi];\n\n  for v_tok in select * from archive._pq_clc_rle(v_combined_lengths) loop\n    v_clc_sym := array_append(v_clc_sym, v_tok.sym);\n    v_clc_extra_val := array_append(v_clc_extra_val, v_tok.extra_val);\n    v_clc_extra_bits := array_append(v_clc_extra_bits, v_tok.extra_bits);\n    v_clc_freq[v_tok.sym+1] := v_clc_freq[v_tok.sym+1] + 1;\n  end loop;\n\n  v_clc_lengths := archive._pq_huffman_lengths(v_clc_freq, 7);\n  v_clc_codes := archive._pq_canonical_codes(v_clc_lengths);\n\n  v_hclen := 19;\n  while v_hclen > 4 and v_clc_lengths[v_clc_order[v_hclen]+1] = 0 loop\n    v_hclen := v_hclen - 1;\n  end loop;\n\n  -- ---- pass 3: re-tokenize, emit bits under the now-known dynamic codes ----\n  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BFINAL=1\n  v_acc := v_acc | (0 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE low bit\n  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE high bit (=10, dynamic)\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n  v_acc := v_acc | (v_hlit << v_acc_n); v_acc_n := v_acc_n + 5;\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n  v_acc := v_acc | (v_hdist << v_acc_n); v_acc_n := v_acc_n + 5;\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n  v_acc := v_acc | ((v_hclen - 4) << v_acc_n); v_acc_n := v_acc_n + 4;\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n  for i in 1..v_hclen loop\n    v_acc := v_acc | (v_clc_lengths[v_clc_order[i]+1] << v_acc_n); v_acc_n := v_acc_n + 3;\n    while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n  end loop;\n\n  for i in 1..array_length(v_clc_sym, 1) loop\n    v_sym := v_clc_sym[i];\n    v_nbits := v_clc_lengths[v_sym+1];\n    v_code := v_clc_codes[v_sym+1];\n    v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n    while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n    if v_clc_extra_bits[i] > 0 then\n      v_acc := v_acc | (v_clc_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_clc_extra_bits[i];\n      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n    end if;\n  end loop;\n\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    if v_tok.is_match then\n      v_len := v_tok.val1; v_dist := v_tok.val2;\n\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      v_sym := v_lcode;\n      v_nbits := v_litlen_lengths[v_sym+1];\n      v_code := v_litlen_codes[v_sym+1];\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n      if v_lextra_bits > 0 then\n        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;\n        while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n      end if;\n\n      v_sym := v_dcode;\n      v_nbits := v_dist_lengths[v_sym+1];\n      v_code := v_dist_codes[v_sym+1];\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n      if v_dextra_bits > 0 then\n        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;\n        while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n      end if;\n    else\n      v_sym := v_tok.val1;\n      v_nbits := v_litlen_lengths[v_sym+1];\n      v_code := v_litlen_codes[v_sym+1];\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n    end if;\n  end loop;\n\n  -- end-of-block symbol (256), dynamic code\n  v_nbits := v_litlen_lengths[257];\n  v_code := v_litlen_codes[257];\n  v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n  if v_acc_n > 0 then\n    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n  end if;\n\n  if v_chunk_pos > 0 then\n    chunk := substr(v_chunk, 1, v_chunk_pos); return next;\n  end if;\n  return;\nend;\n$$;\n\ncreate or replace function archive._pq_deflate_encode_dynamic(payload bytea) returns bytea\nlanguage sql as $$\n  select coalesce((select string_agg(chunk, \'\'::bytea) from archive._pq_deflate_encode_dynamic_chunks(payload)), \'\'::bytea);\n$$;\n', "-- The full dynamic-Huffman (BTYPE=10) block encoder: tokenizes via\n-- archive._pq_lz77_tokens (pass 1, also tallying the real litlen/distance symbol\n-- frequencies), builds a genuine per-block Huffman code for each alphabet\n-- (archive._pq_huffman_lengths/_canonical_codes -- pass 2), transmits both via the\n-- code-length meta-alphabet (archive._pq_clc_rle, Huffman-coded the same way), then\n-- emits the actual token stream under the new codes (pass 3). Same bit-\n-- accumulator convention as archive._pq_deflate_encode (LSB-first byte packing,\n-- Huffman codes bit-reversed via archive._pq_bit_reverse before packing since they're\n-- conventionally written MSB-first, raw fields/extra-bits pushed unreversed).\ncreate or replace function archive._pq_deflate_encode_dynamic(payload bytea) returns bytea\nlanguage plpgsql as $$\ndeclare\n  v_tok record;\n  v_k int4 := 0;\n  v_litlen_sym int4[] := '{}';\n  v_litlen_extra_val int4[] := '{}';\n  v_litlen_extra_bits int4[] := '{}';\n  v_dist_sym int4[] := '{}';\n  v_dist_extra_val int4[] := '{}';\n  v_dist_extra_bits int4[] := '{}';\n\n  v_litlen_freq bigint[] := array_fill(0::bigint, array[286]);\n  v_dist_freq bigint[] := array_fill(0::bigint, array[30]);\n\n  v_litlen_lengths int4[]; v_litlen_codes int4[];\n  v_dist_lengths int4[]; v_dist_codes int4[];\n\n  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;\n  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;\n  v_len int4; v_dist int4;\n\n  v_acc int4 := 0; v_acc_n int4 := 0; v_bytes int4[] := '{}';\n\n  v_combined_lengths int4[];\n  v_litlen_hi int4; v_dist_hi int4;\n  v_hlit int4; v_hdist int4;\n  v_clc_sym int4[] := '{}'; v_clc_extra_val int4[] := '{}'; v_clc_extra_bits int4[] := '{}';\n  v_clc_freq bigint[] := array_fill(0::bigint, array[19]);\n  v_clc_lengths int4[]; v_clc_codes int4[];\n  v_clc_order int4[] := array[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];\n  v_hclen int4;\n  i int4; v_sym int4; v_code int4; v_nbits int4; v_rev int4;\nbegin\n  -- ---- pass 1: tokenize, tally frequencies ----\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    v_k := v_k + 1;\n    if v_tok.is_match then\n      v_len := v_tok.val1; v_dist := v_tok.val2;\n\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      v_litlen_sym[v_k] := v_lcode; v_litlen_extra_val[v_k] := v_lextra_val; v_litlen_extra_bits[v_k] := v_lextra_bits;\n      v_dist_sym[v_k] := v_dcode; v_dist_extra_val[v_k] := v_dextra_val; v_dist_extra_bits[v_k] := v_dextra_bits;\n\n      v_litlen_freq[v_lcode+1] := v_litlen_freq[v_lcode+1] + 1;\n      v_dist_freq[v_dcode+1] := v_dist_freq[v_dcode+1] + 1;\n    else\n      v_litlen_sym[v_k] := v_tok.val1; v_litlen_extra_val[v_k] := 0; v_litlen_extra_bits[v_k] := 0;\n      v_dist_sym[v_k] := null;\n\n      v_litlen_freq[v_tok.val1+1] := v_litlen_freq[v_tok.val1+1] + 1;\n    end if;\n  end loop;\n\n  v_litlen_freq[257] := v_litlen_freq[257] + 1;   -- symbol 256 (end-of-block), always present\n\n  if (select count(*) from unnest(v_dist_freq) f where f > 0) = 0 then\n    v_dist_freq[1] := 1;   -- RFC 1951 requires >=1 distance code even with zero matches\n  end if;\n\n  -- ---- pass 2: the real per-block Huffman codes ----\n  v_litlen_lengths := archive._pq_huffman_lengths(v_litlen_freq, 15);\n  v_litlen_codes := archive._pq_canonical_codes(v_litlen_lengths);\n  v_dist_lengths := archive._pq_huffman_lengths(v_dist_freq, 15);\n  v_dist_codes := archive._pq_canonical_codes(v_dist_lengths);\n\n  -- meta-alphabet: RLE the combined length sequence, then Huffman-code THAT\n  select max(gs) into v_litlen_hi from generate_series(1,286) gs where v_litlen_lengths[gs] > 0;\n  if v_litlen_hi < 257 then v_litlen_hi := 257; end if;\n  select max(gs) into v_dist_hi from generate_series(1,30) gs where v_dist_lengths[gs] > 0;\n  if v_dist_hi is null then v_dist_hi := 1; end if;\n\n  v_hlit := v_litlen_hi - 257;\n  v_hdist := v_dist_hi - 1;\n\n  v_combined_lengths := v_litlen_lengths[1:v_litlen_hi] || v_dist_lengths[1:v_dist_hi];\n\n  for v_tok in select * from archive._pq_clc_rle(v_combined_lengths) loop\n    v_clc_sym := array_append(v_clc_sym, v_tok.sym);\n    v_clc_extra_val := array_append(v_clc_extra_val, v_tok.extra_val);\n    v_clc_extra_bits := array_append(v_clc_extra_bits, v_tok.extra_bits);\n    v_clc_freq[v_tok.sym+1] := v_clc_freq[v_tok.sym+1] + 1;\n  end loop;\n\n  v_clc_lengths := archive._pq_huffman_lengths(v_clc_freq, 7);\n  v_clc_codes := archive._pq_canonical_codes(v_clc_lengths);\n\n  v_hclen := 19;\n  while v_hclen > 4 and v_clc_lengths[v_clc_order[v_hclen]+1] = 0 loop\n    v_hclen := v_hclen - 1;\n  end loop;\n\n  -- ---- pass 3: emit bits ----\n  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BFINAL=1\n  v_acc := v_acc | (0 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE low bit\n  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE high bit (=10, dynamic)\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n  v_acc := v_acc | (v_hlit << v_acc_n); v_acc_n := v_acc_n + 5;\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n  v_acc := v_acc | (v_hdist << v_acc_n); v_acc_n := v_acc_n + 5;\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n  v_acc := v_acc | ((v_hclen - 4) << v_acc_n); v_acc_n := v_acc_n + 4;\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n  for i in 1..v_hclen loop\n    v_acc := v_acc | (v_clc_lengths[v_clc_order[i]+1] << v_acc_n); v_acc_n := v_acc_n + 3;\n    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n  end loop;\n\n  for i in 1..array_length(v_clc_sym, 1) loop\n    v_sym := v_clc_sym[i];\n    v_nbits := v_clc_lengths[v_sym+1];\n    v_code := v_clc_codes[v_sym+1];\n    v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n    if v_clc_extra_bits[i] > 0 then\n      v_acc := v_acc | (v_clc_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_clc_extra_bits[i];\n      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n    end if;\n  end loop;\n\n  for i in 1..v_k loop\n    v_sym := v_litlen_sym[i];\n    v_nbits := v_litlen_lengths[v_sym+1];\n    v_code := v_litlen_codes[v_sym+1];\n    v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n    if v_litlen_extra_bits[i] > 0 then\n      v_acc := v_acc | (v_litlen_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_litlen_extra_bits[i];\n      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n    end if;\n\n    if v_dist_sym[i] is not null then\n      v_sym := v_dist_sym[i];\n      v_nbits := v_dist_lengths[v_sym+1];\n      v_code := v_dist_codes[v_sym+1];\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n      if v_dist_extra_bits[i] > 0 then\n        v_acc := v_acc | (v_dist_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_dist_extra_bits[i];\n        while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n      end if;\n    end if;\n  end loop;\n\n  -- end-of-block symbol (256), dynamic code\n  v_nbits := v_litlen_lengths[257];\n  v_code := v_litlen_codes[257];\n  v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n  if v_acc_n > 0 then v_bytes := array_append(v_bytes, v_acc & 255); end if;\n\n  return (select decode(string_agg(lpad(to_hex(x), 2, '0'), '' order by ord), 'hex')\n          from unnest(v_bytes) with ordinality as t(x, ord));\nend;\n$$;\n", 1),
        ],
    ),
    "archive_from_item_raw_splice": (
        "bench/archive_encode_boundary.sh",
        "Pre-#408 FROM item: archive._pq_from_item pastes p_schema/p_table in with %s instead of "
        "%I, which is exactly what handing archive._pq_encode_column_data a `p_from_sql text` and "
        "splicing it bare used to do. The boundary test's p_table payload is shaped to survive "
        "this -- it closes the SELECT, drops a victim table, and supplies a third statement "
        "returning the (boolean[], bytea) pair the EXECUTE ... INTO needs -- so the injected DROP "
        "COMMITS rather than rolling back with a failing statement.",
        [(
            """    when p_control is null then format('%I.%I', p_schema, p_table)""",
            """    when p_control is null then format('%s.%s', p_schema, p_table)""",
            1,
        )],
    ),
    "archive_order_by_raw_splice": (
        "bench/archive_encode_boundary.sh",
        "Pre-#408 ORDER BY: archive._pq_encode_column_data joins p_order_by's elements without "
        "quote_ident, which is what passing the whole ORDER BY list in as `p_order_by text` and "
        "splicing it bare used to amount to. An element carrying a statement terminator then "
        "reaches the statement as SQL rather than as one (absurd) column name.",
        [(
            """  select string_agg(quote_ident(c), ', ' order by ord) into v_order_q
    from unnest(p_order_by) with ordinality as t(c, ord);""",
            """  select string_agg(c, ', ' order by ord) into v_order_q
    from unnest(p_order_by) with ordinality as t(c, ord);""",
            1,
        )],
    ),
}

# name -> source install.sql (repo-relative), for mutations that don't touch pgpm_core/install.sql.
# bench/discriminate.sh reads this via --list to know which base file AND which container a
# mutation's guard needs; anything not listed here defaults to the core install + core container.
MUTATION_SRC = {
    "hypertable_cutover_unverified_source": "pgpm_hypertable/install.sql",
    "hypertable_cutover_unverified_dest": "pgpm_hypertable/install.sql",
    "hypertable_catchup_strict_watermark": "pgpm_hypertable/install.sql",
    "hypertable_cutover_no_conservation": "pgpm_hypertable/install.sql",
    "archive_lz77_hash_scratch": "pgpm_archive/install.sql",
    "archive_encode_array_agg_unnest": "pgpm_archive/install.sql",
    "archive_deflate_six_arrays": "pgpm_archive/install.sql",
    "archive_from_item_raw_splice": "pgpm_archive/install.sql",
    "archive_order_by_raw_splice": "pgpm_archive/install.sql",
}

# name -> the CI track whose job runs it; anything not listed here belongs to the default `perf`
# track, which is what `./test.sh discriminate` runs.
#
# This exists so one mutation framework can serve a track that not every machine can run.
# bench/lock_trace.sh needs eBPF, which needs a privileged container and host kernel headers --
# available on Linux and on GitHub's runners, and structurally impossible on Docker Desktop for Mac,
# whose linuxkit VM publishes no headers for its own kernel. Issue #383 is explicit that local
# development must not start requiring that on any platform. Listing the mutation here keeps it out
# of the default listing, so `./test.sh discriminate` stays runnable on a laptop, while
# `--track=locktrace` still runs it under the same mutate/assert-it-FAILS machinery as every other
# guard. A track of its own, not an exemption: the mutation is still mandatory, still built from the
# same patterns, and still has to break its guard.
MUTATION_TRACK = {
    "maintain_no_commits_trace": "locktrace",
    # The hypertable cutover's guard needs a real TimescaleDB, which is a separate image and a
    # separate track for the same reason locktrace is: `./test.sh discriminate` must stay runnable
    # without it. run_timescale invokes these while its own container is already up.
    "hypertable_cutover_unverified_source": "timescale",
    "hypertable_cutover_unverified_dest": "timescale",
    "hypertable_catchup_strict_watermark": "timescale",
    "hypertable_cutover_no_conservation": "timescale",
}


def main() -> int:
    if len(sys.argv) in (2, 3) and sys.argv[1] == "--list":
        track = "perf"
        if len(sys.argv) == 3:
            if not sys.argv[2].startswith("--track="):
                print(__doc__, file=sys.stderr)
                return 2
            track = sys.argv[2].split("=", 1)[1]

        # An unknown track must be an ERROR, never an empty listing. A silent empty listing is the
        # worst possible output from this file: bench/discriminate.sh would run zero mutations and
        # report "PASS (0 guard(s) verified against their defects)", a green check that verified
        # nothing -- in the very machinery whose entire purpose is to prove that a green check means
        # something. Same discipline as a stale pattern below: fail loudly rather than hand back a
        # result that looks like success.
        known = {"perf"} | set(MUTATION_TRACK.values())
        if track not in known:
            print(
                f"mutate.py: unknown track {track!r}; known tracks are "
                f"{', '.join(sorted(known))}.\n"
                f"  Refusing to print an empty listing, which would make discriminate.sh report a\n"
                f"  PASS having verified nothing at all.",
                file=sys.stderr,
            )
            return 2

        listed = 0
        for name, (guard, why, _) in MUTATIONS.items():
            if MUTATION_TRACK.get(name, "perf") != track:
                continue
            listed += 1
            src = MUTATION_SRC.get(name, "pgpm_core/install.sql")
            print(f"{name}\t{guard}\t{why}\t{src}")
        if listed == 0:
            # Reachable only if a track is registered in MUTATION_TRACK and then has its last
            # mutation removed. That leaves a CI job running happily against nothing, so it is a
            # failure here rather than a discovery months later.
            print(
                f"mutate.py: track {track!r} selected no mutations. A registered track with no\n"
                f"  mutation left in it is a guard that nothing verifies -- add one back, or remove\n"
                f"  the track and the job that runs it.",
                file=sys.stderr,
            )
            return 1
        return 0
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2

    name, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    if name not in MUTATIONS:
        print(f"mutate.py: unknown mutation {name!r}; try --list", file=sys.stderr)
        return 2

    _, _, edits = MUTATIONS[name]
    with open(src) as fh:
        text = fh.read()

    for find, replace, expected in edits:
        is_re = hasattr(find, "sub")
        got = len(find.findall(text)) if is_re else text.count(find)
        if got != expected:
            print(
                f"mutate.py: {name}: pattern matched {got} time(s), expected {expected}.\n"
                f"  The code has moved and this mutation is stale. Fix the pattern -- do NOT let it\n"
                f"  write an unmutated copy, which would make its guard look broken when it is fine.\n"
                f"  Pattern begins: "
                f"{(find.pattern if is_re else find).strip().splitlines()[0][:90]!r}",
                file=sys.stderr,
            )
            return 1
        text = find.sub(replace, text) if is_re else text.replace(find, replace)

    with open(dst, "w") as fh:
        fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

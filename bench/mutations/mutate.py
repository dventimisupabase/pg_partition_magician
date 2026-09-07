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
       mutate.py --list
"""
import re
import sys

# Each boundary is a BOUNDARY comment block, a `commit;`, and (usually) the set_config that re-applies
# lock_timeout, since `set local` does not survive a COMMIT. Matching the whole block keeps the mutant
# readable rather than leaving orphaned comments explaining a commit that is no longer there.
BOUNDARY_RE = re.compile(
    r"^  -- BOUNDARY \(#279\).*?\n  commit;\n(?:  perform set_config\('lock_timeout'.*?\n)?",
    re.MULTILINE | re.DOTALL,
)

# _create_partition's two boundaries. Removing them collapses the three phases back into one
# transaction, which is the pre-#280 shape exactly.


# Put the inline VALIDATE back where #265 removed it. Anchored on the comment block that replaced it, so
# a stale pattern fails loudly rather than yielding an unmutated copy.
RESTORE_MARKER = "    -- The VALIDATE deliberately does NOT happen here (#265)."
RESTORE_INLINE = """    if v_readded and not v_is_part then
      begin
        execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
        update pgpm.dropped_fk set validated_at = now() where id = r.id;
      exception when others then null;
      end;
    end if;
    -- The VALIDATE deliberately does NOT happen here (#265)."""

# name -> (guard it must break, why this is the right defect, [(find, replace, expected_count)])
MUTATIONS = {
    "transmute_no_commits": (
        "bench/transmute_lock.sh",
        "Pre-#275 transmute: one transaction, so the ADD's ACCESS EXCLUSIVE is still held during the "
        "O(rows) validation scan.",
        [("  commit;   -- releases the ADD's ACCESS EXCLUSIVE before the scan; "
          "the advisory lock survives\n", "", 1)],
    ),
    "maintain_no_commits": (
        "bench/maintain_lock.sh",
        "Pre-#279 maintain: one transaction per tick, so obtain's ACCESS EXCLUSIVE on the parent is "
        "held across the drain. Also strips the #280 boundaries inside obtain, because after #280 "
        "obtain commits on its own and maintain's boundaries alone no longer decide this.",
        # EVERY boundary inside maintain(), not just the one before the drain. Removing only the first
        # leaves obtain's lock released at the SECOND boundary a few statements later, which is a short
        # window the guard rightly does not object to -- the guard then passed against this mutant and
        # discriminate.sh reported it as non-discriminating. The defect being modelled is "the tick is
        # one transaction", so the mutant has to actually make it one.
        [(BOUNDARY_RE, "", 5)],
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
        [("      v_reason := pgpm._dispatch_detach(p_parent, p_child);\n",
          "      execute format('alter table %s detach partition %I.%I',\n"
          "                     p_parent::text, v_nsp, p_child);\n"
          "      v_reason := null;\n", 1)],
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
        "exists` line: precisely the mistake install.sql's 14 backfill lines exist to prevent. A FRESH "
        "install is unaffected, because it gets the column from the create table -- so the whole pgTAP "
        "suite stays green, installing fresh one database per file and never upgrading anything. Only a "
        "database that already had pgpm installed comes out of the upgrade missing the column, which is "
        "to say only the operators who are not evaluating it.",
        [("alter table pgpm.config add column if not exists obtain_retry_after timestamptz;\n", "", 1)],
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
}


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--list":
        for name, (guard, why, _) in MUTATIONS.items():
            print(f"{name}\t{guard}\t{why}")
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

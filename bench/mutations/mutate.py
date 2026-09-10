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
      p_col, p_order_by, p_col, p_order_by, p_col, p_from_sql)
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
      p_col, p_order_by, p_from_sql) into arr_text;
    select coalesce(array_agg(v is not null order by ord), '{}'::boolean[]),
           coalesce(string_agg(archive._pq_plain_text(v), ''::bytea order by ord) filter (where v is not null), ''::bytea)
      into is_present, values_payload
      from unnest(arr_text) with ordinality as u(v, ord);
    end;
""",
            1,
        )],
    ),
}

# name -> source install.sql (repo-relative), for mutations that don't touch pgpm_core/install.sql.
# bench/discriminate.sh reads this via --list to know which base file AND which container a
# mutation's guard needs; anything not listed here defaults to the core install + core container.
MUTATION_SRC = {
    "archive_lz77_hash_scratch": "pgpm_archive/install.sql",
    "archive_encode_array_agg_unnest": "pgpm_archive/install.sql",
}


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--list":
        for name, (guard, why, _) in MUTATIONS.items():
            src = MUTATION_SRC.get(name, "pgpm_core/install.sql")
            print(f"{name}\t{guard}\t{why}\t{src}")
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

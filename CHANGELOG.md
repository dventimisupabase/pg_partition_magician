# Changelog

## [Unreleased]

- **Retention dropping the coarse source of an in-flight regrain reclaims that regrain instead of
  orphaning it** (#519). With auto-regrain, an `archive_fn` and `retain` all on, the archive step and the
  regrain worked the same wholly-aged coarse child at once, and when archiving covered it first `retire()`
  dropped it and left everything the regrain had built behind: not-attached `pgpm.part` rows that no
  partition covered, standalone fine copies still holding the rows retention had just dropped,
  `config.regrain_cursor` pointing into a range that no longer existed, and no tick able to reclaim any of
  it (auto-regrain answered `none`, the capture sweep only tears down what the cursor does not cover). No
  rows were lost, the source had been archived, but the documented pipeline was not kept and the
  leftovers held disk and misreported `status().inflight_partitions` for good. `retire()` now calls a new
  `pgpm._regrain_reclaim` in the drop's own subtransaction, ahead of the `DROP`: it discards the copies
  inside the dropped range, the captured changes when this child carries the capture trigger, and the
  cursor when it is unambiguously this child's, and logs one `regrain_cancel` row whose `method` names
  `retire`. Scoped to the source, not the parent, so a regrain in flight on another child is untouched
  and a refusal reclaims nothing; reclaimed rather than refused because `set_regrain(parent, null)`
  leaves cursor and capture in place, so a `retire` that waited for the regrain would wait forever. The
  `retain`, `retire`, `regrain_step`, `regrain_cancel` and `pgpm.log` entries in `docs/reference.md` and
  the retention bullet in `docs/guide.md` describe it. `tests/129_retire_regrain_source_test.sql`
  reproduces the scheduled path, the hand-driven path with a captured change pending, and the neighbour
  case, asserting by identity which copies existed at the drop and that none survives it;
  `bench/retire_regrain_source.sh` drives it against the `retire_drops_regrain_source` and
  `retire_cancels_whole_parent_regrain` mutations, which `./test.sh discriminate` requires it to fail.
- **A substituted partition name no longer discards the real partition's archive coverage** (#518).
  `_enforce_write_blocks` decided "coverage found without its block" by name,
  `_is_write_blocked(child_name)`, at the top of its loop body, before the identity check
  `_install_write_block` makes further down. A relation holding a partition's name has no trigger, so
  the tick deleted the `pgpm.archive_ledger` rows describing the real partition (still attached, still
  write-blocked, merely renamed aside) and logged `archive_coverage_reset` in the same tick that logged
  `fail_write_block_identity` for the same child; once the name was sorted out, archiving started over
  from `lo`. No row was lost, but ledger rows naming archived objects were destroyed on the strength of a
  relation that was not the partition, against the guide's promise that every step acting on a name
  checks it first. The loop now resolves each child's name against `pgpm.part.child_oid` before anything
  it decides by that name, with the same predicate as the install (a null anchor compares as nothing; a
  name resolving to nothing stays on the `skip_write_block` path), and a substituted name suppresses the
  discard: the identity refusal is the whole of what the tick does for that child.
  `tests/129_coverage_reset_identity_test.sql` reproduces the substitution, asserts by identity that the
  ledger row survives and that the first tick after the name is restored archives from the watermark
  rather than from `lo`, and pins the positive side (trigger really gone, identity intact: still
  discarded) and the unanchored side (a null `child_oid` is not a mismatch);
  `bench/coverage_reset_identity.sh` drives it against the `coverage_reset_by_name` and
  `coverage_reset_unanchored_is_mismatch` mutations, which `./test.sh discriminate` requires it to fail.

- **The guide's database.dev snippet names the version this tree installs, and the reference names only
  log actions pgpm writes** (#521). `docs/guide.md`'s `create extension ... version '0.4.0'` sat two
  releases behind `extension.control`'s `0.6.0`, because RELEASING.md's list of files to bump at release
  time did not include it, so an operator following the guide installed a release this file lists fixes
  for. And `docs/reference.md`'s Foreign keys section promised `from_hypertable_adopt_fk` beside
  `from_hypertable_carry_fk` after the cutover's adopt step, its only writer, was removed (transmute's
  parent-level re-add logs nothing), so an alert on that action, part of the log-action contract
  RELEASING.md spells out, could never fire. The pin is `0.6.0`, the sentence names
  `from_hypertable_carry_fk` alone, and RELEASING.md and ONBOARDING.md list the pin as the third file a
  release bumps. `scripts/check_living_docs.sh` gained two checks that keep both true: every
  `version 'X.Y.Z'` literal in a living document must equal `extension.control`'s `default_version`, and
  every `pgpm.log.action` the operator docs name (the reference's vocabulary table and every "logged
  `x`" sentence) must be a literal some `install.sql` writes, failing loudly when the vocabulary table
  cannot be found rather than passing on nothing. Its new `--selftest`, which the `Living docs` lint job
  now runs first, re-breaks a scratch copy four ways (the stale pin, the phantom action in prose and as a
  table row, the vocabulary heading moved) and requires each check to fail against its re-break.

- **Turning auto-regrain off mid-flight abandons the run it started, instead of stranding it** (#516).
  `set_regrain(parent, null)` wrote `regrain_to` and nothing else. `maintain` dispatches `regrain_step` only
  while `regrain_to` is set, so the run in flight was never driven again, and the capture janitor keeps
  capture on the child whose range covers `config.regrain_cursor`, which nothing cleared, so it was never
  swept either: the capture trigger kept taxing every write into the source and filling a delta nobody
  drained, the not-yet-attached copies stayed on disk, and `TRUNCATE` of the parent stayed refused as "a
  regrain is in flight", indefinitely, until the operator found `regrain_cancel`. The reference promised
  `maintain` would sweep it and the runbook promised the run would complete; the code did neither. Now a
  `set_regrain(parent, null)` that actually turns auto-regrain off, with a regrain in flight, abandons that
  run through `regrain_cancel` (capture and the `TRUNCATE` guard off, delta cleared, copies dropped, cursor
  null, one `regrain_cancel` row); the source still holds every row, so only the copy work is lost. A call
  that finds auto-regrain already off changes nothing, so it never cancels an operator-driven regrain. The
  reference, the runbook's "Disk is filling during a regrain" and the guide now say so.
  `tests/129_set_regrain_off_midflight_test.sql` witnesses the run in flight (capture, cursor, a captured
  update, the refused `TRUNCATE`) before the call and asserts by identity what is left after it and after
  three more ticks; `bench/set_regrain_off_midflight.sh` drives the same file for `./test.sh discriminate`,
  where the `set_regrain_off_keeps_regrain` mutation puts the defect back.

- **A burst of rows minted within one second (or millisecond) no longer stalls the archiving of its
  partition, silently and for good** (#513). `pgpm._next_archive_chunk` ends a chunk at the next distinct
  control value, decoded to the native grid. For `text_time` and `uuidv7` that decode truncates to the
  encoding's unit (a second for ObjectId and KSUID, a millisecond for uuidv7, ULID and cuid), so when one
  unit held at least a chunk's worth of rows (a bulk import) the next distinct value decoded to the chunk's
  own `lo`: the picker returned no chunk, `_archive_step` moved on without a log row, and every later tick
  stopped at the same place. The partition was never covered, `retire()` never dropped it, and `status()`
  showed nothing. The picker now extends such a chunk past the unit, to the first row minted after it (or
  the child's `hi`), so the tied rows travel as one oversized chunk, which is what the contract always said
  a run of ties does. `tests/125_archive_chunk_ties_test.sql` walks the issue's fixture (100 ObjectId ids
  in one second, a budget for about 35) through write-block, archive and retire and asserts the ledger's
  exact three chunks; `bench/archive_chunk_ties.sh` runs that file in the perf track, and
  `./test.sh discriminate` requires it to fail against `archive_chunk_native_ties`, the mutation that
  removes the extension. The uuidv7 millisecond takes the same step but is not exercised until #507
  (`max(uuid)` in the same picker) lands.

- **Day and week partitions are named by the UTC date they start on, in every `partition_tz`** (#503).
  A day-denominated step is an absolute 86400 s lattice from the anchor instant, but `_part_name`
  rendered its label as the wall date of the cell's start in `partition_tz`. In a zone with daylight
  saving that lattice drifts an hour against local midnight twice a year, so two adjacent cells could
  start on the same wall date: with the anchor at a summer midnight, the New York cells starting 00:00
  EDT and 23:00 EST of the fall-back Sunday; with the default anchor, the 00:00Z cells of the fall-back
  Sunday and the Monday in `Atlantic/Azores`. And `set_partition_tz`, documented as safe on a day step
  because "only the names move", moved every label onto the previous cell's after a change to a zone
  west of the old one. `obtain` and `extend_to` skip a candidate whose name already exists, so the
  second cell of any such pair was never built: a permanent one-day hole that refused every write once
  the frontier reached it, with nothing logged and a healthy `status()`. Fixed-second cells (day, week,
  hour, minute) are now all labelled by the UTC reading of their start, the rule hour and minute labels
  already followed; month and year cells keep their wall-month label in `partition_tz`. A day grid's
  zone is therefore a pure setting: its bounds and names are both absolute. Names of existing day
  partitions are not changed (the name is a label; `pgpm.part` holds the bounds). `tests/125` pins the
  rule, `bench/day_label_utc.sh` runs it against `part_name_day_label_in_zone`, and `tests/111`'s three
  day-label expectations follow the new rule.
- **Archive coverage follows the partition, not a stale name** (#511). `pgpm.archive_ledger` is keyed
  `(parent_table, lo)` and matches chunks to their partition by `child_name`, and two things changed
  what a name meant without touching it. `regrain`'s swap dropped a partly archived source (allowed since
  #278) and deleted its `pgpm.part` row but left its chunks recorded under its name, so the first fine
  child's first chunk, at the same `lo`, collided on `archive_ledger_pkey`: `_archive_step` raised out of
  every tick (`skip_archive`, `duplicate key`), and no partition of that parent was archived or retired
  again. The documented rename procedure (update `pgpm.part.child_name` "and nothing else") orphaned a
  partly archived partition's chunks the same way, so archiving restarted from `lo` under the new name
  and collided with the old name's row, every tick, for good. Both were wedges that never cleared.

  `_archive_step` now discards coverage recorded under a `child_name` that is no longer a tracked
  partition of the parent when it overlaps a range a tracked partition holds, logged once per name as
  `archive_coverage_reset`, and the live partition archives from its own `lo` (nothing guarded that
  coverage across the change, the same reasoning as #452; chunks of retired partitions overlap nothing
  and are left as the record of where their rows went). Where pgpm itself changes a name or replaces a
  partition it keeps the ledger consistent in the same transaction: the swap retires the source's chunks
  with its `pgpm.part` row, and the #266 transitional rename carries them to the new name (the old bare
  name is what the first fine child is then called, so a row left there would sit under a live name with
  only #452's no-block reset between it and adoption). The guide and runbook now document the rename as
  updating `pgpm.part.child_name` and `pgpm.archive_ledger.child_name` together, which keeps coverage
  attached and resumes archiving from the watermark instead of exporting the prefix twice; the old
  procedure no longer wedges, it re-exports. `tests/125_archive_ledger_identity_test.sql` pins all four
  paths by which ids were handed under which name; `bench/archive_ledger_identity.sh` runs it against the
  mutants `archive_ledger_no_orphan_sweep`, `regrain_swap_keeps_source_ledger` and
  `regrain_rename_orphans_ledger`, one per mechanism, and each must fail it.
- **A uuidv7 table can be regrained, archived and retired again: nothing reads its control column
  with `max()` or `min()` any more** (#507). PostgreSQL has no `max(uuid)` or `min(uuid)` aggregate
  before 18, and three reads of a uuidv7 table's newest or next control value used exactly those.
  `regrain_step`'s copy resumed from `max(<control>)` over the fine child, so every regrain of a
  uuidv7 monolith raised `42883 function max(uuid) does not exist` on its first copy batch:
  `regrain()` and `regrain_history()` died synchronously, and once `set_regrain` had armed
  auto-regrain every maintenance tick prepared the monolith, failed the copy and logged `skip_regrain`,
  forever, so a uuidv7 history could never be split. `_next_archive_chunk` sized a chunk with
  `max(<control>)` over the byte-budget window and extended it past ties with `min(<control>)`, so on a
  uuidv7 table with an `archive_fn` every tick's archive step raised the same way, was logged as
  `skip_archive`, wrote no ledger row, and `retain()` never dropped the aged partition. All three
  now read the value with `ORDER BY ... LIMIT 1`, the shape `_frontier_native` has used for uuid
  since #325. `tests/125_uuidv7_regrain_archive_test.sql` regrains a frozen uuidv7 monolith both
  synchronously and through `maintain` ticks, then archives and retires the aged month through a
  400-byte budget so the tie extension is reached, asserting the exact rows, partitions, ledger range
  and `retain_drop` involved; `bench/uuidv7_regrain_archive.sh` runs that file against the three
  mutations `regrain_copy_watermark_max_uuid`, `archive_chunk_boundary_max_uuid` and
  `archive_chunk_tie_min_uuid`, one per site, so `./test.sh discriminate` proves each site is
  exercised on its own.
- **`transmute` refuses up front a table it cannot convert and a name it cannot take, and a failed attempt
  can be retried or aborted from the session that owns it (#509).** Three conditions the cutover was
  always going to trip on were checked nowhere before it, so phases 1 and 2 first committed a validated,
  write-rejecting `pgpm_monolith_bound` and the `transmute_inflight` claim, and the failure surfaced as a
  raw error from inside the cutover, on a table the docs promised an up-front refusal would leave
  untouched. Re-running `transmute` on an already converted table (the documented remedy after any
  failure, and what a client that lost its connection after the cutover committed will do) added the
  bound to the live partitioned parent, where it propagated to the forward partitions and rejected every
  write past the original monolith's `hi`, i.e. every current write; with the frontier already past the
  monolith it instead succeeded and nested the whole table under a second parent, with two `pgpm.config`
  rows. A relation already holding the monolith's own coarse name `<table>_p<lo>_to_<hi>`, which neither
  orphan-guard regex matches, failed the cutover's `RENAME` with `42P07`, bound and claim left behind; a
  sequence, view or index holding a child-partition name was skipped by the guard's `relkind = 'r'`
  filter and then by `obtain` itself, so that conversion completed with no forward partition and nothing
  logged, and the first write past `hi` failed with `no partition of relation ... found for row`. And
  after a cutover failure (a `lock_timeout` in phase 3) the
  claim's owner was the operator's still-connected session, which the take-over predicate and
  `transmute_abort` both read as "another session", so the documented retry and the documented abort were
  refused until that session disconnected, which no document said. `transmute` now refuses, before
  anything is committed, a table with a `pgpm.config` row, one whose relkind is not a plain table, and a
  partition, inheritance child or inheritance parent; checks the monolith's own name once the claim has
  made the bound final; and runs the orphan guard over every relation kind, naming what it found (new
  helper `_relkind_noun`). A claim recorded by the calling session itself is that session's own earlier,
  failed attempt: `transmute` resumes it and `transmute_abort` clears it, while a different live session
  is still refused both ways and the reaper's plain liveness test is unchanged, so a `maintain_all` run by
  hand from the owning session still leaves the bound alone. `tests/125_transmute_preconditions_test.sql`
  pins all of it, driving the failing conversions through dblink so a late failure really commits and its
  damage is observable; `bench/transmute_preconditions.sh` runs that file against the three mutations
  `transmute_no_shape_precondition`, `transmute_names_unchecked` and
  `transmute_claim_refuses_own_session`. `tests/101`'s "another session" claim is now owned by a real
  second backend rather than the test's own, which the fix would otherwise have let through.

- **`untransmute` hands back the monolith with none of pgpm's own apparatus left on it** (#508). It
  captured and replayed the parent's row triggers, and `DETACH` strips their clones, but the triggers
  maintenance puts directly on the monolith child were never touched. A monolith retention had reached
  but not dropped, because archiving was deferred or because recorded coverage kept the block after the
  frontier regressed (#452), came back as an unmanaged table whose `pgpm_write_block` rejected every
  INSERT, UPDATE and DELETE with "past its retention boundary", with `pgpm.config` and `pgpm.part` gone so
  no tick could ever lift it. And with a regrain in flight, `pgpm_regrain_capture` rode the monolith into
  the restored table, so `untransmute`'s own `drop function` died on the dependency and the whole call
  rolled back, neither the documented refusal nor a reverse; a reverse that got past it would have
  orphaned the not-yet-attached fine copies, which the parent's `DROP` never reaches. Now, under the lock
  and after the gate, `untransmute` lifts the block through `_remove_write_block` and abandons an in-flight
  regrain through `regrain_cancel` (trigger and `TRUNCATE` guard off, copies dropped, delta cleared, cursor
  null, one `regrain_cancel` log row), then reverses as before; a regrain that has swapped still shuts the
  door. `tests/125_untransmute_residue_test.sql` builds all three states (deferred block, coverage-kept
  block, mid-regrain), witnesses each before the reverse and asserts by which rows and which triggers
  remain; `bench/untransmute_residue.sh` drives the same file for `./test.sh discriminate`, where the
  `untransmute_keeps_write_block` and `untransmute_keeps_regrain_capture` mutations each put one half of
  the defect back.
- **A name pgpm derives from the table's is never truncated; `transmute` and `set_regrain` refuse
  instead** (#510). `_part_name` cast `<rel>_p<label>` to `name`, which silently cuts it to 63 bytes, and
  its comment called that cosmetic because `pgpm.part` holds the bounds. But `obtain` decides whether a
  forward cell already exists by that name, so for a table name of about 55 characters or more every
  candidate rendered the same 63 bytes, the monolith took that name at `transmute`, every forward cell was
  skipped as existing, nothing was logged, and the first write past the monolith's `hi` failed with
  PostgreSQL's `no partition of relation ... found for row`; one byte longer and the cut monolith name
  equalled the cut staging name `<rel>_pgpm_new`, so the cutover's RENAME failed after two phases had
  committed. `_part_name` now refuses a name over 63 bytes with a `pg_partition_magician:` error naming
  it, its length and the bytes to shorten the table name by, which covers `obtain`, `extend_to`,
  `regrain_step` and `transmute`, where the monolith is named before anything is claimed or committed;
  `transmute` holds the staging name to the same rule, and `set_regrain` refuses a target step whose
  wider labels would not fit at call time rather than logging `skip_regrain` on every tick. The budget is
  under [Partition naming](docs/reference.md#partition-naming): on a monthly grid the table name can be up
  to 43 bytes when the data spans more than one month. `tests/124_part_name_length_refused_test.sql` pins
  the boundary from both sides (a 63-byte name renders, a 64-byte one refuses, and every refusal is paired
  with the same shape one byte shorter converting and building its forward grid); `bench/part_name_length.sh`
  runs it under `discriminate` against three mutations (`part_name_silent_truncation`,
  `transmute_staging_name_silent_truncation`, `set_regrain_no_name_check`).

  **Upgrading in place: a long-named table converted before this fix has no forward grid.** Its monolith
  carries a cut name and `obtain` skipped every cell. After the upgrade each tick's `obtain` refuses
  instead and `maintain` logs `skip_obtain` with the message, so the table is visible rather than silent,
  but nothing repairs it: `untransmute` (a clean reverse, since every row is still in the monolith), rename
  the table within the budget, and `transmute` again. `select parent_table, child_name from pgpm.part
  where attached and octet_length(child_name) = 63` lists the candidates; a cut name ends mid-label.
- **Auto-regrain selects only a child its target actually subdivides (#515).** `maintain`'s candidate
  was the oldest frozen child wider than one `partition_step`; `regrain_step` then required that the
  target step subdivide it, and the two agreed only while the target was no wider than the step at
  every point of the calendar, which `set_regrain`'s coarser-than-step refusal checks once, at
  `partition_anchor`. `'30 days'` on a monthly grid passed (narrower than the anchor's January), yet a
  30-day cell that starts in February is wider than the calendar month from there, so once the first
  coarse child had been split, that cell was the candidate on every tick, answered `nosubdiv`, and every
  coarse child behind it was never regrained: silent and permanent. The candidate query now requires
  both (coarse by the grid's step, and subdividable by the target, `regrain_step`'s own precondition),
  so a cell the target cannot split is skipped and the next coarse child is worked; such cells stay
  counted in `status().coarse_partitions`, and `progress().coarse_frozen` mirrors the same test so it
  reports what auto-regrain will actually work. The refusal itself is unchanged, and its comment now
  says what it does and does not compare. `tests/125` (a monthly ULID grid split into years, then
  auto-regrained toward 30 days: the second year is what the unfixed code never reached), guard
  `bench/regrain_candidate_subdivides.sh`, mutation `regrain_candidate_ignores_target`.
- **A schema whose name needs quoting no longer wedges archive, retire and regrain** (#512).
  `_is_write_blocked` and `_regrain_capture_active` selected the parent's `nspname` and cast the raw
  name back with `::regnamespace`, whose input parses its text as an SQL identifier: for a managed
  table in `"Sales"` the lookup raised `schema "sales" does not exist`, so every `maintain()` tick
  logged `skip_archive`, nothing was archived and the aged partition was never dropped, while an
  auto-regrain could not prepare (`skip_regrain`) and the janitor logged `skip_regrain_capture` per
  child; once a lower-case `sales` schema existed the cast instead answered silently for the twin's
  same-named child. Both functions now compare the child's `relnamespace` against the parent's
  namespace OID and never re-parse a name. `tests/124_quoted_schema_test.sql` drives the archive,
  regrain and twin cases with a lower-case control alongside each; `bench/quoted_schema.sh` runs it
  against an arbitrary install so `./test.sh discriminate` proves it fails against the
  `schema_name_regnamespace_cast` mutation.
- **`maintain` re-applies its 200 ms `lock_timeout` after the retain boundary too, so auto-regrain's
  swap gives up instead of blocking the parent** (#514). `set local` dies at `COMMIT`, and `maintain`
  put `lock_timeout` back after each of its boundaries except the one after `retain`, which is the one
  that precedes the auto-regrain block. `regrain_step` therefore ran under the session default (`0`,
  wait forever): with a writer holding one row in the source, the swap's `DETACH` kept its
  `ACCESS EXCLUSIVE` request on the parent queued for the writer's whole transaction, every read of the
  parent queued behind that request, and when the writer committed the tick swapped as if nothing had
  happened, where the reference promises a `skip_regrain` row after 200 ms and a retry next tick. The
  missing `set_config` is back. `bench/maintain_regrain_lock_timeout.sh` (perf track) holds a row in
  the source from a second session and runs one tick from a third: the tick must return while the
  writer still holds, log exactly `skip_regrain` with the lock-timeout message and nothing else, leave a
  third-session reader unblocked, and swap on a later tick once the writer is gone, with the held row
  read back from its fine child. Its mutation, `maintain_no_lock_timeout_after_retain`, removes the one
  line.
- **regrain's change capture is found by identity, re-minted per regrain, and writable by the parent's
  writers** (#496). The per-parent delta table and trigger function were found by NAME, derived from the
  parent's CURRENT relname, and kept once minted. An ordinary `ALTER TABLE ... RENAME` of the parent
  mid-regrain therefore left the source's trigger writing the delta it was given while the reconcile, the
  swap gate and the swap all derived a new name, found nothing, counted 0 pending and swapped: every
  change committed since the copy went with the source (an UPDATE reverted, a DELETE resurrected, an
  INSERT gone). A key column renamed between two regrains left the delta with the first regrain's
  columns while the trigger function inserted the current key's, so every write into the source raised
  for the life of the next regrain. And the delta was created by whoever ran the tick, with no grants,
  while the trigger runs as the writer, so every non-owner role with DML on the parent got
  `permission denied` on every write into the regraining child. The prepare tick now records the oids it
  minted in `config.regrain_delta_oid` and `config.regrain_capture_fn_oid`, and every reader resolves the
  relations from there (`_regrain_capture_names`; the parent-derived names, now `_regrain_capture_derive`,
  are what it mints under and the fallback when nothing is recorded); it drops and re-mints the delta on
  every prepare from the key as it is then, refusing a foreign relation on the name rather than truncating
  it; and it owns the delta like the parent and grants `INSERT` on it to every role holding `INSERT`,
  `UPDATE` or `DELETE` on the parent (`_regrain_capture_grant`), re-synced on every tick so a grant made
  mid-regrain is honoured from the next tick. Re-running `install.sql` backfills the two anchors for a
  regrain already in flight. Pinned by `tests/124`, run against its three mutations by the new
  `bench/regrain_capture_identity.sh` (`regrain_capture_by_name`, `regrain_delta_reused`,
  `regrain_delta_ungranted`); `bench/upgrade_in_place.sh` now upgrades with a regrain in flight and
  requires the anchors backfilled by identity (`upgrade_regrain_capture_backfill_noop`).
- **`pgpm.dropped_fk` records anchor a preserved incoming key by identity, from any session** (#498).
  The cutover recorded `pg_get_constraintdef()` as rendered in the transmuting session, which leaves the
  referenced table unqualified whenever that session's `search_path` can see it, and `restore_incoming_fks`
  replayed the text in pg_cron's session, so `REFERENCES orders(id)` resolved to whatever `orders` meant
  there: an unrelated `public.orders` (the key came back against the wrong table, logged
  `restore_incoming_fk`) or nothing (`fail_restore_incoming_fk` every tick). And `referencing_table` was
  the referencing table's oid as of the capture: for a self-referential key that is the very oid the
  cutover renames into the monolith child, and for any key it is the oid a later `transmute` of the
  referencing table renames the same way, so the restore re-added the key on that one partition and every
  row routed to a forward partition escaped it, while the log said restored. Now the definition is captured
  through `pgpm._fk_definition`, which pins `search_path` to `pg_catalog` so the referenced table is
  always schema-qualified (the hypertable module's capture uses it too); the cutover moves every record in
  which the converted table is the referencer onto its new parent, in the rename's own transaction, and
  `untransmute` moves them back onto the restored table; and re-running `install.sql` rewrites a record an
  earlier pgpm captured unqualified. Records an earlier pgpm anchored on a monolith partition are not
  rewritten: their key may physically live on that partition, and moving the record without the key would
  break `suspend_incoming_fks`. `tests/124_dropped_fk_identity_test.sql` (the issue's three reproductions
  plus both `untransmute` round trips), `bench/dropped_fk_identity.sh` (the same file against an arbitrary
  install, plus the upgrade rewrite), and three mutations in `bench/mutations/mutate.py`.
- **Native bounds are stored in ISO 8601 form whatever the writing session's `DateStyle`** (#500). Every
  native time value pgpm stores (`pgpm.part.lo`/`hi`, `pgpm.log.lo`/`hi`, `config.partition_anchor`,
  `transmute_inflight.lo`/`hi`, the archive ledger's bounds) is text, and it was rendered with a bare
  `timestamptz::text`, which follows the writing session's `DateStyle`. A `transmute` run from a session
  on `SQL, DMY` stored 1 October 2026 as `01/10/2026 00:00:00 UTC`; the pg_cron session, on the default
  `ISO, MDY`, read that back as 10 January, so the monolith's real upper bound (next month) sat below the
  retention horizon and `retain()` dropped the live write partition, rows written that day included.
  Every render now goes through `pgpm._ts_text`, which pins `DateStyle` to ISO for the duration of the
  call, so a stored bound reads as the same instant from any session; parses are unchanged and still
  honour the caller's session. Bounds a pre-fix install wrote from a non-ISO session keep their old form
  and read correctly only under the `DateStyle` that wrote them, exactly as before. Guarded by
  `tests/124_datestyle_independent_bounds_test.sql` (the issue's reproduction, with the stored text and
  the instant an `ISO, MDY` session reads it back as asserted by identity), which
  `bench/datestyle_bounds.sh` runs against its mutation (`datestyle_session_render`) under
  `./test.sh discriminate`.
- **`pgpm_archive`'s object key keeps the sign (and decimal point) of an `id` kind's lo** (#502). Both
  transports, `pgpm.archive_to_s3_ndjson` and `pgpm.archive_to_s3_parquet`, named the uploaded object
  after the digits of the chunk's lo, `regexp_replace(p_lo, '[^0-9]', '', 'g')`, so chunk lo `-10000`
  and chunk lo `10000` of one table shared one key: a single `maintain()` tick uploaded the second over
  the first, both ledger rows recorded the shared key as archived, and `retire()` would have dropped the
  `[-10000, 0)` partition with its rows gone from the store. On a `numeric` control the same projection
  folded `10.5` onto `105`. The stem now comes from `archive._object_stem(kind, lo)`, which keeps the
  `id` kind's numeric text whole (`<prefix><parent>_-10000.ndjson`) and leaves the digits-only shape of
  every time-based kind, and so every existing key, untouched; a non-negative integer lo produces the
  same key as before. `tests/archive/db/16_archive_object_key_identity_test.sql` drives both transports
  on the issue's fixture and reads each object back by identity; `bench/archive_object_key.sh` runs it
  in the archive track and under `discriminate` against the `archive_object_key_digits_only` mutation,
  which puts the digits-only stem back.
- **`pgpm.set_archive_fn` refuses a strategy that does not return `pgpm.archive_result`** (#517). The
  `regprocedure` cast resolves a name and an argument list and never looks at the return type, and nothing
  else did, so a strategy declared `returns text` was accepted, against the reference's promise that
  assignment validates the whole signature. `_run_archive_strategy` reads the strategy's result into a
  `pgpm.archive_result` variable positionally, so that strategy's one column became `covered_hi`; one that
  echoed `p_hi` passed the contract check as a perfect answer, wrote a ledger row with `rows_archived null`,
  and the next `retain()` dropped the partition with nothing archived. `set_archive_fn` now looks the
  function up in `pg_proc` and refuses one whose return type is not exactly `pgpm.archive_result` (any
  other type, or `setof`), or an oid that names no function, with an error naming the function, what it
  returns and the contract, and leaves `config.archive_fn` unchanged. `docs/reference.md` says what the
  cast checks and what the function checks. `tests/129_set_archive_fn_return_type_test.sql` pairs each
  refusal with the witness that the cast alone accepts the candidate and that the tick which follows
  archives through the well-typed twin; `bench/set_archive_fn_return_type.sh` drives it against the
  `set_archive_fn_no_return_type_check` mutation, which `./test.sh discriminate` requires it to fail.

- **The S3 archive transports read a chunk in the grid's zone** (#501).
  `archive._encode_upload_ndjson_single` and `archive._encode_upload_parquet`, the transports behind
  `pgpm.archive_to_s3_ndjson` and `pgpm.archive_to_s3_parquet`, rendered the chunk's `[lo, hi)` into
  column literals without `config.partition_tz`, so each literal carried the wall clock in UTC. A
  `timestamptz` column reads the same instant from any offset and was unaffected. A naive `timestamp`
  or `date` column drops the offset and compares the wall clock, so on a grid recorded in another
  zone (`America/New_York`, say) the strategy read the range five hours late: the object held the
  wrong hour's rows, `rows_archived` counted them, and `covered_hi = p_hi` still declared the chunk
  archived, so `retire()` could drop a partition whose own rows were never uploaded. Both transports
  now pass `partition_tz`, as every reader of a chunk in `pgpm_core` already did.
  `tests/archive/db/16_encode_partition_tz_test.sql` builds the issue's fixture (three rows in one
  New York hourly child, archived from a UTC session) and reads both objects back from MinIO by row
  identity; `bench/archive_encode_partition_tz.sh` drives it in the archive track and in
  `discriminate` against the `archive_encode_no_partition_tz` mutation, which removes the argument
  from all four sites.
- **A row trigger's enabled state survives `transmute` and `untransmute`** (#499). Both replayed the
  table's triggers from `pg_get_triggerdef`, which never emits `pg_trigger.tgenabled`, so every replayed
  trigger came back `ENABLE` (origin-only) whatever it had been: a trigger the operator had `DISABLE`d
  fired again on the very next write and silently rewrote what was stored, an `ENABLE ALWAYS` one stopped
  firing under `session_replication_role = replica` and an `ENABLE REPLICA` one started firing for
  ordinary sessions, with nothing refused or logged. Each site now captures the trigger's name and state
  alongside its definition and re-applies every non-default state after the verbatim replay: at the new
  parent, where `ENABLE`/`DISABLE TRIGGER` recurses to the clone on every partition and a clone minted
  for a later partition inherits it, and at the restored table. `tests/124_cutover_trigger_tgenabled_test.sql`
  carries one trigger per state through the cutover and the reversal and asserts by which rows carry
  which value; `bench/cutover_trigger_state.sh` drives the same file for `./test.sh discriminate`, where
  the `transmute_trigger_state_dropped` and `untransmute_trigger_state_dropped` mutations each put one
  site's defect back.

- **A regrain reconcile pass consumes from the delta exactly the captured rows it applied, never
  "everything at or below a watermark"** (#497). `_regrain_reconcile` read its batch watermark, its list
  of touched fine children, each child's delete and reinsert, and its final `delete from <delta> where
  pgpm_seq <= wm` as separate statements, each under its own READ COMMITTED snapshot. `pgpm_seq` is an
  identity value assigned when the capture trigger fires, inside the writer's transaction, so a writer
  that updated an already-copied row, held its transaction open across a tick, and committed while the
  tick was applying its batch had a capture below the watermark that the apply statements could not see
  and the final delete could: it was deleted unapplied, the fine child kept the pre-change row, and the
  swap attached it, silently reverting a committed UPDATE. The batch is now materialised once, as the
  `pgpm_seq` values of the eligible rows visible in a single snapshot, and every later statement in the
  tick, the final delete included, addresses the delta by that set; a capture the tick did not see stays
  in the delta for the next tick, which applies it. `tests/124_regrain_reconcile_snapshot_test.sql`
  reproduces the three-session interleaving by lock state and asserts by identity that the UPDATE
  survives the swap; `bench/regrain_reconcile_snapshot.sh` drives it against the
  `regrain_reconcile_delete_by_watermark` mutation, which `./test.sh discriminate` requires it to fail.

- **A `timestamp` or `date` control column's grid is the column's own wall clock, recorded as
  `partition_tz = 'UTC'`** (#504). pgpm read a naive value as wall time in the transmuting session's
  zone, computed the grid on the resulting instants and rendered every bound back in that zone with an
  offset the column then discarded. A calendar step round-trips that way, but the day and hour steps are
  an absolute lattice of seconds that does not sit on the column's clock in a zone with an offset: under
  `America/New_York` a `date` column with a day step got a monolith `CHECK` of `d < yesterday's date`
  (the 00:00Z boundary rendered as 20:00 the previous day), so phase 2's `VALIDATE` failed with a raw
  `23514` after phase 1 had committed and the `NOT VALID` `CHECK` rejected every row dated today; with an
  hourly step the two cells either side of the autumn fall-back rendered to the same naive wall time
  (05:00Z and 06:00Z are both 01:00 in New York), `CREATE TABLE` refused the second as an empty range
  and the grid could never extend past that hour; and `set_partition_tz` accepted a zone change for such
  a column, after which new bound literals were rendered in a different zone from the existing ones.
  Now a naive column's values are taken as what they are, wall readings: a day is `[D 00:00, D+1 00:00)`
  in the column's values, an hour `[H:00, H+1:00)`, a month `[1st 00:00, next 1st 00:00)`, and every
  literal is that reading. That is the UTC lattice, so `transmute` records `UTC` for such a column
  whatever the session's zone (as it does for an `id` grid) and `set_partition_tz` refuses to move it.
  The write frontier for such a column is `now()` on that same clock, so an application writing local
  wall time from a zone east of UTC runs ahead of it by its offset, which the forward slack covers on a
  day or coarser grid and needs `obtain` above the offset in hours on an hourly one. A naive-column
  table transmuted from a non-UTC session on an unreleased build keeps its recorded zone (its grid is on
  that lattice). `tests/126` pins the rule, `bench/naive_column_utc_grid.sh` runs it against
  `naive_column_grid_in_session_zone`, and `tests/111` (d) follows it.
  A grid converted before this change keeps the zone it was recorded in, and pgpm keeps reading it there;
  `tests/archive/db/16_encode_partition_tz_test.sql` (#501's guard) now builds that legacy state by hand,
  since it is the state on which the transports' zone argument is observable.

- **A month step is one lattice where midnight on the 1st falls in a daylight-saving gap** (#505). Where
  a zone's clocks jumped forward at midnight on the 1st (`America/Asuncion` on 2023-10-01, `Asia/Amman`
  on 2016-04-01), `_grid_floor` correctly resolved the boundary to the first instant of the month, which
  reads 01:00 on the wall clock, but `_grid_next` added the month to that reading as it stood and landed
  an hour past the next boundary: `next(floor(Oct))` was 01:00 on November 1 while `floor(Nov)` was
  00:00. `regrain_step` walks its sub-ranges with exactly that pair, so the October child ended an hour
  after the November child began, the swap's `ATTACH` failed with "would overlap", and under
  auto-regrain that was `skip_regrain` on every tick, forever. `_grid_next` now steps a month boundary
  from its month's wall midnight, so the two functions describe one lattice; an off-grid value (the
  anchor `set_regrain` compares two widths from) still steps by a plain calendar month. `tests/127` pins
  the pair regrain computes on both gaps and on a twelve-step chain, under two session zones;
  `bench/month_step_dst_gap.sh` runs it against `grid_next_month_unsnapped`, and the existing
  `grid_session_timezone` mutation is re-anchored on the rewritten line.

- **A resumed `transmute` keeps the zone its bound was computed in** (#506). Phase 1 computes the
  monolith's bound in the transmuting session's zone and records it in `pgpm.transmute_inflight` so a
  re-run after a failure between the phases resumes on it, but the claim did not record the zone. A
  resume from a session in another zone reused the bound and then registered `config.partition_tz`
  from its own session, so the monolith sat on one lattice and every later grid computation on another:
  `obtain`'s first candidates half-overlapped the monolith and were skipped, a hole one whole step wide
  was left right past its `hi` (writes there failed with "no partition of relation found for row"), and
  `set_partition_tz` refused to repair it. `pgpm.transmute_inflight` now carries `partition_tz`, the
  claim records it, a resume adopts it along with the bound, and the `transmute_resume` log row names
  the zone it reused. A claim recorded before the column existed carries null there and a resume keeps
  the session's zone, as before. `tests/128` resumes a New York claim from a UTC session and checks the
  monolith's bound is a boundary in the recorded zone and the first forward child starts exactly at it;
  `bench/transmute_resume_zone.sh` runs it against `transmute_resume_session_zone`.

- **PRs land through a merge queue, and the repository moved to `neptunestation-com`.** GitHub offers the queue only on organization-owned repositories, which is why the move; the explainer now lives at `neptunestation-com.github.io/pg_partition_magician` and the old Pages URL does not redirect (the old repository URL does). Every PR workflow (`test`, `lint`, `perf`, `archive`, `observe`,
  `locktrace`, `lockview`) now also runs on `merge_group`, so the queue tests `main` plus the queued
  PRs as one tree before merging, and `main` requires three stable summary checks (`Test Summary`,
  the new `Lint summary` and `Perf summary`) instead of eight job names. The perf workflow drops its
  path filter, because a required check that did not run blocks a PR from being queued; sharded, it
  is about as long as one pgTAP matrix job. Before this, `main`'s "branch must be up to date" rule
  made every merge a rebase plus a full CI run per PR, about 30 minutes each, serialised.

- **The perf CI job is sharded across runners.** One job that ran every bench guard and then every
  discriminating mutation took 27 minutes and was the critical path of every PR's CI (the pgTAP matrix
  takes 6). `./test.sh perf --shard=I/N` and `./test.sh discriminate --shard=I/N` (also
  `bench/discriminate.sh --shard=I/N`) run the I-th of N interleaved slices of the same lists, chosen by
  index, so every guard and every mutation runs in exactly one of `.github/workflows/perf.yml`'s seven
  matrix jobs and no guard's environment changes: each still gets its own runner, container and
  database. A slice that would select nothing fails instead of passing vacuously, and `--list` prints a
  slice without touching Docker, which is how the partition was checked. Without `--shard` both tracks
  still run everything, as `./test.sh ci` does.

- **The partition grid is computed in a recorded zone, never in the caller's session `TimeZone`** (#455).
  `_grid_floor`, `_grid_next`, `_part_name` and `transmute`'s bound computation evaluated `date_trunc`,
  `extract`, `+ interval` and `to_char` in whatever zone the calling session had. An operator transmuting
  under `America/New_York` therefore built children on the `00:00-04/-05` lattice while pg_cron, under
  the server's UTC, computed `obtain`'s candidates on the `00:00+00` lattice, found each half-overlapping
  an existing child, skipped it, and created the first one past the New York tail: a permanent hole about
  `p_obtain` steps out, with nothing logged and a healthy `status()`. Independently, `+ '1 day'` on a
  `timestamptz` is a calendar day in the session zone (23 or 25 hours across a DST transition) while
  `_grid_floor`'s fixed-seconds branch is an absolute 86400 s lattice, so any DST-observing session
  opened a 23-hour hole every autumn on daily and weekly grids.

  `transmute` now records the transmuting session's `TimeZone` in the new `pgpm.config.partition_tz`
  (`UTC` for `id` grids; the call refuses a session zone that is not a `pg_timezone_names` name), and
  every adapter call takes that zone as a parameter, so the same table gets the same bounds and names
  from any session. Day-denominated steps are an absolute number of seconds in `_grid_next` too, so the
  two functions share one lattice; the price is that in a DST zone a daily boundary drifts an hour against
  local midnight twice a year (UTC is unaffected). `timestamp` and `date` control columns are read as
  wall time in `partition_tz` everywhere, and every bound literal pgpm writes carries the wall time in
  that zone with its offset, so all three column types get the same bounds from any session. Hour and
  minute partition labels are rendered in UTC: a DST zone's wall clock repeats an hour every autumn, so
  two adjacent hourly cells would otherwise share a name and `obtain` would skip one.

  **Upgrading in place: check `partition_tz` if any table was transmuted from a non-UTC session.** The
  column backfills to `UTC`, because nothing in the catalog records which zone an existing grid was built
  in. If the operator's session was in another zone at `transmute` time, run
  `select pgpm.set_partition_tz('schema.table', 'That/Zone')` for that table. The new setter validates
  the name against `pg_timezone_names` and refuses unless the grid's newest bound is on that zone's
  lattice (a day-denominated grid is on the same lattice in every zone and always accepts). A refusal
  means maintenance has already extended the grid in UTC: keep `UTC`, and look for an existing hole by
  walking `pgpm.part` for the table ordered by `lo::timestamptz`, where any row whose `hi` differs from
  the next row's `lo` marks a range no partition covers and must be created by hand. Installs that only
  ever transmuted from UTC sessions need no action.
- **A Parquet file is now written from one snapshot (#462).** `archive._pq_to_parquet` and
  `archive._pq_to_parquet_range` used to run `count(*)` and then one query per column straight
  against the relation. A VOLATILE plpgsql function under READ COMMITTED takes a fresh snapshot per
  statement, so a row that committed between two column reads was in the later columns and not the
  earlier ones, and from that column on every value sat one row away from the row it belonged to.
  The file was well-formed (every column had exactly `count(*)` values), so no reader could tell;
  the bug hunt read 8000 of 8000 rows with a `tag` belonging to a different row's `id`. Both
  encoders now materialise the rows once, in their final order, with the new
  `archive._pq_snapshot` (one statement, one snapshot, into a session temp table dropped as soon
  as the last column is read), and read every column from that. Bytes are unchanged for an
  unchanged table: the ordering key is the same, verified byte-for-byte across both entry points,
  compressed and not. The automatic path's `rows_archived` comes from that same snapshot too, via
  the new `archive._pq_to_parquet_range_counted(...) -> (p_file, p_num_rows)`; the bytea
  `archive._pq_to_parquet_range` is now a one-line wrapper over it, so existing callers are
  unaffected. The comment on `archive.to_s3_parquet` that claimed a single snapshot now describes
  one, and says plainly that the manual path has no write fence: a row that commits after the
  snapshot is not in the file, so quiesce the partition first or use the automatic path.

  If you archived Parquet on the **manual** path (`archive.to_s3_parquet`) while the partition was
  still being written to, files written before this fix may be misaligned across columns in exactly
  this way, and nothing in the file says so. Re-encode from the source if you still have it, or
  check a sample of rows against a column you can cross-reference. The automatic path write-blocks a
  partition before archiving it, so its files were exposed only to a writer that bypassed the
  fence (`session_replication_role = replica`). New: `tests/archive/db/15`, the two-session race,
  and `bench/archive_parquet_snapshot.sh`, which reads the racy files back with pyarrow and is
  required to fail against the `parquet_per_column_statements` mutation.
- **`text_time` refuses a digit alphabet the control column's collation does not order** (#456). A RANGE
  partition on a `text` column compares under the column's collation, while the bounds `text_time`
  computes are ordered by base-N place value, which is bytewise. Under `en_US`, the default collation of
  most databases, case is a tertiary weight, so `a` sorts before `P` where base62 puts `a` = 36 above
  `P` = 25: random-payload KSUIDs do not sort in timestamp order (13% of 2,085 sorted outside their own
  month), the guide's exact KSUID recipe failed at VALIDATE with `check constraint "pgpm_monolith_bound"
  ... is violated by some row`, and a small table that happened to pass routed rows to the wrong month,
  where retention would drop them early. `transmute` (before anything is touched, and not overridable by
  `p_force_text_time`, which covers a sampling heuristic, not arithmetic) and `check_text_time` (as a
  refusal, not a plausible fraction) now compare the alphabet's adjacent digits under the column's
  collation at the declared width and refuse, naming the collation (the effective database locale when
  the column is on `"default"`), the first misordered digit pair and the remedy,
  `alter table ... alter column ... type text collate "C"`. The comparison is of width-long strings, not
  single characters: a multi-level collation can order two characters at the case level and let a later
  position override it (`'a' < 'A'` yet `'aZ' > 'Ab'` under `en_US`), and the string form fails exactly
  when two digits are not separated at the primary level. cuid, ULID-as-text and ObjectId are
  single-case and unaffected, verified rather than assumed by `tests/122`'s random-payload ULID on an
  `en_US` column. `tests/91`'s KSUID fixture moves to a `collate "C"` column, which the guide's recipe now
  says it must be; its payload-zero values are the month bounds themselves, so it could never have
  caught this. New internal `pgpm._check_text_time_collation`.
- **`_detach_reap` no longer finalizes a live concurrent detach** (#453). It finalized every partition
  flagged pending detach under a managed parent, with no check that the session running the detach was
  gone. A concurrent detach spends its whole wait phase in exactly that state, for as long as the longest
  transaction holding a lock on the parent, and `maintain_all` shares a cadence with the `pgpm_detach`
  job, so the reaper routinely finalized a detach that was alive and waiting: PostgreSQL's
  wait-for-old-snapshots phase was skipped, and the real detacher then failed with `is not a partition`,
  once per tick, into `cron.job_run_details`. The reaper now skips a pending partition while any other
  session is still running its detach. The test is shaped by a measured fact: a detacher parked in its
  wait phase holds **no** relation lock at all (its first transaction commits before it waits), so "does
  anyone hold a lock on the partition" cannot see the phase the bug lives in. Three signals, any one of
  which means live: a lock held or awaited on the partition itself (the finalizing transaction), an
  active `DETACH PARTITION ... CONCURRENTLY` statement naming the partition (every phase, but visible
  same-role only), and a backend parked on the vxid of a transaction that has the parent locked (the wait
  phase, `pg_locks` only, so it covers a hand-run detach under a role whose statement the reaper cannot
  read). A skipped partition is not logged: a detach in progress is the expected state, not a deferral.
  The residual failure is deferring a reap by one tick, never finalizing a live detach. `tests/116` pins
  four cases with the detacher's liveness witnessed before every reap: live and same-role, live in the
  wait phase and live in the finalizing phase with the reaper run as a role for which the detacher's
  statement is masked (each isolating one signal), and abandoned with the holder's transaction still open
  on the parent, which is what tells the signals from a "someone has the parent locked" shortcut.
- **Fixed: Parquet shifted `timestamp` (without time zone) columns by the session zone** (#465). The
  writer cast a naive timestamp through `::timestamptz`, which reads the wall clock in the SESSION
  zone, so the same partition archived by pg_cron (the cluster's default zone) and by
  `call pgpm.maintain()` from a differently-zoned psql carried different instants, while NDJSON's
  `row_to_json` preserved the wall clock either way. A `timestamp` column is now written as its wall
  clock read as UTC and annotated `TIMESTAMP(isAdjustedToUTC=false, MICROS)` beside the legacy
  `TIMESTAMP_MICROS` (the pair pyarrow writes for a naive timestamp), so the bytes no longer depend on
  the session, and pyarrow and DuckDB return the wall clock as a naive timestamp, the same value NDJSON
  carries. `timestamptz` is unchanged. **Parquet files written before this fix from a `timestamp`
  column under a non-UTC session carry instants shifted by that session's UTC offset at each row's
  date** (under `America/New_York`, January rows read five hours late and July rows four); files
  written under UTC hold the right values and only lack the annotation, so readers label their wall
  clock UTC.
- **`transmute` refuses a `uuidv7`/`text_time` maximum far ahead of the clock (#457).** For these kinds
  the frontier is `greatest(max(control), now())` and had no upper sanity bound, so one row minted by a
  client with a wrong clock set the frontier, and with it the monolith's permanent `hi`, years into the
  future: every row written today landed in the monolith, `check_uuidv7` passed at 0.9975, `status()`
  showed nothing abnormal, and the monolith could not be regrained nor anything behind it dropped until
  the clock really got there. `transmute` now refuses, before anything is committed, a newest value that
  decodes to more than **one partition step plus one hour** past `now()`, naming the offending value, its
  decoded timestamp, the `hi` it would have imposed and the one the clock alone gives. The allowance is
  measured from `now()`, not from a `p_bound_headroom`-widened bound; one step because the cost of a
  maximum inside it is bounded to what `p_bound_headroom => 1` would have cost, one hour so a fine grid
  still tolerates ordinary clock skew. The check runs after the UUIDv7 ceiling refusal, so a forced random
  column keeps getting the message that names its real cause. New trailing parameter
  **`p_force_frontier boolean default false`** on `_transmute` and the interval-width `transmute` accepts
  the far `hi` knowingly (with a `NOTICE` restating the cost); the previous shapes of both are dropped on
  upgrade so a 3-argument call cannot become ambiguous. `check_uuidv7` and `check_text_time` gain
  **`newest_decoded`** (the column's actual maximum, decoded, not the sample's) and **`newest_in_future`**
  (more than one hour past `now()`), so the row is visible before converting; both are drop-and-recreate,
  so re-running `install.sql` picks them up. `tests/123`.
- **regrain's aged skip is re-checked at the swap, and never fires on a half-copied sub-range** (#448).
  As the cursor passed a sub-range entirely below the retention horizon, `regrain_step` skipped it
  (`regrain_aged`) and that decision lived on only as the advanced cursor. Two consequences.
  `set_retain(parent, null)`, or a longer value, before the swap made the policy say keep while the rows
  were still visible through the attached source, and the swap's `DROP` took them (39,999 rows in the
  hunt that found this). And a sub-range partially copied in one tick whose range aged before the next
  was skipped anyway, so the swap attached its partial child and the parent served a fraction of the
  range as the whole of it.

  Now the swap walks every sub-range of the source on the target grid, before it locks anything, and
  **refuses**, naming the range, when one that has no fine child to attach is no longer below the
  current horizon: the source stays attached, the cursor stays at `hi`, and the run resumes once
  `retain` is set back (or `regrain_cancel` it and re-run under the new policy; through `maintain` the
  refusal is a `skip_regrain` row carrying the message). The skip itself no longer fires on a sub-range
  that already has a fine child: its copy is finished instead, which is what lets the swap treat "a
  child exists" as "its copy is complete". `set_retain` **warns**, rather than refuses, when it loosens
  retention under an in-flight regrain, since the change is safe and only the swap's timing is affected.
  New internal `pgpm._regrain_has_child(parent, lo, hi)`, the one notion of "this sub-range has a fine
  child" both sites share, answered from `pgpm.part` because that is what the swap attaches from.
  Guarded by `tests/121`: four sub-ranges skipped as aged, `set_retain(null)`, the swap refuses and every
  sampled aged row is still served by identity; a longer value, and the refusal names the first range no
  longer below the horizon; the original value, and the very next tick swaps. Then a batch smaller than
  a sub-range, one tick copying 100 of 249 rows, the frontier moving the horizon past it, and the
  following ticks finishing the copy, so that after the swap no attached partition holds a strict subset
  of its source range.
- **Fix: `regrain_step`'s reconcile no longer discards captured changes in a clamped first sub-range**
  (#446). When a coarse child's `lo` is off the target grid (a weekly `regrain_to` on a monthly monolith,
  which `set_regrain` accepts; a `7000` target on a child starting at `20000`), `regrain_step` clamps the
  first sub-range to that `lo` and names the fine child from it, but the reconcile re-derived the sub-range
  from the grid floor with no clamp, looked for a child that never existed, took its absence for "skipped
  as aged", logged `regrain_reconcile_aged` and deleted the captured keys. The swap then dropped the source
  with them: every UPDATE in that sub-range reverted, every DELETE came back, every INSERT vanished. The
  reconcile now locates the fine child by range containment in `pgpm.part` (the name is a label; the
  recorded bounds are authoritative), and a sub-range with no fine child is treated as aged only when it
  is below the retention horizon, the same test `regrain_step` applied when it skipped it. Otherwise the
  tick raises and the delta keeps the keys, which `maintain` surfaces as `skip_regrain`. The
  `regrain_reconcile_aged` row now carries the sub-range's `lo` and `hi` in place of a rendered name.
  Pinned by `tests/120`: the issue's fixture with one UPDATE, one DELETE and one INSERT inside the clamped
  sub-range, asserted by identity in the fine child before the swap and through the parent after it, with
  the aged path kept, the not-aged raise, and the monthly-to-weekly name disagreement on the time grid.
- **A write block is no longer lifted from a partition `pgpm.archive_ledger` covers** (#452). Coverage is
  a watermark, and it describes the partition's contents only while the write block has been on it since
  the first chunk. Eligibility regresses, though: an `id` table's frontier is `max(control)`, so deleting
  the newest rows moved the horizon back, and `set_retain` loosening moved it back for every kind. The
  tick lifted the block, a late write landed in a range the ledger already called done, the block came
  back, archiving resumed from the watermark, and `retire` dropped the partition with a row in it that no
  strategy had ever been handed. Now the block stays while coverage exists: the partition keeps being
  archived to completion and is dropped only if retention reaches it again. The first tick that keeps a
  block it would otherwise have lifted logs `skip_write_block_lift` for that partition, once; to make it
  writable again, delete its `pgpm.archive_ledger` rows and the next tick lifts the block (archiving
  starts over from `lo` if it is ever blocked again). Coverage a tick finds on a partition with **no**
  block (a trigger removed by hand, or lifted by a pgpm older than this rule before an upgrade) is
  discarded and logged as `archive_coverage_reset` with the chunk count, so an in-place upgrade heals such
  a partition on its first tick instead of trusting a watermark nothing has been guarding. `tests/114`
  pins all three by identity (the `id` frontier regression, `set_retain` loosening followed by the
  documented way out, and the unblocked-coverage backstop), each ending in a drop whose contents equal
  exactly what the strategy was handed.
- **`TRUNCATE` is refused while a regrain is in flight** (#449). Change capture is a row trigger, and
  `TRUNCATE` fires none, so a truncate of the coarse child mid-regrain left the delta empty, and a
  truncate of the parent never reached the standalone copies; the swap then attached copies of every
  row the operator had just removed (9,999 rows resurrected in the hunt that found it). The prepare
  tick now puts a `BEFORE TRUNCATE` statement trigger (`pgpm_regrain_truncate_guard`) on the source
  beside the row trigger, and it raises `pg_partition_magician: cannot TRUNCATE ... a regrain is in
  flight on it` for either spelling (`TRUNCATE parent` cascades to the source as a partition and fires
  the partition's own trigger), before anything is truncated. Refuse rather than capture, matching the
  write ceiling: loud refusal over silent divergence. The guard is `ENABLE ALWAYS`, so
  `session_replication_role = replica` cannot skip it, and it goes wherever the row trigger goes: with
  the dropped source at the swap, in `regrain_cancel`, and in `maintain`'s sweep of an abandoned
  regrain. Pinned by `tests/119`, which also proves the replica-mode case discriminates.
- **Fixed: upgrading from 0.4.0 or older left two ambiguous overloads behind** (#441). `create or
  replace` across a changed argument list does not replace the old function; it adds a second overload
  beside it, and four signature changes were missing their `drop function if exists` lines:
  `restore_incoming_fks(regclass)` and `schedule(text)` (the shapes 0.2.0 through 0.4.0 shipped) and the
  two-argument `_encode`/`_decode` (0.1.0 and 0.2.0). **An install upgraded from 0.4.0 or older to
  0.5.0 or 0.6.0 has the first two today**, and the upgrade reported success: `select pgpm.schedule()`
  fails with `function pgpm.schedule() is not unique`, and every `maintain` tick logs a
  `skip_restore_fk` row with `method = 'function pgpm.restore_incoming_fks(regclass) is not unique'`,
  so a preserve-managed incoming FK is never restored and `p_status` carries `restore_fk_deferred` for
  good. **Re-running `install.sql` with this fix removes the stale overloads**: the fix is itself the
  remedy for an install already upgraded, and the next tick restores the FK. Verified from every tag
  0.2.0 through 0.5.0: the routine catalog after the upgrade is identical to a fresh install's. (0.1.0,
  the pre-transmute `adopt` release, additionally leaves its seven `adopt`-era routines behind; those
  are removed names rather than overloads, nothing calls them, and they are out of scope here.) New
  guard `bench/upgrade_from_release.sh` upgrades a real released artifact, v0.2.0's `install.sql`
  fetched from the tag, and requires routine identity with a fresh install, `schedule()` resolving, and
  one tick restoring the FK; `bench/upgrade_in_place.sh` now compares routines by name as well.
  Mutation: `upgrade_stale_overloads_kept`.
- **The archive step now holds `archive_fn` to its contract (#454).** The `covered_hi` a strategy
  returned was written into `pgpm.archive_ledger` verbatim, and that ledger is `retire()`'s drop
  precondition, so a strategy bug that answered chunk `[0, 15)` with `covered_hi = 15000` marked the
  partition fully covered on the spot and the next `retain()` dropped it with nothing archived.
  `_archive_step` now checks the returned `covered_hi` against the chunk it handed over: it must be a
  native grid value with `p_lo < covered_hi <= p_hi`. On a breach (null, at or below `p_lo`, past
  `p_hi`, or not a native value) no ledger row is written; the step logs the new `fail_archive_contract`
  action, with the strategy, the chunk, the value returned and the rule it broke in `method`, skips that
  partition for the tick, and `status().retain_drop_failures` counts it alongside the other `fail_*`
  actions that stall retention.

  The strict lower bound closes a second defect for free: a strategy returning `covered_hi = p_lo` ("no
  progress") used to write a `(lo, lo)` ledger row, after which every tick resumed from `max(hi) = lo`,
  handed the strategy the same chunk, and collided on the ledger's primary key, a permanent wedge that
  `maintain()` reported as a `skip_archive` deferral. Such a return is now refused before it reaches the
  ledger. A strategy that genuinely cannot make progress on a call should raise; that is logged as
  `skip_archive` and retried with the same chunk, which is the deferral path.

  `fail_archive_contract` is a prefixed non-success event per the naming rule, so alerts matching exact
  action values are unaffected. Unlike the identity refusals it is retryable by construction: nothing
  advanced, so a corrected strategy (`pgpm.set_archive_fn`) is handed the very same chunk next tick. The
  built-in `pgpm._archive_noop` and `pgpm_archive`'s two S3 strategies always return the chunk's own
  `p_hi` and are unaffected. One new internal, `pgpm._archive_contract_breach(kind, lo, hi, covered_hi)`,
  which returns the rule broken or null; internal, so no promise attaches to it. `tests/115` drives four
  misbehaving strategies (overshoot, `p_lo`, null, not a number) through the step and a `maintain()`
  tick, each paired with the strategy's own record of the chunk it was handed, and then a well-behaved
  one on the same chunk as the control.
- **Fixed: a primary key that excludes the control column is refused whatever other unique constraints
  the table has** (#445). `transmute` on `events(id PRIMARY KEY, created_at, UNIQUE (tenant, created_at))`
  by `created_at` used to fall through to the unique-constraint reuse: the parent adopted the UNIQUE,
  `events_pkey` stayed on the monolith, and every forward partition accepted duplicate `id`s with no
  error, notice or log row. The docs said the shape was refused; it was refused only when there was
  nothing else to adopt. It is now refused up front, before any COMMIT, with a message naming the primary
  key constraint and the control column and prescribing the widening (`CREATE UNIQUE INDEX CONCURRENTLY`,
  then `DROP CONSTRAINT ..., ADD PRIMARY KEY USING INDEX ...`); adding a unique constraint is no longer
  offered as a remedy, since it is exactly the shape being refused. Unchanged: a table with no primary
  key and a unique constraint that includes the control column still reuses that constraint, and a
  primary key that includes it is still reused in place. Pinned by `tests/113`.
- **`uninstall.sql` now removes regrain's change capture from your schema** (#442). The per-parent delta
  table, its trigger function and the `pgpm_regrain_capture` row trigger live in the parent's schema, not
  in `pgpm`, so `drop schema pgpm cascade` never reached them: after an uninstall during a regrain the
  trigger kept firing on every write to the former source child, appending to a delta table nothing would
  ever drain, and a parent that had ever regrained kept the table and function for good. The script now
  walks `pgpm.config` and drops all three for every managed parent before the schema goes, the way
  `untransmute` already did. Best-effort per parent: a parent dropped without `untransmute` is skipped, a
  parent whose capture objects the running role cannot drop is reported in a warning naming them, and a
  re-run with the schema already gone stays a no-op. The guide's uninstall paragraph now says exactly what
  goes and what stays: your partitioned tables, their partitions and every row, and nothing else pgpm
  made. The bound `CHECK` a completed `transmute` leaves is nothing, since the cutover drops it; the one
  it cannot undo, a conversion interrupted between phases, is called out with the `transmute_abort` call
  to run first. `./test.sh` stages a real regrain before every channel's uninstall check and asserts the
  trigger is present before, and no relation, function or trigger named for it after.
- **`from_hypertable_cutover` refuses to swap when the source and the destination disagree, and the
  append-only catch-up no longer loses a row that lands exactly at the watermark** (#460). Without
  `p_track_changes` the cutover caught up rows with control strictly greater than `max(control)` in the
  destination. A row arriving during the online window BELOW that watermark (out-of-order appends:
  multi-writer clock skew, batched device uploads, backfills, the normal IoT shape) was never copied, a row
  EXACTLY AT it was not copied either, and nothing under the lock compared the two sides, so the source was
  dropped short with no error and no log row. Three layers, cheapest first. On a keyed table the under-lock
  catch-up is now inclusive at the watermark with a key anti-join against the destination, bounded to the
  tail (an unbounded anti-join would be O(rows) under the lock) and materialised and ANALYZEd first so the
  plan probes the pre-built key index instead of seqscanning the destination (measured: even at 20k rows
  the direct form planned a Seq Scan of the destination); equality is never a loss and the copied row
  already there is not duplicated. A keyless table keeps the strict `>`: a duplicate row is legitimate
  there, so an all-columns anti-join would refuse to copy one. Under the lock, BEFORE the drop, `count(*)`
  over the frozen source is compared with the destination's count (its pre-lock baseline plus exactly what
  the catch-up changed, so the destination is not scanned again) and the swap is REFUSED on a mismatch with
  a message naming both counts, the difference and the fix; the raise precedes every irreversible step, so
  the source stays whole and still a hypertable. The reference now states the late-arrival caveat as loudly
  as the update/delete one and recommends `p_track_changes => true` whenever the table has a key; the
  default is unchanged, a behaviour change worth its own issue. Cost: one `count(*)` over the source joins
  the locked window, the one step in it that scales with the table. `tests/timescale/db/20` pins all three
  layers: the equal and 1 us-past rows survive by identity on a keyed table with no duplicate, and a row an
  hour behind the watermark makes the cutover refuse with `243` vs `242` (keyed) and `243` vs `241`
  (keyless), source intact. `bench/hypertable_late_appends.sh` proves both assertions discriminate against
  mutants that put the strict `>` and the missing check back.
- **A `p_incoming_fks => 'preserve'` conversion that fails after phase 1 no longer loses the incoming
  foreign keys (#444).** The cutover is where the referencing table's key is dropped now, in the same
  transaction that records it in `pgpm.dropped_fk`. It used to be dropped in the first of `transmute`'s
  three transactions, with the record written only in the third, so a stray row failing phase 2's
  `VALIDATE` (or a lock timeout in the cutover) left the key gone from the referencing table with no
  record anywhere: `transmute_abort` reported the table restored, the referencing table accepted orphans,
  and a clean re-run had nothing to restore. Now a failure in phase 1 or 2 leaves every incoming key
  exactly where it was, a failure in the cutover rolls the drop back with it, and referential integrity
  on the referencing table is off only between a completed cutover and `restore_incoming_fks`. Nothing
  in phases 1 or 2 ever needed the key gone; the drop was simply left behind when the conversion was
  split. Two things came free: the drop's wait for the referencing table's lock is now bounded by
  `p_lock_timeout` (it used to wait indefinitely, before anything was claimed), and the cutover drops
  what is live at that moment rather than a list captured at the start, so a key the operator dropped
  during the validation scan is not recorded as pgpm's to restore. `tests/112` pins the phase 2
  failure, the abort, the cutover failure under a lock on the referencing table, and the resume path.
- **`from_hypertable_copy` applies each chunk's bounds in the dimension's own type**, so a `timestamp`
  (without time zone) or `date` dimension migrates whole under any session `TimeZone` (#459). The chunks
  view renders every time dimension's `range_start`/`range_end` as `timestamptz`, and the copy spliced them
  as bare literals, which render in the session zone (`'2024-01-01 09:00:00+09'` under `Asia/Tokyo`) and,
  coerced to a `timestamp` column, lose the offset. Every chunk range shifted by the UTC offset. East of
  UTC the oldest chunk's first hours were copied by no chunk (540 of 2880 rows in the reproduction), and
  because the cutover's catch-up only reaches rows past `max(control)` in the destination, they were gone
  after the migration; west of UTC the last chunk's tail was missed by the copy and came back only through
  the catch-up; a `date` dimension lost its last day west of UTC. A `timestamptz` dimension was never
  affected. Bounds are now `::timestamptz`, `at time zone 'UTC'`, or the `::date` of that, per dimension
  type: exactly the value each chunk's own CHECK constraint names. A hypertable on any other dimension type
  is refused by the copy up front, before it creates anything, rather than bounded on a `NULL` (the view
  has no `range_start` for it, and the old predicate would have copied nothing into a destination the
  cutover would then have renamed into place). `tests/timescale/db/19` pins the `Asia/Tokyo` and
  `America/Los_Angeles` cases by row identity, with witnesses that the zone was in effect and that the view
  rendered the bounds with an offset.
- **`archive.to_s3_parquet` resolves its child in the parent's schema, and both manual archive functions
  check the child's identity** (#464). `to_s3_parquet` cast the bare child name to `regclass`, so it
  resolved through the caller's `search_path`: from a session whose `search_path` did not reach a managed
  table's schema, the real child was refused with `relation does not exist`, and once any same-named
  relation existed in `public`, that relation's rows went out under the partition's key with HTTP 200.
  `to_s3` had the schema right but, like `to_s3_parquet`, never compared what the name resolved to
  against `pgpm.part.child_oid`. Both now resolve `%I.%I` off the parent's namespace and refuse, with a
  `pg_partition_magician:` error naming both oids, a relation that has taken a partition's name: the
  manual-path twin of the automatic path's `fail_archive_identity`. A child that does not exist in the
  parent's schema fails with a clear message rather than a bare `relation does not exist`; a null
  `child_oid` is unanchored and skips the comparison, as everywhere else.
- **`from_hypertable` refuses an integer-time dimension, and a `p_control` that is not the dimension, up
  front** (#458). The chunk-by-chunk copy bounds each chunk on `range_start`/`range_end` from
  `timescaledb_information.chunks`, which are ranges of the dimension column and are populated only for a
  timestamp-typed dimension. Preflight checked only that `p_control` exists, so a `bigint` dimension copied
  `t >= NULL and t < NULL` (nothing) and the cutover dropped the hypertable before `transmute` refused the
  column, leaving an empty plain table and no hypertable; and a second time column that is not the
  dimension migrated to a partitioned table with zero rows and reported success. `from_hypertable_preflight`
  now requires `p_control` to be the primary dimension (naming the actual dimension when it is not) and the
  dimension to be `timestamptz`, `timestamp` or `date`, and `from_hypertable_cutover` runs the same two
  checks in its own right, since a destination left by a copy under an older version reaches the
  irreversible drop without preflight ever having run. `tests/timescale/db/18` pins both refusals through
  every entry point, with the hypertable intact by identity afterwards, and passes `timestamp` and `date`
  dimensions as positive controls. The retention translation's `(config->>'drop_after')::interval`, which
  would have read an integer policy's `1000` as seconds, is unreachable now that integer dimensions are
  refused before it, and is left as is.
- **`transmute` and `set_retain` refuse a negative retain** (#451). Neither `transmute` overload
  checked the sign of `p_retain`, so `p_retain => interval '-1 day'` (or `-1000` on an `id` grid)
  registered a retention horizon in the future, and the first maintenance tick write-blocked and dropped
  every partition, the one taking writes included; the next insert failed with `no partition of
  relation ... found for row`. Both overloads now raise before anything is committed, and `set_retain`
  refuses a negative value unconditionally: before, only its would-drop guard stood in the way, and that
  guard compares boundaries, so a value that grid-floored to the current boundary (retain 0 to -400 at a
  frontier of 2501, step 1000) went through and armed a later tick. Zero is unchanged and legitimate: its
  horizon is the write partition's own floor, so it keeps that partition and ages everything behind it.
  As defence in depth for a `config.retain` edited by hand, `_retain_boundary` and `regrain_step` refuse
  to compute a horizon from a negative value: a tick against such a row logs `skip_write_block` and
  `skip_retain` (and `skip_regrain`, when auto-regrain reaches it) carrying the message and drops
  nothing, `status()` stays up with `retain_backlog` null for that table, and `set_retain` can still
  repair it. A positive retain shorter than one `partition_step` is unaffected. New internal
  `pgpm._retain_nonnegative(kind, retain)`; internal, so no promise attaches to it.
- **`untransmute` decides its one-way door under the lock that acts on it (#443).** It refuses when any
  row lives outside the original monolith, and that refusal was decided once, under `ACCESS SHARE`, by a
  check that cannot see another session's uncommitted insert; the detach and drop that acted on the
  answer took their `ACCESS EXCLUSIVE` later. A writer whose insert into a forward partition was
  uncommitted at the check and committed before that lock was granted had its row dropped with the
  parent, and `pgpm.log` recorded the `untransmute` as a success. The check now runs again under an
  explicit `lock table ... in access exclusive mode`, taken one statement before the detach would have
  taken the same lock, so the exclusive window opens where it always did and grows by one probe of
  partitions that are empty whenever it passes; the unlocked check stays as the cheap refusal that blocks
  no writer when the door is already shut. The wait is bounded by the caller's `lock_timeout` and a
  refusal rolls the whole call back. Because the second answer is only worth something if its snapshot
  postdates the lock, `untransmute` now also refuses to run under `REPEATABLE READ` or `SERIALIZABLE`,
  whose snapshot predates the call. Guarded by `bench/untransmute_race.sh` (a writer parked on an
  uncommitted forward-partition insert, `untransmute` witnessed waiting on `AccessExclusiveLock` while
  that xid is still open, then released) with the mutation `untransmute_no_recheck_under_lock`, and by
  `tests/109`, which runs the same race through `dblink` in the version matrix.
- **regrain's swap now reconciles every captured change before it drops the source (#447).** After
  the `DETACH`, the swap drained the change-capture delta for at most 100 passes of
  `greatest(batch, 1000)` keys and then attached, dropped and truncated unconditionally; nothing checked
  that the loop had stopped because the delta was empty. The pre-swap gate bounds only what had committed
  before it ran: a writer already holding a row in the source keeps the `DETACH` waiting, and everything
  it commits during that wait lands in the delta after the gate. Under `maintain` the `DETACH`'s 200 ms
  `lock_timeout` keeps that window small; a hand-driven `regrain_step` has none, and a history purge
  committing during the wait was exactly the shape that overflowed. Reproduced: 150,051 committed rows,
  49,851 of them gone after a clean `swapped:30`, no error anywhere.

  The loop now runs until the reconcile finds nothing (the `DETACH`'s lock is what makes that finite),
  and before the `DROP` the swap asserts that no captured change in `[lo, hi)` remains, raising a
  `pg_partition_magician: internal error` otherwise so the whole swap rolls back with the source still
  attached; under `maintain` that surfaces as a `skip_regrain` row and the next tick reconciles the
  backlog before swapping. New internal `pgpm._regrain_delta_count(parent, lo, hi)`, the range-scoped
  count that check uses (range-scoped because a cross-partition `UPDATE`'s new key can sit outside the
  child being split). Guarded by `tests/107`, a two-session probe in which a writer commits 120,002
  captured changes after seeing the swap's ungranted `ACCESS EXCLUSIVE`, and by
  `bench/regrain_swap_reconcile.sh`, which drives that file against two mutants: the pre-fix bound put
  back (the file fails on identity, after a swap that reported success) and the bound with the new
  check left in (the file fails on the swap tick, which now raises), so the check is proven live rather
  than assumed.
- **`archive.to_s3` no longer drops rows that tie on the control column at a page boundary** (#463).
  The synchronous NDJSON export read the partition `fetch_rows` at a time and resumed each page from
  the previous page's `max(control)`. The control column need not be unique, so when a run of equal
  values straddled a page boundary the cursor landed on the tied value and the next page's `> cursor`
  skipped the rest of the run: 30 rows at one timestamp with a 10-row page came out as 10, with HTTP
  200 and no error, on the path the README offers for archiving before a manual drop. Paging is now
  by the total order `(control, ctid)`, so a page boundary can fall anywhere in a tie run and lose
  nothing. The export also counts what it pages against the partition's row count when it began and
  **refuses to write the object** on a mismatch (`pg_partition_magician: archive.to_s3 of ... paged N
  rows but the partition held M ...`), aborting an in-flight multipart upload, rather than reporting
  success; with the fix in place that check trips only when something wrote to the partition during
  the export, which is the operator's cue that the partition was not quiescent. Pinned by
  `tests/archive/db/12`, whose witness proves the first page ends inside the tie run and whose
  assertions name the previously lost rows by identity.
- **Parquet archives of a `numeric(p,s)` column with `p >= 17` encoded negative values, and positives
  of 19 or more digits, as different numbers, and every reader agreed on the wrong one (#461).**
  `archive._pq_plain_decimal` stepped its two's-complement byte loop with `trunc(v / 256)`, and
  PostgreSQL's numeric `/` rounds its quotient to about 16 significant digits, so once the running
  value had 17 or more integer digits the rounding carried into every higher byte. Every negative gets
  there at the 8-byte width `numeric(17,s)` is the first to need (its `2^(8n) + value` step has 20
  digits), so `numeric(19,4)`, the money shape, was squarely inside it: `-1.5` came back as `5.0536`,
  `-0.0001` as `0.0255` and the column maximum `999999999999999.9999` as `1000000000000000.0255`, from
  pyarrow and DuckDB alike. `numeric(16,s)` and narrower, 7 bytes or fewer, were never affected, which
  is why `scripts/verify_parquet.py`, whose widest DECIMAL fixture was 5 bytes, stayed green. The loop
  now steps with `div()`/`mod()`, exact at any magnitude, as `pgpm._radix_encode` already did for the
  same reason.

  **A Parquet file written before this fix from a `numeric(p >= 17)` column that held a negative
  value, or a positive of 19 or more digits, carries wrong values, and nothing in the file says so:**
  each wrong value is a valid encoding of some other number (`-0.0001` became the exact bytes of
  `+0.0255`), so no reader can flag it and the file cannot be repaired from itself. The repair is to
  re-archive the range from the source rows while they still exist; `pgpm.archive_ledger` lists which
  ranges went to which keys. A column of that shape that only ever held non-negative values under 19
  digits was encoded correctly and needs nothing, and NDJSON archives (`archive.to_s3`, which renders
  rows with `row_to_json`) were never affected. Pinned by `tests/archive/db/11`, which checks the
  encoder's bytes against a Python-derived two's-complement reference for five values at every width
  1..16 they fit (the width-8 row is required to be present, since widths 1..7 passed before the fix
  and pass again against it), and by three new `verify_parquet.py` fixtures (`numeric(19,4)`, `(17,2)`,
  `(38,10)`, with negatives and near-max values) read back exactly through both readers; all three
  fail against the previous encoder.
- **Both pgpm triggers now fire under `session_replication_role = replica`** (#450). The write block
  and the regrain change capture were created in PostgreSQL's default origin-only state, so a session
  running as `replica`, which is what a logical-replication apply worker runs as and what some bulk
  loaders set to silence triggers, wrote straight past both: a replica-role `INSERT` landed in a
  write-blocked partition, where archive coverage was already complete and the row would have been
  dropped unarchived, and replica-role DML during a regrain went uncaptured and was reverted, lost or
  resurrected by the swap. Both triggers are now `ENABLE ALWAYS`, asserted directly against
  `pg_trigger.tgenabled` in `tests/110`, which also shows the refusal and the capture from a
  replica-role session. **Upgrading in place:** re-running `install.sql` touches no existing trigger, so
  every write block an older pgpm installed is repaired on the first `maintain` tick afterwards, by the
  same per-child revisit that already runs every tick. A regrain already in flight across the upgrade
  keeps its origin-only capture trigger until it swaps; if a replica-role writer can touch that table,
  `regrain_cancel` it and the next tick re-prepares with the new trigger.
- **`pgpm.progress(p_parent regclass default null)`**: the drill-down `status()` is not (#343). One row
  per managed table, or one, answering the two questions that watching a production `transmute`, freeze,
  `regrain` sequence used to leave to hand arithmetic over `pgpm.part`, `pgpm.config`, `pgpm.log` and
  `cron.job_run_details`. *When will the monolith freeze?* `frontier`, `write_child`, `write_ceiling`,
  `freeze_margin`, `freeze_in`, `coarse_frozen`. *How far along is the regrain, and when does it finish?*
  `regrain_child`, `regrain_cursor`, `regrain_pct_range`, `regrain_rows_copied`, `regrain_rows_total_est`,
  `regrain_delta_pending`, `regrain_started_at`, `regrain_elapsed`, `regrain_eta`. The ETA is extrapolated
  from `config.regrain_cursor`, which already records exact, monotonic range progress, so it costs no
  scan and no per-tick timing on the hot path. That is why the issue's question of whether to instrument
  per-microbatch duration is answered no rather than deferred: an ETA never needed it.

  Three places a plausible number would have been a lie, and what was done instead. `regrain_pct_range`
  is a fraction of the RANGE and `regrain_rows_copied` a count of rows, never fused into an "N of M":
  rows are not uniform across a range, the cursor sits still until a whole sub-range completes, and an
  aged sub-range is advanced over without being copied, so the two legitimately disagree (pinned by
  `tests/106`, where 40% of the range is behind the cursor with 15% of the rows moved). `freeze_in` is
  **null for `id` grids**, whose frontier is `max(control)` with no clock and no history to make a rate
  from; `freeze_margin` carries the count instead. And `regrain_eta` is **null until there is progress**
  to extrapolate from, which is the whole of the first sub-range, even when rows have already moved.
- **`status()` gains `regrain_to`**, appended so positional readers are unaffected (#343). The auto-regrain
  target was the one field that had to be read from `pgpm.config` separately to learn whether the history
  was being split at all. `status()` is drop-and-recreate, so re-running `install.sql` picks it up.
- **New internal `pgpm._native_frac(kind, lo, hi, x)`**, the one place pgpm subtracts native grid values
  rather than comparing them. Internal, so no promise attaches to it.
- **Runbook: the lock-race deferral row is `skip_regrain`, not `regrain_skip`.** The regrain triage
  section named the suffixed form, which is exactly the shape the log-naming rule exists to forbid, and
  a reader filtering on it would have found nothing.
- The sixth gap in #343, telling a caught-error `skip_regrain` apart from a routine, self-healing
  `skip_write_block` without reading the source, is not in this change. It touches the log vocabulary
  across every action value and belongs in its own change; the issue stays open for it.

## [0.6.0] - 2026-09-23

**Upgrading in place needs no action this time.** `pgpm.part` gains `child_oid`, and unlike the
columns 0.5.0 added it is **backfilled** as part of re-running `install.sql`: through `pg_inherits`
for an attached partition, so what gets adopted is a partition of that parent by construction, and by
name for a not-yet-attached regrain child. A row whose name no longer resolves is left null, reads as
unanchored, and behaves exactly as before.

Two things will look different, neither of which is a migration step:

- **Three new `pgpm.log.action` values** -- `fail_archive_identity` (#421),
  `fail_write_block_identity` (#429), and wider use of the existing `fail_retain_identity` (#428).
  All are prefixed non-success events per the naming rule, so alerts matching exact action values are
  unaffected; all three count in `status().retain_drop_failures`, and none of them ever clears
  itself. A non-zero count where there was none means a partition's name has stopped resolving to the
  relation pgpm recorded for it, and the runbook's retention-triage section now leads with them.
- **pgpm now refuses where it previously acted.** That is the whole content of this release: four
  places resolved a partition or table by *name* and then read, dropped or replaced whatever answered,
  with nothing asserting it was the object they meant. Each now checks an oid first and stops. In a
  healthy install none of this is reachable and nothing changes.

This release closes the last of the #346 security-hardening campaign's successors. #411's
per-function time-of-check/time-of-use pass is fully worked through: #421, #428, #429 and #422.

- **`from_hypertable_cutover` locked a name and then `DROP`ped it, without verifying the oid (#422).**
  It resolved `p_hypertable` to a name pair once at the top, did a great deal of work, then
  `lock table <nsp>.<rel>`, `drop table <nsp>.<rel>`, and renamed the copy into place. `LOCK TABLE`
  freezes whatever a name means *at lock time*, so locking by name is only half the standard pattern;
  nothing re-resolved it afterwards, and the missing half is what turns a rename in the window into a
  `DROP TABLE` on a relation the procedure never identified.

  Most of that window turns out to be self-protecting, and it is worth recording which part is not. A
  rename before the cutover starts is caught by the `found no copy to cut over` check. A rename during
  the online pre-drain is caught too, but by a mechanism the issue did not name: the drain *steps*
  re-resolve the name per batch and raise `found no delta`, so the part of the window that commits
  repeatedly, and therefore looks widest, is the safest. What is left is the index pre-builds --
  explicitly the O(rows) work kept outside the lock so the outage stays brief, and so the longest
  stretch in the window, with nothing in it that re-resolves the source.

  The cutover now locks the source **by oid** (`p_hypertable::text` renders the current name of the
  relation actually passed in, so the lock lands on it even after a rename) and then requires the name
  to resolve back to it. It does the same for the **destination**, against the oid its own existence
  check resolved, and locks that too: the destination is renamed *into* the source's name, so an
  unverified one does not merely get dropped, it becomes the production table. Either mismatch aborts.

  Two limits, stated rather than implied. The destination check covers the window from the existence
  check to the swap; a destination substituted before the cutover was ever called is out of reach,
  because nothing in this module records what `from_hypertable_copy` built. And the lock could not
  simply move earlier: building the indexes outside it is what keeps the blocking window bounded by
  the catch-up rather than by the table size.

- **`_install_write_block` created its trigger on whatever answered to the name (#429).** It resolves
  the child by name and issues `CREATE TRIGGER` against the result, and `_enforce_write_blocks` calls
  it for every attached child on every `maintain()` tick -- so a relation that had taken a
  partition's name got a pgpm trigger rejecting all of its `INSERT`s, `UPDATE`s and `DELETE`s. DDL on
  a table pgpm was never handed, recorded nowhere in its own catalog.

  It is also what made #421 reachable rather than theoretical: `_archive_step`'s candidate query
  gates on `_is_write_blocked`, so a substituted name was only ever *eligible* for archiving because
  this step had made it so. Maintenance manufactured its own bad candidate. The check now lives in
  `_install_write_block` itself rather than in the reconciling loop, so a caller that does not know
  about it cannot reintroduce the defect; on a mismatch it logs the new `fail_write_block_identity`
  and returns without issuing DDL, rather than raising (which would propagate out of `retire`, and
  would be logged as a `skip_`, implying a deferral that a later tick clears -- which this is not).

  **`_remove_write_block` is deliberately left resolving by name.** Refusing to install on an
  unidentified relation is protective; refusing to *remove* is the opposite. A pre-#429 pgpm could
  already have stranded this trigger on a relation it never managed, leaving it rejecting every
  write, and an anchored removal would refuse to touch the very trigger pgpm itself wrongly created.
  Resolving by name is what lets an upgraded pgpm clean up after an older one.

  `fail_write_block_identity` is a prefixed non-success event per the naming rule, so alerts matching
  exact action values are unaffected; it counts in `status().retain_drop_failures` and, like its two
  siblings, never clears itself. No new column and no migration.

- **`retire`'s ordinary one-step `DROP` was unanchored (#428).** #407 gave `retire` an identity check
  but scoped it to the defect #407 was about: its anchor, `pgpm.part.retiring_oid`, is set only inside
  the referenced-partition branch, as `retire` dispatches a concurrent detach. For a partition nothing
  points a foreign key at -- the overwhelmingly common case -- it is null on every call, the check was
  skipped whole, and the closing `drop table schema.child` destroyed whatever answered to the name.
  `pgpm.part.child_oid` (#421) is the anchor that path was missing, since it is recorded at creation
  and so populated for every partition, and `retire` now consults it before any side effect.

  **The two anchors are checked independently, not coalesced**, and the difference is not academic:
  `retiring_oid` is itself resolved *by name*, out of `pg_inherits` at dispatch time, so a
  substitution that landed before the dispatch is adopted by that anchor and comparing the name
  against it passes forever. `coalesce(retiring_oid, child_oid)` would never reach the one anchor that
  still remembers the original. A disagreement with either refuses, and `method` names which, so a
  stale dispatch and a stale catalog row are distinguishable.

  No new action value and no new column: this reuses `fail_retain_identity`, which already counts in
  `status().retain_drop_failures` and already never clears itself. The `method` text has changed shape
  to name the disagreeing anchor; alerts matching the action value are unaffected. A null anchor is
  still not consulted, so nothing an upgrade cannot compare gets wedged.

- **The archive path carried a partition's identity as a name, with nothing anchoring it (#421).**
  `pgpm._archive_step` selects `child_name` out of `pgpm.part`, and every step downstream re-resolves
  that string on its own: the write-block eligibility test matches it against `pg_class`,
  `_next_archive_chunk` reads `schema.child` three times to size the chunk, and `archive_fn` is handed
  the bare name. Nothing asserted that the relation answering to it was the partition the row was
  written for.

  That needed no race. A name that has stopped meaning what it meant is a state pgpm already knows is
  reachable -- `pgpm.forget_missing` exists for it -- and on this path it is not read-only reporting:
  the chunk is sized from the substitute's rows, and the `pgpm.archive_ledger` row that follows claims
  coverage of a range those rows never came from. That ledger is `retire()`'s drop precondition, so the
  bogus claim opened the gate and the next `retain()` tick dropped the relation holding the name.

  `pgpm.part` gains `child_oid`, recorded where a partition *enters* the catalog (`obtain`, regrain's
  standalone child, `transmute`'s monolith) rather than at retirement the way `retiring_oid` is -- that
  one is null for every partition the archive step ever touches. `_archive_step` resolves each
  candidate's name against it before reading anything, and on a mismatch (including a name that
  resolves to nothing) logs the new `fail_archive_identity` action and skips that partition, leaving
  the rest of the batch to proceed. Nothing is read, so no ledger row is written, so coverage never
  completes and the drop precondition stays shut.

  Two notes for an upgrade, neither needing action. `child_oid` is **backfilled**, from `pg_inherits`
  for an attached partition and by name for a standalone regrain child, so an existing install is
  anchored the moment it upgrades rather than only for partitions minted afterward; a row whose name
  no longer resolves is left null, reads as unanchored, and behaves exactly as before. And
  `fail_archive_identity` is a prefixed non-success event per the naming rule, so alerts matching exact
  action values are unaffected; it counts in `status().retain_drop_failures` and, like
  `fail_retain_identity`, never clears itself.

## [0.5.0] - 2026-09-22

**Upgrading in place? Read this first.** `obtain` has moved out of `maintain()` into its own
procedure and its own `pg_cron` job (#347), and `pgpm.schedule()` is operator-invoked, so **an
existing install does not pick the new job up by installing this file**. Until you re-run
`pgpm.schedule()`, nothing extends the forward grid: `maintain()` no longer obtains at all, and
with no `DEFAULT` partition (#288) a write past the last bound is refused rather than absorbed.
`maintain_all()` detects the state and logs the new `warn_obtain_unscheduled` action once per
sweep, so it is visible rather than silent, but it does not self-heal. **Re-run
`pgpm.schedule()` right after upgrading.**

Three smaller surface changes, none of which needs action:

- `pgpm.part` gains `retiring_oid` (#407) and `pgpm.transmute_inflight` gains
  `owner_pid`/`owner_backend_start` (#405), all backfilled null. Null reads as "not anchored" and
  "no live owner" respectively, so a retirement or conversion already in flight across the upgrade
  behaves exactly as it did before.
- Two new `pgpm.log.action` values, `fail_retain_identity` (#407) and `warn_obtain_unscheduled`
  (#347). Both are prefixed non-success events, per the naming rule; alerts matching exact values
  are unaffected. `fail_retain_identity` is counted in `status().retain_drop_failures` and, unlike
  its neighbours there, never clears itself.
- `pgpm.set_regrain` now refuses a target step coarser than `partition_step` (#341), where it
  previously accepted one and produced a regrain that could not converge. A caller relying on the
  old acceptance gets an error instead of a wedge.

This release also carries five security fixes from the #346 hardening campaign, none of which
shipped in 0.4.0: #405 (an advisory-lock denial of service any connected role could trigger with
no grants at all), #406 (an unpinned publishing CLI handed a live token), plus #407, #408/#409
and #410. The campaign is closed; its two remaining findings are tracked as #421 and #422.

- **The dbdev minifier decided what a line was without knowing where it sat (#410).**
  `scripts/build_dbdev_package.sh` trims `pgpm_core/install.sql` from 329,376 chars to fit dbdev's
  250,000-char cap by dropping blank lines, full-line `--` comments and `COMMENT ON` statements. The
  `awk` that did it judged every one of those from the line's own leading characters, with no idea
  whether the line sat inside a string literal. A line beginning `--` inside a multi-line `'...'`
  literal is *data*: a statement assembled across several source lines, an example inside a `raise`
  message. Dropping it changes the SQL an operator installs from dbdev while the reviewed, committed
  `install.sql` still reads correctly, and nothing catches that, because the script's only check is
  the size ceiling and a dropped line can only help pass it.

  **#410 recorded this as dormant. Line-*dropping* was; whitespace *collapsing* was not.** The same
  blindness was already rewriting literal content in the published package, at **17 lines across
  five multi-line literals** -- among them the body of the delta trigger `regrain` generates, whose
  indentation and internal spacing were being rewritten inside the `format()` string that carries
  it. Harmless in every one of the five (the altered text lands in generated whitespace or inside a
  generated comment), which is exactly why it had never been noticed.

  The minifier is now `scripts/minify_sql.py`: one character-level scanner over the whole file
  carrying real lexical state -- single-quoted literals with `''` escapes, double-quoted
  identifiers, nestable `/* */` comments, and a stack of dollar-quote tags -- with every line's
  decision made from the state the line *starts* in. A line starting inside a literal is emitted
  byte for byte. A file that does not lex end to end (an unbalanced quote or dollar tag) is a loud
  error rather than a silent minify, and so is a run that drops no lines at all.

  Two things deliberately did not change. Comments inside `$$` bodies are still stripped: they are
  most of what the minifier removes, and #410's sketch of leaving dollar-quoted bodies alone does
  not fit under the cap. And `COMMENT ON` stripping stays, now state-aware, so a `;` inside the
  comment's own text no longer ends the statement early (the old `;$` line match did, and emitted
  the remainder of the literal as stray SQL). `\ir`/`\i` expansion is gone rather than fixed: it had
  never run against any file in this repo, so it was unverified code standing between the reviewed
  file and the published one, and a build that meets one now fails loudly.
  `scripts/build_install_bundle.sh` keeps its includes, which is a real asymmetry rather than an
  oversight -- it copies lines verbatim, where an include boundary costs nothing.

  The self-test carries a port of the old awk and requires each of its five defect fixtures to come
  out *differently* under it, so a rewrite that quietly reintroduced the blindness fails; three more
  fixtures assert the opposite, that the preserved behaviour still matches the old minifier exactly.
  Checked by pointing `minify()` at the legacy logic: the five fail, the three pass. New package is
  148,737 chars against the 250,000 cap, and `./test.sh 17 --channel=dbdev` installs it and runs the
  full pgTAP suite against it, green.

- **`bench/upgrade_in_place.sh` degraded 15 of the 25 columns it claimed to, and nothing said so
  (#417).** The guard proves that re-running `install.sql` over an existing database upgrades it
  rather than half-breaking it: it drops "every column `install.sql` backfills with `add column if
  not exists`" from a populated install, re-runs the file, and requires the result to hash-match a
  fresh oracle. `DEGRADE_COLS` is that list, and it held **15 entries against 25 backfill lines**.
  Ten backfill lines were exercised by nothing: the seven `text_time` `pgpm.config` columns
  (#334/#335), `pgpm.config.archive_batch`, and
  `pgpm.transmute_inflight.owner_pid`/`owner_backend_start` -- the last two being the columns #405's
  whole claim rests on, that a conversion whose session died stays reapable. On an upgraded install
  that backfill was unverified.

  The list's one precondition ran the wrong way. "Every LISTED column exists in a fresh install"
  catches the list naming a column the product has DROPPED, and the list was not stale in that
  direction, so it passed and reported nothing. It cannot catch the product GAINING a backfilled
  column the list forgot, which is the direction drift actually goes: every new column is an
  opportunity to forget one.

  So the guard gains a second precondition running the other way -- read the backfill lines out of
  the install file about to be run, and fail naming any that `DEGRADE_COLS` omits -- and the ten
  missing columns are now degraded. The hardcoding stays, because deriving the list from those same
  lines would make the guard circular against its own mutation, and the new check is one-directional
  for the same reason: `upgrade_no_column_backfill` DELETES a backfill line, and a missing backfill
  *line* is not a missing *list entry*, so the check still passes under that mutant and the
  catalog-hash assertion is still what fails it. Confirmed by running it, not assumed. The converse
  check ("every list entry has a backfill line") would fail under that mutant for a reason that is
  not the defect, and is deliberately absent.

  The new precondition has a mutation of its own, `upgrade_degrade_list_drift`: it gives
  `install.sql` a backfilled column the list does not name, and the guard has to fail on that
  precondition, by name. It is the first mutation here whose modelled defect lives in the guard
  rather than in the product, the product being moved only because that is the one way to reproduce
  it. The parse carries its own liveness witness: the loose match is case-insensitive and the strict
  one is not, so a backfill line written in a style the parser cannot read surfaces as a loud count
  mismatch instead of a line the check silently does not cover.

  The same defect one level up turned out to be sitting in `.github/workflows/perf.yml`, and is
  fixed with it: its path filter enumerated the guards it covers, and four of the thirteen the perf
  track runs were not on it. `bench/upgrade_in_place.sh` was one, so a change to the very file this
  entry is about triggered no perf job at all on its own. The filter matches `bench/*.sh` now, which
  is a shape rather than a list and so cannot fall behind.

- **`bench/restore_fk_lock.sh` stops racing a 4 ms window, and its liveness witness can now fail
  (#416).** The guard polled `pg_stat_activity` until it saw `restore_incoming_fks` active and only
  then began writing. Measured on PG 17.11 against its own fixture, the fixed restore takes
  **4.4 ms** -- it is one `ADD CONSTRAINT ... NOT VALID`, and `NOT VALID` does not scan -- so the
  probe was trying to catch a 4 ms window by polling. It missed intermittently, wrote nothing, and
  reported `at least one write landed inside it got false` against perfectly good code. Exactly the
  instrument-versus-window mistake CLAUDE.md records.

  Worse, the witness that was supposed to stop "no timeouts" from passing vacuously was itself
  vacuous: `saw := true` sat *after* the spin loop, so it was set whether the loop found the restore
  or exhausted two million iterations having seen nothing, and `"the probe overlapped a running
  restore"` could not fail.

  The race is now gone rather than tuned. A gate makes the ordering structural -- the probe starts
  writing and announces itself, the restore does not begin until that lands, and the probe does not
  stop until it finishes -- so the probe's write span *contains* the restore by construction and
  nothing has to be caught. Each attempt and the restore both record the interval they occupied, and
  the guard requires a genuine interval overlap, which also catches an attempt that began before the
  window and blocked into it. That the new witness CAN fail was checked rather than assumed: against
  a deliberately sabotaged copy whose probe never overlaps, it reports `0 of 300 attempts overlapped`
  and fails -- while "writes are not blocked" passes, which is the vacuous green the old guard
  reported as success. Fixed code 5/5 with 22-32 overlapping attempts; the
  `restore_fk_inline_validate` mutation still fails it (221.8 ms restore, 4 timeouts).

- **A retirement now knows WHICH relation it is retiring, not just its name (#407).** Retiring a
  partition an incoming foreign key references needs `ALTER TABLE ... DETACH PARTITION ...
  CONCURRENTLY`, which PostgreSQL refuses to run from a function, a procedure, a `DO` block or a
  dynamic `EXECUTE` -- so pgpm dispatches it to pg_cron as command text and completes the `DROP` on a
  later tick. A command text can only name a relation; there is no way to write an oid into it. The
  cron session therefore re-resolves `schema.child` a tick or more later, with no lock held on the
  partition across the interval, and had no way to notice that the name had come to mean something
  else. That is the same time-of-check/time-of-use shape as the `SPLIT`/`MERGE PARTITION` finding
  that motivated the whole #346 audit -- a name decided now, re-resolved and trusted by something
  else later -- and it ended in a `DROP`.

  pgpm cannot close the window, because the reason the statement is dispatched at all is that
  PostgreSQL will not let pgpm hold anything while it runs. So `pgpm.part` gains `retiring_oid`,
  recorded in the same transaction as the dispatch, and `retire` checks it at the top of every later
  call -- before the write block, the crossing `DELETE`, the re-dispatch or the `DROP`, so no step
  can touch a substitute. Two facts have to agree, since either alone is forgeable: the name
  resolves, and it resolves to that oid. When they do not, `retire` logs the new
  `fail_retain_identity`, returns the standing `pgpm_detach` job to idle and does nothing else. The
  detach can still land on a substitute; the destructive half cannot, which is the half worth
  anchoring. `status().retain_drop_failures` counts the refusal alongside `fail_retain_drop`,
  `fail_retain_crossing` and `fail_retain_detach`, because it wedges retention the same way -- and
  unlike those it never clears itself, so it is a wedge an operator has to look at.

  Three smaller changes fall out of the same reading. `_dispatch_detach` now takes the child as a
  `regclass` and renders both relation names from oids, so the text that lands on `cron.job` can only
  name relations the caller resolved in its own transaction. The standing job is returned to idle
  BEFORE the `DROP` rather than after it: the armed window was never one cron interval, it lasted
  until the drop SUCCEEDED, and a drop that kept failing left a stale name armed and re-firing
  indefinitely. And `_idle_detach_job` takes the command it expects to find, so the wedge above --
  which revisits it on every tick for as long as it lasts -- disarms only its own dispatch instead of
  clobbering another parent's on every tick; both it and `_dispatch_detach` build that text through
  the new `pgpm._detach_cmd`, so arming and disarming cannot drift. Both changed signatures are
  dropped explicitly, since `create or replace` can change neither a parameter's type nor its
  arity, and the old copies would otherwise stay installed and resolvable beside the new ones.

  `tests/77_retain_incoming_fk_test.sql` builds the substitution in the only shape that matters --
  the impostor is a genuine partition of the same parent under the same name, so the dispatched
  detach succeeds on it -- and drives both refusals, with liveness witnesses for the recorded oid,
  the impostor's different oid, and the impostor actually being attached. Every assertion there is a
  negative, so `bench/retire_detach_substitution.sh` runs the same file against an arbitrary copy of
  the module and the `retire_drop_unanchored_name` mutation deletes the identity check, which
  `./test.sh discriminate` requires the file to FAIL against. Measured: the mutant loses seven
  assertions, including the one that finds the substitute dropped. `retiring_oid` is added with `add
  column if not exists` and reads null for a retirement already in flight across the upgrade, which
  is treated as unanchored and behaves exactly as it did before rather than wedging mid-flight.

- **A `_q` suffix now marks every already-quoted SQL fragment, and CI keeps the mark honest
  (#409).** Several functions build a comma-joined fragment out of `quote_ident`'d pieces and then
  splice the whole fragment with a bare `%s` -- correct, since `%I` over an already-quoted string
  double-quotes it into garbage, but indistinguishable at the call site from a raw identifier
  someone forgot to `%I`. A later edit could swap one for the other in any of these functions and
  nothing would read as wrong.

  Applied to all 31 sites rather than the three #409 cited: `_regrain_reconcile` and
  `from_hypertable_drain_delta_step` were only the most visible copies, and a suffix on 3 of 31
  would have made the other 28 read as "not pre-quoted". (#409's third site,
  `_pq_to_parquet_range`'s `v_order_by`, is not among the 31 because it no longer exists: #408
  turned it into a `name[]` the encoder quotes itself, which is the stronger answer wherever it is
  available. A marker is for the fragments that have to stay fragments.) The sweep also turned up
  sites nobody had listed, including `regrain_step`'s `v_pkjoin_q` (a `format('d.%I = s.%I', ...)`
  join predicate), `transmute`'s `v_pdef_q` (a whole CREATE INDEX statement), and
  `from_hypertable_cutover`'s
  `v_pseq_q` (a `pg_get_serial_sequence` result, quoted by Postgres and spliced with `%s`).

  `scripts/check_quoted_splices.py` (CI's `Quoted splices` lint job) enforces it in both
  directions: a quote-derived `text` local must carry the suffix, and a suffixed one must be
  assigned from something that actually quotes, so the name cannot outlive its value. It carries a
  `--selftest` over embedded fixtures that requires each check to FAIL against its own defect, and
  a floor on how many quoting assignments it must find, so a parser that has stopped reading the
  module fails instead of reporting a clean sweep of nothing. Only `text` locals are considered,
  which is why it parses the DECLARE block: `format('%I.%I', ...)::regclass` quotes identifiers on
  its way to an OID, and an OID is not a fragment anyone can splice wrong.

- **No parameter of `archive._pq_encode_column_data` carries SQL any more (#408).** It was the one
  place among the 166 `execute format(...)` sites the #346 audit covered where a `text` parameter
  reached the executed statement through a bare `%s` with no quoting at all: the whole FROM item
  (`p_from_sql`) and the whole ORDER BY list (`p_order_by`), twice each, in every one of the seven
  type branches. Nothing untrusted ever reached it -- `_pq_to_parquet` passed a `%I`-quoted
  `schema.table` and the literal `'ctid'`, and `_pq_to_parquet_range` passed a `quote_ident`-joined
  key list and a `%I`/`%L`-built subquery -- so this closes no live hole. What it closes is where the
  guarantee lived: entirely in the two callers, so the function promised nothing on its own and a
  third caller written later would have inherited nothing.

  The relation now arrives as `p_schema`/`p_table` and the range as `p_control`/`p_lo`/`p_hi`, both
  of which go to the new `archive._pq_from_item` to be `%I`/`%L`-quoted; the ordering arrives as
  `p_order_by name[]` and is `quote_ident`'d element by element inside the function. There is no
  longer a parameter a caller can paste SQL into, so a future caller cannot route around it. Both
  entry points also build their `count(*)` FROM item through `_pq_from_item`, which is now the only
  place in the module that builds one.

  `tests/archive/db/10_encode_boundary_test.sql` drives a statement-terminator payload through every
  one of those parameters. Its `p_table` payload is deliberately self-completing -- it closes the
  SELECT, drops a victim table, and supplies a third statement returning the `(boolean[], bytea)`
  pair the `EXECUTE ... INTO` needs -- because the obvious payload leaves an unterminated identifier,
  and a statement that fails rolls back the very drop it was meant to prove, which would have made
  "the victim table survived" pass against vulnerable code too.

  That those assertions discriminate is now a standing check rather than something checked once by
  hand: `bench/archive_encode_boundary.sh` runs the same pgTAP file against an arbitrary copy of
  the module, and two mutations put each half of the defect back (`archive_from_item_raw_splice`
  weakens `%I` to `%s` in `_pq_from_item`; `archive_order_by_raw_splice` drops `quote_ident` from
  the ORDER BY build), so `./test.sh discriminate` requires the file to FAIL against both. The
  first takes the victim table with it; the second turns the payload into a syntax error instead of
  a quoted column name. The signature is pinned by the test and the old 7-arg arity is dropped
  explicitly, #209's gotcha being that `CREATE OR REPLACE` would otherwise leave the SQL-taking
  version installed beside the new one.

- **`docs/reference.md` described an `obtain` that has not existed since #288.** Its closing paragraph
  called `obtain` "a procedure, not a function", said it took "an advisory lock per parent" so a second
  concurrent call "defers instead of interfering", and said it reported failures through `p_deferred`.
  All three were false: `obtain` is `function pgpm.obtain(p_parent regclass) returns int` (as the
  section's own signature block, three paragraphs above, said correctly), there is no advisory lock
  anywhere in `pgpm_core/install.sql`, and no `p_deferred` parameter exists. Removed rather than
  rewritten -- the paragraphs above it already describe the real early-stop and lookahead behavior, so
  it left no gap.

- **`transmute` no longer claims a conversion with a session advisory lock (#405).** The claim was keyed
  on `hashtextextended('pgpm_transmute:' || oid)` -- a formula published in `install.sql`, over an oid
  anyone can read out of `pg_class` -- and advisory locks carry no ACL of any kind. Any role that could
  merely CONNECT could therefore take it, with no grant on any pgpm function and no privilege on the
  table. Two consequences, the second much worse than the first: holding it pre-emptively blocked every
  `transmute()` of that table outright, and grabbing it the instant a crashed conversion released it
  starved `_transmute_reap` forever, because the reaper decided "still running" by trying to take that
  same lock. That second one had no way out at all -- `transmute_abort`, the documented manual escape
  hatch, consulted the same lock and refused too -- so a crash could be turned into a permanent outage,
  with the table's `pgpm_monolith_bound` CHECK rejecting every write outside `[lo, hi)` indefinitely.

  `pgpm.transmute_inflight`'s existing primary key on `parent_table` is now the exclusion itself: one row
  per table, taken by a single atomic `insert ... on conflict do update`, in a pgpm-owned table carrying
  no GRANTs, so an unprivileged role cannot take or hold it at all. Liveness -- still the thing that has
  to tell "running" from "its session died", with no heartbeat and no timeout guess -- comes from the
  claiming session's identity, recorded in two new columns (`owner_pid`, `owner_backend_start`).

  The subtlety that decided the implementation, found by measuring rather than reasoning: `backend_start`
  is **masked for a backend owned by another role**, reading NULL rather than its real value (measured on
  stock PostgreSQL 17.10: an unprivileged role sees the row and its `pid`, but `backend_start`,
  `backend_type` and `query` all read NULL). The reaper runs from pg_cron under whatever role scheduled
  it, which need not be the role that ran `transmute`, so the obvious predicate
  `backend_start = owner_backend_start` evaluates to NULL for a perfectly live cross-role conversion --
  and the reaper would then have undone it out from under itself, dropping the bound and deleting the
  claim mid-validation-scan. `pgpm._session_alive` therefore DEGRADES instead: pid and `backend_start`
  where that column is visible, pid alone where it is not. The residual failure is under-reaping (a
  recycled pid looks live, leaving an abandoned bound for an operator's `transmute_abort`) and never
  over-reaping a live conversion. Same discipline #98 established for the ambient sensors: read what
  every role can see, never a column `pg_monitor` masks.

  Guarded by `bench/transmute_claim_squat.sh`, which drives a real second-session squatter against the
  old key and asserts -- with a liveness witness that the squat is genuinely in place, on the right key,
  from a session that is not the claim's owner -- that the reaper and `transmute_abort` both work anyway.
  Its mutation (`transmute_claim_advisory_reap`) restores the advisory-lock recovery paths and the guard
  fails against it. `tests/101_transmute_claim_test.sql` pins the claim's state machine and the liveness
  predicate. Upgrades in place: the two columns are added with `add column if not exists`, and a claim
  recorded before they existed reads as having no live owner, so it stays reapable rather than becoming
  stuck behind a check it has no data for.

- **The lock-trace guard now runs in CI (`.github/workflows/locktrace.yml`, #383 phase 3 / #389).**
  Until now nothing in CI ran that track, so off Linux it was verified by nobody. A spike on a hosted
  runner settled the three questions that had kept the workflow unwritten, by measurement rather than
  argument: BCC compiles and attaches on `ubuntu-latest` (kernel `6.17.0-1022-azure`) and the guard
  passes there, including failing against its mutant; headers matching `uname -r` are already present,
  so there is no drift to work around and no source build; and the whole job takes 132 s, of which the
  image build is 91 s, which is why it carries no build cache. The job asserts the header requirement
  up front so that losing it later is a legible failure rather than an opaque BCC compile error, and
  runs a single `./test.sh locktrace`, since that track already runs the guard and requires it to fail
  against the defect. `./test.sh ci`'s skip notice and `CLAUDE.md` now say CI covers the skip, which
  before this they could not truthfully say.

  Running it in CI immediately earned its keep by failing, on a defect in the instrument rather than
  in pgpm, and that failure ended with **pg-lock-tracer being abandoned entirely**. It emitted every
  lock event for the whole server through a PER-CPU perf buffer and formatted each one as JSON in
  Python: ~120,000 events per tick to deliver about ten facts. Two consequences followed from that one
  design choice. Per-CPU buffers deliver out of order across CPUs (measured: 4 inversions in 101,185
  events, two of them statement markers, which moved a boundary 53,000 positions and silently shrank
  the window under test to almost nothing), and the Python consumer could not keep up, so the buffer
  overflowed -- opened with no `lost_cb`, discarding events in complete silence (measured: 4,150 lost
  in one run, the guard reporting a lock as never released while the commits in the same interval
  proved it had been).

  `bench/lock_probe.py` replaces it: ~40 lines of BPF C we own, probing `LockRelationOid` and
  `CommitTransaction` and filtering by relation oid and backend IN THE KERNEL, so dozens of events
  reach userspace instead of ~120,000. It uses `BPF_RINGBUF` rather than `BPF_PERF_OUTPUT` -- one
  shared buffer, so records arrive in order and nothing needs sorting, and `ringbuf_reserve()` fails
  visibly when full, so the probe counts its own drops in the kernel and the guard asserts that count
  is zero. A truncated stream can no longer masquerade as a complete one. The image drops
  pg-lock-tracer, four Python libraries and the script that patched its source in two places; only
  `python3-bpfcc` and version-pinned debug symbols remain. The release path is deliberately not
  probed: `UnGrantLock` takes a struct pointer, so reading a relation oid from it would mean
  depending on field offsets that shift between PostgreSQL versions, whereas
  `LockRelationOid(Oid, LOCKMODE)` passes scalars. A commit releases the lock, so the commit is the
  honest signal.

- **Lock boundaries are now OBSERVED, not inferred, by a new `./test.sh locktrace` track (issue #383,
  phases 1 and 2).** Every lock guard in `bench/` proves "the lock was released before the next slow
  step" indirectly: a concurrent reader under a short `lock_timeout` either times out or does not.
  Cheap and portable, but it cannot see a lock it did not happen to collide with, and it cannot say
  which boundary released one. `bench/lock_trace.sh` attaches
  [pg-lock-tracer](https://github.com/jnidzwetzki/pg-lock-tracer) uprobes to the running server and
  asserts the thing itself: between the last `AccessExclusiveLock` grant on `mg_ret`'s parent and the
  first lock event on `ml`'s parent, there is an ungrant (the release) and a `TRANSACTION_COMMIT` (the
  `#265`/`#279` boundary). Measured on correct code: 2 releases and 7 commits in that interval; against
  the mutant, zero of each while every liveness witness still passes. The track runs the guard and its
  mutation together in about 50 seconds. It is a supplement, not a replacement: the reader-probe guards
  stay as the fast, portable first line, and `./test.sh discriminate` is unchanged and still runs
  anywhere. `./test.sh ci` runs the track on Linux and reports it as `SKIPPED`, never folded into the
  `PASS`, on anything else; the condition is the kernel alone, so a Linux box that cannot actually
  trace FAILS rather than skipping, on the rule that a guard which never ran is unverified. eBPF needs
  a privileged container and the host's own kernel headers, which Docker Desktop for Mac cannot
  provide. (`bench/lock_trace.sh`, `bench/skip_fastpath_probes.py`,
  `bench/mutations/mutate.py`'s `maintain_no_commits_trace`, the `locktrace` compose service,
  `Dockerfile`'s `WITH_LOCK_TRACER`)

  Two findings worth keeping. The trace JSON is written in perf-buffer DELIVERY order, not time order:
  4 inversions in 101,185 events, two of them the statement markers themselves, which moved
  `maintain_all()`'s `QUERY_BEGIN` 53,000 events away from its real position and silently reduced the
  window under test to almost nothing. Sort by `timestamp` first. And that failure was caught by the
  guard's liveness witnesses rather than its ordering assertion, which held vacuously over the empty
  window -- the exact shape `CLAUDE.md` exists to prevent, arriving from a direction nobody had
  anticipated.

- **`maintain_obtain()` no longer lets its back-off outlast the forward grid.** One lost `lock_timeout`
  race sets a 30-second `config.obtain_retry_after` back-off, and obtain was skipped for all of it, however
  little grid was left. That was harmless while a `DEFAULT` partition caught writes past the grid; since
  #288 such a write is refused. A local load test at ~42k ids/s against a 3-partition lookahead (~14 s)
  lost one race and every client aborted with `no partition of relation ... found for row`. The back-off
  is now honored only while at least `ceil(obtain / 2)` complete grid steps of attached coverage remain
  beyond the frontier's own grid cell; below that, obtain runs anyway (status note
  `obtain_backoff_bypassed`). Coverage, not partitions: grid inside a monolith widened by
  `p_bound_headroom` counts, so such a table does not retry obtain's `ACCESS EXCLUSIVE` every tick while
  it still has room. The count runs only while a back-off is active. (tests/100, bench/obtain_backoff_headroom.sh)

- **Leftovers from the `DEFAULT`/drain removal (#288) cleaned out of `pgpm_core/install.sql`.** Two
  error messages named machinery that no longer exists: `pgpm.schedule()` without `pg_cron` told you to
  call `drain_all`, and now points at `maintain_all()`/`maintain_obtain_all()`; `transmute`'s orphan-table
  refusal blamed an "interrupted drain" and now says "interrupted regrain", matching the runbook. Also
  removed: `regrain()`'s unreachable `default_dirty` branch and about a dozen unused adaptive-feathering
  variables in `maintain()`; comments that still described the drain now describe regrain.

- **`obtain` split out of `maintain()`/`maintain_all()` into its own procedure and its own `pg_cron`
  job (issue #347).** `maintain_all()` loops over every managed table sequentially in one session,
  calling `maintain()` for each; a slow `archive`/`retain`/`regrain_step` for one table used to delay
  `obtain` for every table after it in the same tick, purely because of loop order. Every other step
  degrades gracefully if delayed; only `obtain` turns "ran late" into "writes started failing," since
  there is no `DEFAULT` partition (#288) to catch a write past the forward grid. `pgpm.maintain_obtain(p_parent,
  inout p_status)` and `pgpm.maintain_obtain_all()` now carry `obtain` on their own, and
  `pgpm.schedule()` takes a second, independent cadence parameter, `p_obtain_every` (default
  unchanged), registering a new `pgpm_obtain` job alongside the existing `pgpm` and `pgpm_detach`
  ones; `pgpm.unschedule()` removes all three. `pgpm.obtain()` itself, and `maintain_all()`'s
  structure, are untouched. `maintain()`'s returned status string no longer includes `obtained=`
  (unchanged: `pgpm.log`'s `obtain`/`skip_obtain` action values, which now originate from
  `maintain_obtain()` instead).
  **Upgrade hazard:** `schedule()` is operator-invoked, never automatic -- an installation that
  already called it before upgrading past this change will NOT pick up the new `pgpm_obtain` job on
  its own, and `obtain` will silently stop running until the forward grid runs out and writes start
  failing. **Anyone with an existing `pgpm.schedule()` must re-run it after upgrading.**
  `maintain_all()` also logs a `warn_obtain_unscheduled` row to `pgpm.log` once per sweep as a
  backstop for anyone who misses this. (tests/31, tests/78)

- **`pgpm.set_obtain(p_parent, p_obtain)` and `pgpm.set_retain(p_parent, p_retain default null)`
  (issue #326).** `obtain`/`retain` were settable only at `transmute` time; changing either
  afterward meant a raw `update pgpm.config`, with no validation and no test coverage -- the only
  other `update pgpm.config set obtain/retain...` anywhere was the internal backoff writer.
  `set_obtain` refuses a negative `p_obtain`, which would otherwise silently and permanently disable
  lookahead (`obtain`'s `for k in 0 .. cfg.obtain` loop never runs when `cfg.obtain < 0`). `set_retain`
  validates `p_retain`'s shape against `control_kind` the same way `transmute` does (`numeric` for
  `id`, an interval otherwise), and -- since `retain` is the destructive knob that decides what
  `retain()` `DROP`s -- **refuses**, not merely warns, whenever the new value would make the very
  next `retain()` tick drop a partition the *old* value still kept. Loosening (a bigger
  interval/count, or `null` = keep forever) can never trip that refusal. (tests/97, tests/98)

- **`pgpm.extend_to(p_parent, p_value, p_max default 10000)` pre-extends the forward grid past
  `obtain`'s lookahead ceiling (issue #290).** Since #288 removed the `DEFAULT` partition, `obtain`'s
  `config.obtain x partition_step` lookahead is the only thing standing between a write and `no
  partition of relation ... found for row`, and for an `id` grid the frontier is data-driven and can
  jump past it with no recovery path: a sequence restart, a non-dense Snowflake/ULID generator, a
  bulk import, a backfill. `extend_to` is the relief valve -- name a value you know is coming and it
  builds every missing partition on the existing grid up to and including the one that would hold it,
  without moving the frontier or touching data. It never partially extends: the number of new
  partitions needed is checked up front, before any DDL, and a target needing more than `p_max`
  (default 10000) is refused loudly rather than silently stopping short. Idempotent; returns how many
  partitions it actually created.

- **`set_regrain` now refuses a target step coarser than `partition_step` (issue #341).** Accepting
  one used to silently wedge auto-regrain forever: `maintain()`'s auto-regrain candidate query
  calls a child "coarse" whenever it is wider than one `partition_step` (hardcoded, not
  `regrain_to`), while `regrain_step`'s own `'nosubdiv'` guard refuses to split a child already at
  (or narrower than) the configured target. With `regrain_to` coarser than `partition_step`, a
  coarse child got split down to `regrain_to`-wide pieces exactly once; those pieces were still
  wider than `partition_step`, so the candidate query kept reselecting the same now-unsplittable
  child every tick, forever, with nothing raised and no log signal beyond the routine no-progress
  status. `set_regrain` now rejects a coarser target at call time instead. Equal-or-finer targets
  are unaffected -- every existing call site in this repo (`README.md`, `docs/guide.md`,
  `docs/runbook.md`, all five tests, all three bench scripts) already passes one. The one-off
  manual functions, `pgpm.regrain()` and `pgpm.regrain_history()`, are untouched and remain fully
  general: `docs/runbook.md`'s disk-pressure workflow deliberately regrains to a step coarser than
  the final grid through those, and it is single-shot, not a perpetual tick loop, so it never hits
  this failure mode.

## [0.4.0] - 2026-09-08

**Upgrading in place? Read this first.** This release adds `config.archive_batch`, backfilled onto
every existing managed table with a default of `1`. If you currently rely on `_archive_step`
fanning out across every eligible partition in one `maintain()` tick (the only behavior earlier
versions had), that default silently makes archiving strictly sequential -- one partition at a
time -- immediately after upgrading. Set `archive_batch = null` for any table where you want to
keep the old unbounded behavior; see [Byte-budget chunked
archiving](docs/reference.md#byte-budget-chunked-archiving) for the tradeoff. Everything else in
this release is additive or a pure bug/doc fix with no behavior change for an existing install.

- **One partition's lock timeout no longer stalls write-blocking (and regrain-capture cleanup)
  for every other eligible partition that tick (issue #360).** `_enforce_write_blocks` and
  `_enforce_regrain_capture` each looped over every eligible child with no per-iteration exception
  handling, so a lock timeout (or any other failure) on any single child raised out of the whole
  loop, leaving every other child that tick -- lock-contended or not -- untouched. Since `retain`
  only drops a child once it is write-blocked, this could turn one recurring point of lock
  contention into a compounding retention backlog. Fixed by isolating each child's attempt in its
  own exception scope (a failure now logs `skip_write_block` / `skip_regrain_capture`, attributed
  to that child's own `hi`, and the loop moves on) and adding `order by hi asc` to
  `_enforce_write_blocks`'s cursor so forward progress always prioritizes the oldest, most overdue
  partitions first, matching `_archive_step`'s existing convention. Verified directly: a
  deliberately "poisoned" middle child (its underlying table dropped out from under an
  otherwise-normal `pgpm.part` row) no longer prevents children before *or* after it from being
  correctly write-blocked -- against the old code, the same fixture failed to block even the
  oldest eligible child, since the old query had no ordering guarantee at all.

- **Docs: corrected a stale comment describing `obtain`'s `lock_timeout` rationale (issue #361).**
  The comment justifying `obtain`'s 200ms lock timeout in `maintain()` described the pre-#288
  `ADD CONSTRAINT`/`VALIDATE` exclusion-constraint dance against a `DEFAULT` partition -- a
  mechanism issue #288 removed. Rewritten to describe what `obtain` actually does today (a single
  `CREATE TABLE ... PARTITION OF`, taking `ACCESS EXCLUSIVE` on the parent itself and scanning
  nothing). No behavior changed; the timeout value itself is unchanged.

- **Docs: `p_bound_headroom` permanently delays regrain eligibility, undocumented (issue #342).**
  Headroom widens the monolith's upper bound `hi` before the bound `CHECK` is added in `transmute`'s
  phase 1, and that same `hi` becomes the monolith's permanent, attached partition bound at cutover
  (Postgres's zero-scan `ATTACH PARTITION` requires the validated `CHECK` to exactly imply the
  attached bound, so there is no cheaper way to widen the transient write-ceiling protection alone).
  `regrain_step`'s frozen precondition is a whole-child test against that same `hi`, so headroom
  sized to cover a write-ceiling window lasting seconds to minutes also delays regrain eligibility
  for the entire monolith by the same number of grid steps. Documented in both `docs/reference.md`'s
  `p_bound_headroom` parameter description and `docs/guide.md`'s transmute walkthrough; no code
  changed.

- **Docs: sizing `archive_byte_budget` (issue #354).** Added a "Sizing `archive_byte_budget`:
  there is no single optimal size" subsection to [Byte-budget chunked
  archiving](docs/reference.md#byte-budget-chunked-archiving) -- the four considerations that pull
  in different directions (the DEFLATE compression window's 32 KB floor, the `statement_timeout`
  ceiling, query-engine pruning being file-level only, and per-file overhead), a sizing method
  (tie the budget to a meaningful partition boundary, measure real per-row cost rather than assume
  it, prefer `archive_batch` over `archive_byte_budget` for throughput), and why the ~1 GiB
  in-memory ceiling documented in `pgpm_archive/README.md` isn't the one that actually binds.
  Linked from [docs/guide.md](docs/guide.md#archiving-before-a-drop) too.

- **S3 archive uploads no longer break on a table name that needs quoting.** `archive._encode_upload_ndjson_single`/`_encode_upload_parquet` build their S3 key from `p_parent::text`, which Postgres renders with a literal `"` for any identifier that needs it (mixed case, a reserved word) -- a Prisma-style `PascalCase` table, for one. That quote rode straight into the request path unencoded: the canonical request used for SigV4 signing diverged from what actually went out over the wire, and every upload failed `403 SignatureDoesNotMatch`. Fixed by `archive._s3_encode_path`, applied to the S3 key in both signer functions (`archive.s3_signed_request`/`s3_signed_request_bytea`): percent-encodes each path segment via the existing `archive.s3_url_encode`, while leaving `/` alone as the path separator, matching AWS's own S3 canonical-URI rule.

- **Regrain no longer stalls on a table's outgoing foreign key (issue #348).** A fine child is created
  via `like ... including constraints`, which never copies a `FOREIGN KEY` (no `LIKE` option does), so
  every fine child reached the swap's `ATTACH PARTITION` with no matching constraint at all. PostgreSQL
  then validated the parent's outgoing FK for that partition from scratch, inside the `ATTACH`
  statement, under whatever lock it already holds and with no timeout of its own -- in production this
  reached the session's `statement_timeout` outright and the swap never completed. Fixed by giving each
  fine child its own outgoing FK, added and validated while the child is still empty (the same moment
  the bound `CHECK` is added), so the scan costs nothing and the swap's `ATTACH` adopts the
  already-validated constraint instead of re-scanning -- the same adoption `transmute` already relies on
  for the monolith. Measured: attaching a 90,000-row partition with the FK pre-validated took 0.69ms;
  the identical attach without pre-validating took 16.9ms for the same row count. Guarded by
  `bench/regrain_outgoing_fk_lock.sh` (`./test.sh perf`), with a paired mutation
  (`regrain_no_outgoing_fk` in `bench/mutations/mutate.py`) so `./test.sh discriminate` proves the
  guard actually catches the regression.

- **Parquet column encoding is no longer O(n^2) (issue #353).** `archive._pq_encode_column_data`
  built each column's data page by growing a `bytea` (or, for `bool`, a `boolean[]`) one row at a
  time with `:=`/`||` inside a PL/pgSQL loop -- every append reallocated and copied the entire
  accumulated buffer, costing O(n^2) total for n rows, regardless of `archive.config.compress`
  (this ran identically either way, before compression ever saw the result). Rewritten to derive
  both the column's null bitmap and its encoded bytes with real SQL aggregates
  (`string_agg`/`array_agg` over `unnest(...) with ordinality`), mirroring the pattern this file
  already used correctly elsewhere for list/array encoding. Verified byte-for-byte identical output
  against the prior implementation across all eight supported types, both nullable states, and
  empty/single-row/all-null/all-present edge cases (40 cases, zero mismatches). Measured: encoding
  a 100,000-row text column dropped from 22.96s to 189ms (~121x), and scaling from 100K to 500K
  rows is now close to linear (4.9x for 5x rows) rather than the ~29.5x it was.

- **Chunked archiving now paces itself across partitions, not just within one (issue #351).**
  `_archive_step` used to loop over every write-blocked, not-yet-covered partition on every
  `maintain()` tick with no cap -- fine when one new partition becomes eligible per rollover
  interval, but a single tick's duration scaled with the size of the archiving *backlog* the moment
  a bulk regrain or backfill left many partitions eligible at once, which could itself cross
  `statement_timeout` regardless of how conservatively `archive_byte_budget` was tuned. New
  `config.archive_batch` (default `1`; `null` = unbounded) caps how many different partitions one
  call touches, oldest first -- the same shape as `retain_batch`, but a different default:
  `retain_batch`'s unlimited default is safe because `DROP TABLE` is cheap and constant-cost
  regardless of volume, while archiving a partition is a real read, encode, and (with compression
  on) CPU-bound pass. Defaulting to `1` makes archiving strictly sequential: one partition fully
  archived, and so retirable, before the next is even touched.

- **Parquet archival supports PostgreSQL enums and arrays (issue #339).** Enums are written as UTF-8
  strings, while arrays are written as JSON-tagged strings that preserve null arrays, empty arrays,
  null elements, multidimensional values, and element escaping. Both whole-table and automatic
  range archival use catalog type metadata, so schema-qualified and mixed-case enum names work.

## [0.3.0] - 2026-08-26

- **`uuidv7`'s forward frontier no longer stalls on a data drought (issue #325).** Every other kind's
  frontier is either the clock (`time`) or bounded by it (`id` has no clock, so it cannot fall behind
  where the next write goes). `uuidv7` was the one exception: gridded against plain `max(control)`, with
  no clock in it at all. A table whose writes went quiet for longer than `obtain x step` -- a restored
  dump, a stale clone, a table that simply stopped being written to -- had that frontier stuck wherever
  the data ended while `now()` kept moving. `obtain` then measured itself against its own past output,
  found nothing to do, and every write past the stalled grid was refused, permanently and silently: no
  `fail_*`/`skip_*` log event distinguished the tick from a healthy one.
  - Fixed by gridding `uuidv7` against `greatest(max(control), now())`, in **both** places that compute
    it: `_frontier_native` (what `obtain`/`maintain`/`regrain_step` use every tick) and `_transmute`'s
    separate inline duplicate (the initial monolith bound, computed before `pgpm.config` exists to call
    the shared function). Fixing only one leaves the other stuck at the data-only value, opening a
    partition gap between the monolith's frozen edge and `obtain`'s now()-anchored forward grid on the
    very next tick.
  - `bench/frontier_drought.sh` reproduces the issue's own repro (a table backfilled 13/11 months stale,
    `p_obtain => 2`) and drives three separate maintenance ticks, matching the issue's own "across five
    ticks, nothing changes" observation but showing it now stays fixed instead. Verified via
    `./test.sh discriminate` against the `frontier_data_only` mutation, which reverts both sites.
  - `docs/pilot.md`'s uuid preflight section, added while this was still open, is retired: there is
    nothing to check before converting now.

- **A fourth control kind, `text_time`, for opaque sortable TEXT ids** -- classic `cuid`, KSUID, ULID
  stored as text, and MongoDB `ObjectId`, none of which fit `time`/`id`/`uuidv7`. The shape is declared,
  not detected: a constant prefix, a fixed character width, a radix, a time unit, and (for formats that
  need them) a custom digit alphabet, a bit-discard count, and a non-Unix epoch --
  `p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit`/`p_tt_alphabet`/`p_tt_discard_bits`/`p_tt_epoch` on
  `transmute`. `pgpm.check_text_time` (the `check_uuidv7` analogue) samples a column against the declared
  shape to gate the conversion, the same way `check_uuidv7` gates `uuidv7`; `p_force_text_time`
  overrides. Ready-to-use parameter recipes for all four formats are in the
  [user guide](docs/guide.md#pick-the-kind).
  - Motivated by a real production id shape: a customer's `cuid()`-generated TEXT primary key, verified
    empirically (order-monotonicity and value-closeness against a companion timestamp column, and a
    check for incoming foreign keys) before choosing to partition on it directly rather than widen the
    key or drop it.
  - ULID and KSUID needed more than cuid and ObjectId did. ULID uses Crockford's base32 (deliberately
    skips I/L/O/U), not the plain `0-9a-z` convention -- `p_tt_alphabet` overrides it. KSUID base62-encodes
    its *entire* 160-bit payload (a 32-bit timestamp plus 128 bits of random) as a single number against
    a non-Unix epoch (`2014-05-13 16:53:20+00`) -- the timestamp is the top 32 bits of a wider decoded
    value, not a separate substring, which is what `p_tt_discard_bits` and `p_tt_epoch` are for. Every
    alphabet and epoch value was verified against the format's own source (`segmentio/ksuid`,
    `ulid/spec`, MongoDB's BSON reference), not assumed from the name.
  - `_radix_decode`/`_radix_encode` (the base-N codec `text_time` is built on; PostgreSQL has none built
    in) widened from `bigint` to `numeric`, since KSUID's whole-payload value overflows a 64-bit bigint
    by close to 100 decimal digits. Building the KSUID case surfaced a real arithmetic bug at that scale:
    digit extraction used `floor(v_n / p_radix)`, and PostgreSQL's general numeric division computes a
    non-terminating quotient to a *bounded* number of decimal digits -- exact enough at cuid's ~12-digit
    scale, silently wrong (occasionally negative "digits") at KSUID's ~48-digit scale. Fixed with exact
    integer `div()`/`mod()`, verified with a round trip at real KSUID scale.
  - Inherits the `uuidv7` frontier fix above from day one: `_frontier_native` and `_transmute`'s inline
    duplicate both grid `text_time` against `greatest(max(control), now())`. Confirmed the hard way
    during development that generalizing only the shared function reproduces the exact partition-gap
    defect the `uuidv7` fix closed, since `_transmute`'s copy is a separate site that does not call it.
    `bench/frontier_drought.sh` proves the drought-immunity property for `uuidv7` and `text_time`
    independently rather than inferring one from the other, for exactly that reason.

- **The pilot playbook (`docs/pilot.md`) split rung 0 into correctness and concurrency, and gained a
  field apparatus for the second half.** An idle restored clone proves a conversion is correct but
  cannot prove it is online -- "no reader or writer was blocked" is trivially true where there are none.
  Rung 0a now covers correctness on an idle clone; rung 0b needs a live writer and reader across the
  conversion, and now has one: `bench/pilot_workload.sql` generates a self-consistent workload from a
  target table's own catalog (copying an existing row with the control column overridden, so every
  `NOT NULL`, FK and `CHECK` holds by construction), and `bench/transmute_online.sh` is the field
  instrument that drives a live conversion under it and asserts no writer was blocked or even queued.
  Verified on a 3M-row table: 9/9 assertions pass against real `install.sql` and fail correctly against
  the `transmute_no_commits` mutant.
  - The rung 0a/0b split also surfaced the `uuidv7` idle-clone gap that became issue #325, and the doc's
    reset-between-runs section was rewritten from measurement rather than reasoning: on a real
    point-in-time restore, `cron.job`'s scheduler resumes about one second after the database becomes
    reachable, immediately re-applying whatever retention pass the restore had just undone. The fix is
    to take the reset point with pgpm **paused**, verified with a controlled pair of restores (resumed
    vs. paused) on the same project.

## [0.2.0] - 2026-08-20

- **An installed database can say what it is: `pgpm.version()` and `pgpm.installed`.** There was no way
  to ask a database which pgpm was in it. The only version string lived in `extension.control`, which the
  `install.sql` channel never reads, so a database installed that way carried no version at all and every
  support conversation started by guessing.
  - `pgpm.version()` returns the semver triple, baked into `install.sql` at release time.
    `RELEASING.md` makes it the same string as `extension.control`'s `default_version` and the git tag.
  - `pgpm.installed` records one row per `install.sql` run, with the version and the full
    `server_version`. It is a history, not a current-version row, because re-running `install.sql` *is*
    the upgrade path for this channel. The `insert` is deliberately the **last statement in the file**,
    so a row for version V means the V run reached the end rather than dying partway: `psql -f` gives
    each statement its own transaction unless called with `--single-transaction`.
  - One honest limit: an install predating the table records its first row as the version it was
    upgraded *to*. The history can only start where the table does.

- **`bench/upgrade_in_place.sh`: the in-place upgrade was never tested at all.** `install.sql` is the
  upgrade path, and a new column reaches an existing database only if the file also carries an
  `alter table ... add column if not exists` line for it. There are fourteen such lines, all
  hand-maintained, and nothing enforced them. Add a column to a `create table` body, forget the backfill
  line, and every existing install comes out missing it.
  - The whole pgTAP suite is blind to this by construction: it installs **fresh**, one database per file,
    so it never upgrades anything. The break lands only on operators who already had pgpm installed,
    which is to say only on the ones who are not evaluating it.
  - The guard installs, degrades the database to an older shape by dropping all fourteen columns,
    re-runs `install.sql`, and requires the result to be catalog-identical to a fresh install of the
    same code, with its managed table's rows intact by identity and its registration unchanged.
  - Two liveness witnesses, because every assertion in it is of the form "the upgrade restored X" and
    all of them pass against a degrade that silently did nothing. First: the columns really are absent
    after the degrade. Second: `maintain()` still mints a partition afterwards, named, since a
    structurally perfect install that can no longer obtain is not an upgrade anyone wants.
  - The fixture is id-kind rather than time-kind, and that is load-bearing: `obtain` measures a time
    table against the **clock**, so nothing the harness inserts can give it work to do. For an id table
    the frontier is `max(control)`, which the harness moves on purpose. It moves it to one below the last
    bound, since with no DEFAULT partition (#288) an insert past the newest bound is rejected rather than
    extending the grid.
  - Mutation `upgrade_no_column_backfill` deletes the `obtain_retry_after` backfill line and the guard
    fails against it, catalog mismatch first and then `record "cfg" has no field "obtain_retry_after"`
    out of `maintain` itself. Wired into `./test.sh perf`, verified by `./test.sh discriminate`.

- **`RELEASING.md`, `SECURITY.md`, `docs/pilot.md`.** Project mechanics that had no written form.
  `RELEASING.md` states what a version number covers (the callable surface, the config tables, the
  `pgpm.log.action` values, the supported PostgreSQL majors), the pre-1.0 policy and the bar for
  spending `1.0.0`, the release steps and two traps in the existing tag pipeline, and the
  install.sql-is-the-upgrade-path rule for contributors. Cadence anchored to PostgreSQL's release
  calendar, and the deprecation policy, are recorded there as an explicit TODO rather than invented now.
  `SECURITY.md` gives a private report route and scope, and states the properties a reviewer would
  otherwise have to infer: no `SECURITY DEFINER` anywhere, no superuser requirement of pgpm's own, and
  identifiers quoted through `format(%I)` or `quote_ident()` in dynamic SQL. `docs/pilot.md` is the
  template for an early production install: what it does not promise, the exposure ladder, the kill
  switch and what a stopped pgpm actually leaves behind, and the two health queries an operator needs.

- **`transmute` refuses a colliding `<index>_pgpm` name up front instead of failing mid-cutover
  (issue #311).** It recreates each carried secondary index as a partitioned index on the new parent named
  `<original>_pgpm`, then attaches the monolith's original under it. Nothing checked that name was free.
  - A pre-existing relation by that name made the `CREATE INDEX` fail with a raw `42P07` from inside the
    cutover: `relation "q_p_idx_pgpm" already exists`, no `pg_partition_magician:` prefix, no guidance,
    and no hint that the remedy is `drop index ..._pgpm`.
  - **The operator was not left where they started.** The cutover is one transaction, so no data was lost,
    but phases 1 and 2 had already committed. Measured with a bare `CALL` against pre-fix code: a
    `pgpm.transmute_inflight` row and a live `pgpm_monolith_bound` `CHECK` remained on the table, and that
    `CHECK` goes on refusing every write outside `[lo, hi)` until someone runs `transmute_abort`.
  - Every sibling shape already refused up front with the remedy (a key excluding the control column, a
    bare unique index, an un-carryable `UNIQUE` secondary, a transition-table row trigger, an orphaned
    child table). This was the one hole in that contract. The new check names every collision at once,
    since one per retry would make an operator with several re-run the conversion once per index.
  - `tests/83` records something worth knowing about the other refusal tests too: `throws_ok` is a
    function, and a committing procedure cannot commit inside one, so a refusal that happens *after*
    phase 1's `COMMIT` cannot be asserted with it -- the call dies at the commit with `2D000` and never
    reaches the defect. Only the first assertion discriminates; the rest characterise the post-fix
    contract, and the file says so rather than letting them read as proof.

- **`transmute` no longer downgrades `GENERATED ALWAYS AS IDENTITY` to `GENERATED BY DEFAULT`
  (issue #308).** The conversion moves identity from the original table to the new parent, and re-added it
  unconditionally as `BY DEFAULT`, so an `ALWAYS` column came back `BY DEFAULT`.
  - **It is a write-path change, not a catalog cosmetic.** `ALWAYS` *rejects* an insert that supplies the
    column unless the statement says `OVERRIDING SYSTEM VALUE`; `BY DEFAULT` accepts it. The downgrade
    therefore silently began accepting writes the operator's schema was written to refuse, with no error,
    no `pgpm.log` row, and nothing in `status()`. The first evidence is a row that should not exist.
  - The identity **kind** is now captured alongside the column (`pg_attribute.attidentity`, `'a'` or
    `'d'`) and replayed in the same form, in `transmute` and in `untransmute`, so a round trip is stable
    in both directions rather than stable because both ends were flattened. `untransmute`'s "transmute
    already normalises ALWAYS -> BY DEFAULT" fidelity note goes with it.
  - `tests/82` asserts the **behaviour**, not the flag: the supplied-value insert must still fail with
    `428C9`, `OVERRIDING SYSTEM VALUE` must still work, and an ordinary insert must still generate. A
    catalog assertion on `attidentity` would pass against code that set the flag without restoring the
    semantics. It opens with a liveness witness proving the fixture really has `ALWAYS` in force *before*
    the conversion, and closes with a `BY DEFAULT` control so the fix cannot over-correct in the other
    direction. Verified to fail against pre-fix code (assertions 2, 5 and 6) and pass against the fix.
- **`transmute` no longer waits indefinitely for a lock (issue #309).** It takes `ACCESS EXCLUSIVE` twice
  on the operator's live table -- phase 1's `ADD CONSTRAINT`, phase 3's `RENAME` -- and set no
  `lock_timeout` on any phase, while `maintain` has applied one at every boundary since #279.
  - **The wait was the hazard, not the lock.** Both locks are brief. But a *pending* `AccessExclusive`
    request blocks every lock request queued behind it, including plain `SELECT`s that conflict with
    nothing currently running, so one long-running query turned transmute's wait into an outage of the
    whole table, with nothing to break it.
  - New `p_lock_timeout` on both public overloads, `'5s'` by default, applied at each of the three phases
    (re-applied per phase, since `set local` does not survive a `COMMIT` -- the caution `maintain` already
    records at its own boundaries). One setting covers every wait in the cutover, which is one
    transaction: the `RENAME`, and the outgoing-FK re-add's `SHARE ROW EXCLUSIVE` on each *referenced*
    table (#263), which queues behind writers there rather than on the table being converted.
  - A bad value is refused before anything is committed, rather than from inside phase 1 or, far worse,
    phase 3 -- after the operator has already waited through the `O(rows)` validation scan. The check
    restores the previous setting, so validating the parameter does not double as applying it.
  - **Adding the parameter changed the argument count**, so `install.sql` now drops the prior arities of
    `pgpm.transmute` (both overloads) and `pgpm._transmute` first. `CREATE OR REPLACE` does not replace
    across a different arg count even when the new parameter has a default, so without the drops a
    re-install over a prior one would leave both arities defined and every existing call site ambiguous.
    That is #209/#210 exactly.
  - Guarded by `bench/transmute_lock_timeout.sh` (a second session holds a conflicting lock; the
    conversion must fail with `55P03`, leave nothing behind, and -- the liveness witness -- succeed once
    unblocked), with a `transmute_no_lock_timeout` mutation that strips the per-phase `set_config` and
    requires the guard to fail. The mutation deliberately leaves the parameter in the signature: a mutant
    that removed it too would fail the guard's `CALL` with `42883` and look like a catch for the wrong
    reason. `tests/81` covers the parameter's own contract, which the shell guard cannot: the up-front
    refusal, that it leaves no inflight row or bound `CHECK`, and that the caller's `lock_timeout` is
    unchanged afterwards.

- **`transmute` no longer silently stops enforcing an outgoing foreign key (issue #263).** A foreign key
  follows the table it is defined ON, and the conversion renames the original aside to become the monolith
  child, so the constraint landed on the monolith and never on the new parent.
  - **The loss was partial, which is what made it dangerous.** The key kept enforcing for rows routed into
    the monolith, and only rows in a FORWARD partition escaped. Measured before the fix: an insert
    referencing a row that does not exist was accepted into `ev263_p0000000000000030000`, with no error and
    nothing in `pgpm.log`. The obvious post-conversion check ("is my foreign key still there?") passed,
    because the constraint genuinely existed; it was simply scoped to one partition.
  - The captured definitions are now re-added at the parent inside the same transaction as the attach, so
    no session ever observes the parent without its keys. Replayed verbatim from `pg_get_constraintdef`, so
    composite keys, referential actions and `DEFERRABLE`-ness come along without pgpm reasoning about them.
  - **It is metadata-only.** PostgreSQL adopts a partition's equivalent already-validated foreign key
    rather than rescanning: measured at **0.8 ms against a 200,000-row monolith**, with the parent
    constraint ending up `convalidated` and the monolith's demoted to a child.
  - **A `NOT VALID` outgoing key is refused**, with the `VALIDATE CONSTRAINT` remedy. Over one of those the
    same `ADD` scans: `seq_tup_read` +400,000 at 200k rows, and 89 ms at 2M, holding SHARE ROW EXCLUSIVE on
    the table and on the referenced table. That is the data-coupled blocking lock the project's acceptance
    rule forbids, and validating on the operator's behalf would either fail on rows they never checked or
    silently promote a constraint they deliberately left unvalidated.
  - Self-referential keys are untouched here on purpose: `confrelid = p_parent` makes them **incoming** as
    well, so `p_incoming_fks` has already decided their fate (verified: such a table hits the incoming
    refusal).
  - `tests/80_transmute_outgoing_fk_test.sql`, 11 assertions, opening with a liveness witness that the
    plain table enforced the key BEFORE the conversion. Verified to fail against pre-fix code, where the
    forward-partition orphan is accepted and the row count comes out one too high as a result.

- **Deleted the adaptive-feathering surface (issue #304).** #288 removed the drain and, with it, the AIMD
  controller that paced it against WAL rate, checkpoint pressure and ambient IO/lock waiters. The machinery
  that *measured and reported on* it survived, analysing a signal nothing emits.
  - Gone: `_wal_sustainable_bps`, `_feather_congested`, `_ambient_lock_waiters`, `_ambient_io_latency`,
    `_ambient_io_surge`, `_ambient_congested`, `_ambient_surge`, `_forced_checkpoints`, `_aimd_next`, and
    the public `pgpm.feathering_validation` -- 295 lines, every one with zero call sites. Dropped via
    `drop function if exists` in the upgrade path, as `install.sql` already does for the fourteen removed
    `config` columns.
  - `observe_window` loses `drains`, `adaptive_ticks` and the per-signal `backoffs` columns, and
    `rows_moved` becomes `rows_copied`. They counted `drain_move` / `drain_budget` log actions, neither of
    which has been written since #288, so they could only ever read 0. **A reported zero that means "this
    never happens" is worse than no column, because it looks like a measurement.** `impact_report` loses its
    feathering line for the same reason; both functions otherwise stay and remain useful.
  - **CI was keeping it green by manufacturing its input.** `tests/65` and `tests/observe/db/with_pgfr_test.sql`
    each inserted synthetic `drain_budget` rows and then asserted the analysis read them correctly. Those
    assertions were true and useless: they proved the *analyser* worked, not that anything *emitted* the
    signal, so a green suite said nothing about whether the feature existed. Both now exercise real regrain
    and retention actions instead.
  - `tests/41` keeps the claim that never depended on the sensors (no pgpm function reads cross-role
    `wait_event`, so pgpm needs no `pg_monitor`) and gains one asserting the whole sensor family is gone.
  - **`bench/run.sh` was already broken**: its observe poll read `pgpm._ambient_lock_waiters()` and
    `config.drain_ambient_baseline`, a function and a column `install.sql` had already removed, so the poll
    errored rather than reporting. Its dead samples and the adaptive-feathering summary are gone, and
    `bench/run_ambient_demo.sh` is deleted -- it configured knobs that no longer exist to demonstrate a
    capability that no longer exists. `bench/plot_results.py` is untouched: it renders figures from stored
    run CSVs, which are history and still render.
  - `scripts/check_living_docs.sh` gained the newly-removed identifiers, and immediately found four
    documents still naming them (`README.md`, `docs/guide.md`, `docs/reference.md`, `bench/README.md`) --
    the guard doing exactly the job it was added for in #300.

- **`from_hypertable` no longer loses the migrated table's foreign keys (issue #264).** Outgoing keys went
  silently; incoming keys failed outright, after the entire online copy had run.
  - **Outgoing, silent loss.** `CREATE TABLE ... LIKE ... INCLUDING CONSTRAINTS` copies CHECK and NOT NULL
    only -- no `INCLUDING` option copies foreign keys -- nothing later added them, and the cutover dropped
    the source hypertable, the only relation still holding them. Measured before the fix: the constraint
    count went to 0 and an orphan row was accepted. Now each definition is replayed verbatim
    (`pg_get_constraintdef`, so composite keys, referential actions and `DEFERRABLE` come along) on the
    private copy as `NOT VALID`, validated there in its own transaction, and re-added at the new parent
    after the handoff.
  - **Validated on the copy, adopted at the parent.** A validating `ADD CONSTRAINT ... FOREIGN KEY` holds
    SHARE ROW EXCLUSIVE on the *referenced* table for the whole scan, so the `O(rows)` work is done in the
    copy phase where such work belongs, not in the cutover, whose pre-build shares a transaction with the
    swap. The parent-level add is then metadata-only, because PostgreSQL adopts a partition's equivalent
    already-validated key. **Carrying it onto the copy alone is not enough**: measured, that leaves the key
    enforcing over the monolith's range only, and an orphan routed into a forward partition was accepted.
  - **Incoming, hard failure.** An FK pointing at the hypertable puts a constraint on every chunk, so
    `drop table <source>` was refused -- and only after the whole copy, leaving the populated destination
    orphaned behind the rollback. The cutover now captures and drops those keys (which is what unblocks the
    drop) and they are re-added against the new parent after the handoff via `pgpm.dropped_fk`, reusing the
    core's `restore_incoming_fks` / `validate_incoming_fks` rather than duplicating the
    `NOT VALID`-then-`VALIDATE` dance.
  - **The residual window is stated, not hidden.** Referential integrity is off on the referencing table
    from the cutover's drop until the re-add, bounded by the swap plus one `transmute`, and surfaced by
    `status().fks_suspended`. Re-adding inside the cutover is impossible: `transmute` refuses a table that
    still carries an incoming key.
  - **Two new preflight refusals**, both before any copying: an outgoing key that is `NOT VALID` (replaying
    it would either fail validation on rows the source never checked or silently upgrade the constraint),
    and an incoming key that references anything other than the key pgpm will reuse. The second is the one
    that matters most, since the alternative is discovering it after hours of copying.
  - Tests: `tests/timescale/db/16_from_hypertable_foreign_keys_test.sql` (12 assertions, including
    enforcement in a forward partition -- which fails against a fix that carries the key onto the copy but
    never re-adds it at the parent) and two added to `01_preflight_refusals_test.sql`. Whole track green at
    114 assertions.

- **A uuidv7 grid can no longer produce a partition with `lo > hi` (issue #299).** A UUIDv7 carries its
  timestamp in the leading 48 bits, so the grid it can express stops at `2^48 - 1` ms after the epoch:
  `10889-08-02 05:31:50.65504+00`. Past that, `to_hex` returns 13 hex digits and **`lpad(..., 12, '0')`
  truncates rather than pads**, silently dropping the high nibble, so a LATER timestamp encoded as a
  SMALLER uuid:

  ```text
  _ts_to_uuid(ceiling)        -> ffffffff-ffff-0000-0000-000000000000
  _ts_to_uuid(ceiling + 1 ms) -> 10000000-0000-0000-0000-000000000000
  ```

  Monotonicity is the one property every bound-computing caller assumes. Losing it silently produced
  partition bounds with `lo > hi`, surfacing much later as PostgreSQL's `empty range bound specified for
  partition` -- an error naming neither the cause nor the ceiling.
  - **`_ts_to_uuid` now refuses** (`datetime_field_overflow`) instead of truncating. Fixed at the root, so
    no caller can receive a non-monotonic bound. The inverse needs no guard: a uuid's leading 48 bits
    cannot exceed the 48-bit maximum, so `_uuid_to_ts` always returns a representable timestamp and only
    stepping *forward* off the end is possible.
  - **`transmute` refuses up front** when the monolith's own upper bound `B` -- the grid boundary above the
    frontier -- cannot be expressed, leaving the table untouched. **`p_force_uuidv7` does not override
    this**: that override exists to let an operator vouch for a column the *sampling* misjudged, not to
    request a bound no uuid can carry. In practice it catches the same random-UUIDv4 column the sampling
    check does, from the other side.
  - **`obtain` exits cleanly** when the grid runs out rather than raising, so a table that legitimately
    advances toward the ceiling keeps working with a shorter lookahead. Deliberately not logged: obtain
    runs every tick and the condition is permanent, so logging would bury real failures under identical
    rows -- and a write past the grid is already refused loudly by PostgreSQL.
  - `tests/39_uuidv7_refused_test.sql` goes from 5 to 11 assertions and **stops being a CI flake**. It had
    asserted that `p_force_uuidv7` converts a random-uuid column; whether that blew up depended on how
    close to the ceiling the run's random maximum landed. The ceiling case now uses a crafted
    top-of-range fixture, and a new deterministic year-1990 fixture keeps the override's real remit
    covered (samples implausible, grid ordinary). Verified across 12 independent runs with fresh
    `gen_random_uuid()` data.
  - **`bench/maintain_lock.sh`: probe `lock_timeout` 1 s -> 150 ms.** Against its own mutant this guard
    scored exactly **1** timeout -- a margin of a single observation, because one attempt costs one
    timeout and only one or two fit in the blocked window. The `obtain` change above shifted timing by
    milliseconds and flipped it to 0, so `./test.sh discriminate` correctly reported the guard as
    non-discriminating. At 150 ms the same window is ~12 observations wide (measured: 8 against the
    mutant, 0 against real code) while staying ~150x above obtain's own ~1 ms lock window.

- **`pgpm.status()` no longer returns nothing when a managed table was dropped without `untransmute`
  (issue #296).** `pgpm.config.parent_table` is a `regclass` and carries no dependency on the relation, so
  a plain `DROP TABLE` on a managed parent left the config row pointing at an oid with no `pg_class` entry.
  `regclass::text` then rendered the bare oid, which `_frontier_native` interpolated into a `FROM` clause:

  ```text
  ERROR:  syntax error at or near "17379"
  LINE 1: select t.id::text from 17379 t order by t.id desc limit 1
  ```

  Because `status()` loops every config row and raised out of the whole set-returning function, **one**
  dropped table meant `status()` returned nothing at all -- for every managed table, healthy ones included.
  Dropping a managed table is off-contract, so the state is self-inflicted; what made it worth fixing is
  that the *diagnostic* was the thing that broke. Maintenance kept running (its per-step handlers absorb
  the error) and logged `skip_obtain` / `skip_write_block` / `skip_retain` every tick forever, each giving
  a syntax error as the reason, while the one tool that would explain it returned zero rows.
  - Trigger, measured and narrower than it looks: only `id`/`uuidv7` kinds reach the failing `EXECUTE`
    (`time` returns `now()` before it), and only when `config.retain` is set (otherwise `_retain_boundary`
    short-circuits first). Both conditions are ordinary.
  - **`_frontier_native` now refuses legibly**, naming the cause and the remedy instead of letting
    PostgreSQL blame a syntax error on an integer. Checked there rather than in each of its four callers,
    so `obtain`, `_retain_boundary`, `regrain_step` and `maintain` all inherit the real message. This
    deliberately sits *before* the `control_kind` branch, so a `time` table no longer sails past it to fail
    less legibly further downstream.
  - **`status()` gains `parent_missing boolean`** and reports such a row instead of dying on it.
    Everything else in the row still comes from pgpm's own catalog, so a dead parent gets a full, useful
    row; only `retain_backlog` is null, since the horizon is derived from `max(control)` read from the
    relation and there is no honest answer without it (`0` would read as "nothing is eligible", a claim
    `status()` cannot make).
  - **New `pgpm.forget_missing()`**, returning `(parent_oid, partitions_forgotten, orphan_tables)`. It
    takes **no argument** on purpose: the relation is gone so there is no name to pass, and with no
    argument it can only ever match rows whose relation is already absent, so by construction it cannot
    touch a live managed table. Not an automatic reaper -- silently deleting pgpm state would trade a loud
    failure for a silent one.
  - **It drops nothing.** A *detached* partition survives its parent's `DROP` still holding its rows
    (measured on PG 17.10), and "detached, not yet dropped" is exactly the state a referenced partition's
    retirement sits in between the cron detach and the completing drop (#268). Those tables are reported by
    name in `orphan_tables` and left in place; destroying data as a side effect of a cleanup command would
    be the worst possible reading of "forget". `pgpm.log` is left intact as the audit trail it is.
  - A second, quieter reason to clear a stale row: `pg_class` oids are recycled, so leaving one is a
    standing chance of pgpm eventually believing it manages an unrelated table that lands on that oid.
  - Tests: `tests/79_status_survives_dropped_parent_test.sql` (26 assertions), including the orphan case
    against a genuinely detached-then-orphaned partition, and a new runbook entry.

- **Retention now reclaims a partition an incoming foreign key references (issue #268).** `p_incoming_fks
  => 'preserve'` and a `retain` policy were both supported and both documented, and the combination never
  reclaimed anything: every `retain()` failed on the oldest eligible partition and returned 0, forever,
  while `retire()` had already installed the write block. The partition ended up frozen **and**
  unreclaimable -- no writes in, no storage back -- for the life of the table.
  - `DROP TABLE <partition>` is refused on a pure **catalog** dependency, and the refusal is
    data-independent: identical whether one row references it, zero rows do, or the referencing table is
    empty. `retire()` now DETACHes first, which severs the per-partition constraint and leaves the drop
    unguarded. The referencing table's own foreign key survives and still enforces. **Do not** take
    PostgreSQL's `HINT: Use DROP ... CASCADE` here: that drops the constraint and keeps the data,
    silently removing referential integrity across the whole referencing table.
  - The detach must be `CONCURRENTLY`. Measured on PG 17.10 against an 8M-row referencing table, plain
    `DETACH` holds `AccessExclusiveLock` on the **managed parent** for ~1.5 s and a concurrent read of it
    dies with `55P03`; `CONCURRENTLY` holds only `ShareUpdateExclusive` and the parent stays readable and
    writable. Retention must not block the table pgpm exists to keep online, for a duration set by a
    table pgpm does not own.
  - PostgreSQL refuses `DETACH CONCURRENTLY` from a function, a procedure that has already committed, a
    `DO` block, and dynamic `EXECUTE` -- it is a check on execution context, and pgpm is pure SQL. So
    `retire()` **dispatches** it: `pgpm.schedule()` now also creates a standing, idle `pgpm_detach`
    cron job, `retire()` rewrites its command in place (a cron command runs as a top-level statement in
    its own session, where the statement is legal), and a later call completes the `DROP` and returns the
    job to idle. **Retiring a referenced partition therefore requires `pgpm.schedule()`**; if you
    scheduled pgpm before this change, re-run it once to create the second job.
  - **The crossing** -- a live row genuinely referencing a doomed one -- is executed, not decided. pgpm
    issues `DELETE FROM <parent> WHERE <crossing keys>` and lets PostgreSQL apply whatever the operator
    declared in the foreign key: `CASCADE`, `SET NULL` and `SET DEFAULT` proceed, `NO ACTION` and
    `RESTRICT` refuse and block retention with the constraint's own error (`fail_retain_crossing`). There
    is no new knob, because the foreign key already is the policy. Identifying the crossing runs first
    and unconditionally: measured at 0.7 ms indexed and 141.9 ms unindexed, against a *failing* detach's
    1176 ms unindexed -- a near-full scan under `ShareLock` paid only to learn it cannot proceed.
  - **`pgpm._detach_reap()`**, called from `maintain_all` before the per-parent loop alongside
    `_transmute_reap`. A backend killed during a concurrent detach's *wait* phase leaves the partition
    flagged `pg_inherits.inhdetachpending` with its rows **already invisible through the parent**
    (measured: a 2,000,000-row parent read 1,000,000) -- rows vanishing from the user's table, which is
    strictly worse than the wedge this fixes. It `FINALIZE`s unconditionally but drops nothing:
    `retire()` completes pgpm's own retirements (it can tell from the new `pgpm.part.retiring_at`), and an
    operator's interrupted hand-run detach is finished and then left alone.
  - **At most one detach is in flight database-wide.** There is a single standing job, so a second
    dispatch would overwrite the first and abandon it. `retain()`'s batch loop walks every eligible
    partition and `maintain_all` walks every managed parent, so this is the ordinary path, not a race:
    without the guard one `retain()` call marked a whole three-partition backlog as retiring while only
    the last dispatch was real. A retirement stops holding the job the moment its partition is detached,
    so this yields rather than blocks -- the next tick takes the next partition. It yields only to a
    strictly **older** in-flight retirement, on a total order: "yield to any other" deadlocks, because
    two concurrent `retire()` calls can both pass the check before either marks, after which each sees
    the other and neither proceeds again. `retiring_at` is therefore set with `coalesce` and never
    refreshed by a retry -- re-stamping would make the winner perpetually the newest marker and collapse
    the order back to nothing.
  - New: `pgpm.part.retiring_at`, `status().retain_detaching`, log actions `retain_detach` /
    `retain_crossing` / `detach_reap` and failures `fail_retain_detach` / `fail_retain_crossing` (both
    counted in `status().retain_drop_failures`, since both wedge retention the same way).
  - `retire()` and `retain()` stay **functions**. `cron.alter_job` called from a non-committing function
    inside a transaction takes effect at commit, so no transaction boundary is required -- and the marker
    and the dispatch then commit atomically, leaving no window where a detach is in flight unrecorded.
  - Guarded by `bench/retire_detach_lock.sh` (the managed parent stays readable *and* writable across a
    referenced partition's retirement) with a `retire_inline_detach` mutation that swaps the dispatch for
    an in-process plain `DETACH`; `./test.sh discriminate` requires the guard to fail against it. The
    mutant is functionally identical -- the partition still ends up detached and dropped, and every
    behavioural test still passes -- so nothing but a lock probe distinguishes them.
  - Tests: `tests/77_retain_incoming_fk_test.sql` (the state machine, the crossing under both `CASCADE`
    and `NO ACTION`, the FK still enforcing afterwards, the reaper against a genuinely interrupted
    detach) and `tests/78_retain_detach_dispatch_test.sql` (the cron handoff; runs against `postgres`
    like `tests/31`, since `pg_cron` only installs there).

- **Parquet writer: add `uuid`, `json`/`jsonb`, and `numeric(p,s)`.** Six supported types
  becomes nine. `uuid` encodes as `FIXED_LEN_BYTE_ARRAY(16)` (the raw bytes `uuid_send()` already
  gives, no logical-type annotation -- readers get fixed-size binary, not a typed UUID).
  `json`/`jsonb` reuse the existing text-encoding path verbatim, tagged `ConvertedType.JSON`
  instead of `UTF8`. `numeric(p,s)` is a real Parquet DECIMAL: a scaled-integer, two's-complement,
  big-endian encoding sized to the column's own declared precision (`archive._pq_decimal_byte_width`
  computes the minimal byte width for any precision Postgres allows). Bare, unconstrained `numeric`
  (no declared precision/scale) is refused with a clear error -- Parquet DECIMAL needs one fixed
  precision/scale for the whole column, and Postgres's bare `numeric` can vary per row. Arrays and
  composite types remain out of scope (real nested/repeated-schema support, a materially bigger
  lift than adding a type).
  - `archive._pq_build_schema_leaf` gained three new optional trailing params
    (`p_type_length`/`p_scale`/`p_precision`), each omitted from the Thrift schema element when
    null -- byte-for-byte unchanged for the six original types.
  - `archive._pq_encode_column_data` gained two new optional trailing params
    (`p_decimal_scale`/`p_decimal_bytes`), used only for `numeric`.
  - Both changed arg counts, so `install.sql` now also drops the old-signature overloads
    (`archive._pq_build_schema_leaf(text,int4,int4,boolean)` /
    `archive._pq_encode_column_data(text,text,text,boolean,text)`) so re-running it over a prior
    install doesn't leave both versions coexisting as ambiguous overloads.
  - `scripts/verify_parquet.py` gained 8 new test functions (uuid/jsonb/numeric, each with a
    nullable variant, plus the bare-numeric refusal), all green first try against real pyarrow +
    DuckDB round-trips; `test_unsupported_type_refused` now uses an `int4[]` array instead of
    `jsonb`, since jsonb is supported now.

- **Rewrite `pgpm_archive/README.md` from the ground up for simplicity and concision.** The
  previous version (post the docs/ fold) had grown into an engineering narrative: architecture
  rationale ("why this lives apart from core"), internal-mechanism recitation ("the gate is gone,
  `retire()` checks coverage directly"), and "verified end-to-end" proof-of-work sections that
  don't help someone trying to use the module. Cut all of that -- most of it (the byte-budget
  chunker's mechanics, the ledger, coverage checking) was already covered properly in
  `docs/reference.md`'s "Byte-budget chunked archiving" section anyway, just re-explained in
  different words. The new README is six short sections: Install, Automatic vs. manual (a small
  comparison table replacing the old multi-section "choosing a strategy" essay), NDJSON or
  Parquet, Limits (only the constraints a user actually needs to know before hitting them), and
  Testing. ~500 lines down to ~95. No content lost that isn't already documented elsewhere
  (`docs/reference.md` for the full contract, `docs/guide.md` for the operator's view).

- **Restore a function-based operator interface for archiving; no more raw SQL as the config
  surface.** Issue #240's deletion of the old paced worker collaterally deleted its
  `archive.configure`/`unconfigure` operator interface too, regressing back to `insert into
  archive.config` / `update pgpm.config set archive_fn = ...` as the documented way to set up
  archiving -- exactly the "raw SQL as the user interface" pattern issue #233 existed to eliminate.
  Two new functions restore it, scoped to the current (schedule-free) architecture:
  - `pgpm.set_archive_fn(p_parent, p_archive_fn regprocedure default null)` in `pgpm_core`, matching
    the existing `set_regrain`/`set_drain_adaptive`/`set_drain_ambient` convention -- the operator
    switch for `config.archive_fn`.
  - `archive.configure(p_parent, p_bucket, ...)` / `archive.unconfigure(p_parent)` in
    `pgpm_archive` -- an upsert/delete on `archive.config`, guarded by a pgpm-managed check. Narrower
    than the old, deleted interface: connection settings only, no scheduling knob (there is nothing
    left to schedule now that `pgpm.maintain()` drives archiving for every managed table).
  Every README/reference/guide example and test fixture that showed raw SQL now calls these
  instead. No behavior change to the underlying columns; purely an interface restoration.

- **Fold `pgpm_archive/docs/` into `pgpm_archive/README.md`; no more docs subfolder.** The three
  pages (`strategies-overview.md`, `to-s3.md`, `chunked-parquet.md`, ~2000 lines total) are gone;
  their narrative, honest-limits, and verified-end-to-end content now lives directly in
  `pgpm_archive/README.md`, one file instead of four. The ~1000+ lines of embedded SQL those pages
  reproduced (the SigV4 signer, the multipart uploader, the from-scratch Parquet/DEFLATE/GZIP
  writer) are dropped rather than carried over: they were byte-for-byte identical to what's already
  shipped in `pgpm_archive/install.sql`, so keeping a second copy in the docs was pure drift risk
  for no benefit. The merged README points at `install.sql` by function name instead. No behavior
  change; purely a documentation consolidation.

- **Fold `pgpm_observe` into `pgpm_core`; one less optional module.** Its four functions
  (`_observe_has_pgfr`, `observe_window`, `impact_report`, `feathering_validation`) move rename-only
  into `pgpm_core/install.sql`, right after `snapshot()`; no behavior change, no new install-time
  cost (the PGFR-aware code was never install-time-coupled to PGFR -- a PL/pgSQL function body isn't
  resolved against `pgfr_analyze` until called). PGFR stays **never a dependency**: the two
  PGFR-backed functions still raise a clear error until it's installed, exactly as before.
  **Operationally breaking**: `pgpm_observe/install.sql` no longer exists; drop it from any install
  script (re-running `pgpm_core/install.sql` already brings the functions along, so nothing else
  changes). The test track follows the same split as the functions' own PGFR-optionality: the
  PGFR-absent gate (no real PGFR needed) moves into the main suite as
  `tests/65_observe_no_pgfr_test.sql`; the PGFR-present correlation, which does need a real vendored
  PGFR install, stays its own track (`tests/observe/db/with_pgfr_test.sql`, `./test.sh observe`,
  `.github/workflows/observe.yml`).

- **Retire the `prototypes/parquet-writer/` prototype; its independent-reader verification moves
  into `scripts/`, wired into CI.** Both features it was built for (the Parquet writer, #199, and
  dynamic Huffman coding, #206) had already been ported rename-only into `pgpm_archive/install.sql`;
  keeping the prototype's own copy of the SQL around any longer was just a second, drifting copy of
  already-shipped code. Its two genuinely load-bearing pieces -- `verify.py`/`verify_range.py`,
  which check `archive._pq_to_parquet`/`_range`'s output against two independent Parquet readers
  (pyarrow and DuckDB), something the pgTAP-based archive test track never did -- move to
  `scripts/verify_parquet.py`/`verify_parquet_range.py`, retargeted to call the real shipped
  `archive._pq_*` functions directly (no more local install step) against `pgpm_core`+
  `pgpm_archive` installed by `test.sh`'s own `run_archive()`. `./test.sh archive` now runs both,
  in a venv (`scripts/requirements-verify.txt`), right after the pgTAP suite, against the same
  running instance -- closing a real gap the archive test track's own docs had flagged (no
  independent-reader re-verification of a real compressed Parquet object). The now-redundant
  fixed-vs-dynamic-Huffman comparison tests (meaningful during #206's own development, not for
  ongoing regression coverage, since production exposes no such toggle) were folded into the
  plain compressed-output tests instead of duplicated. `prototypes/` (the whole tree) is deleted.

- **Docs/CI: describe the retention/archiving merge as it now actually works; breaking change
  (#241).** Closes out the stack #242-#240 built: `pgpm.hook` and `pgpm_archive`'s old paced-worker
  scanning apparatus (`archive.tick`/`file_gate`/`configure`/`schedule` and friends) are gone, and
  archiving is configured per table via `pgpm.config.archive_fn` -- a partition only drops once it
  is write-blocked and, if `archive_fn` is set, fully archived. **Breaking**: any table that relied
  on `pgpm.hook_register`/`archive.configure`/`archive.schedule` for archiving-before-drop needs to
  set `config.archive_fn` instead; there is no migration shim (pre-1.0, no live installs, #217's
  precedent).

  - `pgpm_archive/docs/assistant.md` (the partition-aligned, `archive.tick`/`file_gate`-driven paced
    worker) is deleted outright, not banner-and-keep: every function it documented is gone with no
    successor (the `archive_fn` contract only ported the byte-budget rule, #237, never the
    partition-aligned one), so there is nothing left for it to point at.
  - `pgpm_archive/docs/chunked-parquet.md` and `docs/strategies-overview.md` are rewritten to
    describe the current, much smaller design space: `config.archive_fn`'s built-in byte-budget
    strategy (automatic, drop-gated) versus the synchronous `archive.to_s3`/`archive.to_s3_parquet`
    functions (manual, no automatic tie to a drop). The old "two knobs, four configurations" table
    (boundary rule x drop-trigger rule) and the module name-mapping table are both gone -- there is
    only one built-in strategy now, and its names never diverged from the module's own.
  - `pgpm_archive/docs/to-s3.md` and `pgpm_archive/README.md` drop every `pgpm.hook_register`/
    `archive.configure`/`archive.schedule` reference; the synchronous functions are reframed
    honestly as **not** gating a drop on their own (a real behavior change from the old
    hook-based design, where a failed copy blocked the drop automatically) -- `config.archive_fn`
    is now the path for that guarantee.
  - `docs/guide.md`'s "Pre-drop hooks" section is replaced with "Archiving before a drop", describing
    `config.archive_fn` directly; `docs/runbook.md` and `ONBOARDING.md` had their own stale
    `retain_hook_failures`/`archive.config` shape references fixed to match #238's renames and
    #240's column drops.
  - `test.sh`'s `archive` track no longer provisions a disposable database per test file: nothing
    in `tests/archive/db/*.sql` commits internally anymore (the old paced worker's internal commits
    were the only reason it needed to), so it now installs once and runs every file via `pg_prove`
    against one shared database, each wrapped in its own `BEGIN`/`ROLLBACK` -- the same pattern the
    default channel matrix already uses. `tests/archive/db/04_parquet_and_sync_hook_test.sql` is
    renamed to `04_parquet_and_sync_archive_test.sql` ("hook" no longer being the right word for a
    plain function call).
  - Backfills the `CHANGELOG.md` entries #239 and #240 should have landed with (below), which this
    issue's own audit found missing.

- **Port `archive.to_s3`/`archive.to_s3_parquet` onto the `archive_fn` contract (#239).**
  `pgpm.archive_to_s3_ndjson`/`pgpm.archive_to_s3_parquet` (in the `pgpm` schema, defined in the
  optional `pgpm_archive/install.sql`) adapt the existing synchronous functions' transport onto
  `pgpm.config.archive_fn`'s calling contract, so a table can ride `pgpm.maintain()`'s own
  byte-budget chunking (#237) instead of a separate schedule. Both delegate to the exact same
  encode/upload steps the synchronous functions already use
  (`archive._encode_upload_ndjson_single`/`archive._encode_upload_parquet`) and read connection
  settings from the same `archive.config` row, so there is no second, independently configured
  surface. `archive._encode_upload_ndjson_commits` (the third format, with internal `COMMIT`s) has
  no `archive_fn` counterpart and cannot: `archive_fn` is a plain function, and PL/pgSQL forbids
  transaction control inside one regardless of call context -- it does not need one anyway, since
  `pgpm._next_archive_chunk` already bounds every call to `config.archive_byte_budget` before
  `archive_fn` ever runs. Widens `pgpm.archive_result` (`covered_hi`, `rows_archived`) to also carry
  `s3_key`/`etag`, threaded through `pgpm._archive_step`'s ledger insert -- closing the gap #237's
  own comment flagged ("`s3_key`/`etag` stay null until a real strategy has something to put
  there"). New `tests/archive/db/08_archive_fn_s3_test.sql` (10 assertions, against real MinIO):
  both strategies dispatch via `config.archive_fn`, chunk via `pgpm.maintain()`, ledger every chunk
  with a non-null `s3_key`/`etag`, and the uploaded NDJSON object round-trips exactly through a
  direct MinIO fetch.

- **Delete the old paced worker and `pgpm.hook` entirely (#240).** Cutover: everything the old
  paced/`self_driving` apparatus existed to do -- pick ranges, record a ledger, gate a drop on a
  recount, drive the drop itself on a schedule -- is now done by the unified `archive_fn` path
  (#235-#239). Deletion only, no new behavior. Deleted from `pgpm_archive/install.sql`:
  `archive.tick`, `_tick_one`, `_next_range_partition_aligned`, `_next_range_byte_budget`,
  `_retire_covered`, `file_gate`, `_file_watermark`, `archive_range`, `archive_partition`,
  `run_all`, the `archive.ledger` table, and the `archive.configure`/`unconfigure`/`schedule`/
  `unschedule` operator interface (#233), along with the `pgpm-archiver` pg_cron job they
  registered. `archive.config`'s `boundary_rule`/`drop_trigger`/`format`/`byte_budget`/
  `probe_sample` columns are dropped (`ALTER TABLE ... DROP COLUMN IF EXISTS`, upgrade-safe);
  `part_bytes`/`fetch_rows` stay, still used by `archive.to_s3`'s own multipart chunking. Deleted
  `pgpm.hook`/`hook_register`/`hook_unregister` from `pgpm_core` entirely: `retire()` stopped
  consulting it in #238, and #239 gave `archive.file_gate` -- its last real registrant -- a
  replacement on the `archive_fn` contract, so nothing depended on it anymore. `archive.to_s3`/
  `archive.to_s3_parquet` (the synchronous functions) and `pgpm.archive_to_s3_ndjson`/
  `archive_to_s3_parquet` (the `archive_fn` strategies, #239) are untouched and keep working
  exactly as before. Deleted `tests/58` (`pgpm.hook` mechanics, the registry it tested no longer
  exists) and `tests/archive/db/01/02/03/05/06/07` (each tested exactly the deleted
  paced-worker/operator-interface/hook surface); rewrote `tests/archive/db/04` to call
  `archive.to_s3_parquet` directly with no hook registration; stripped the now-impossible
  `pgpm.hook` assertions from `tests/62` and fixed dangling `tests/58` cross-references in
  `tests/59`/`60`/`64`/`63`.

- **`pgpm.retire()`: drop only once write-blocked and archive-covered; `pgpm.hook` no longer
  consulted (#238).** With write-blocking (#235) and ledger-driven archive coverage (#237) both in
  place, `retire()`'s drop precondition becomes fully internal: past the retention boundary (as
  before), write-blocked (ensured here via idempotent `pgpm._install_write_block`, not merely
  assumed -- `retire()` is called by more than one path, and asserting instead of ensuring would
  make it raise for any caller that reaches an eligible partition without `maintain()` having run
  first), and `pgpm._archive_fully_covered`. A not-yet-covered child is a normal, retryable state,
  not a failure: `retire()` returns `false` and logs nothing, the same as an already-retired or
  concurrently-claimed partition. Only a genuinely unexpected `DROP` failure is logged
  (`retain_drop_fail`, replacing `retain_hook_fail`; `status()`'s `retain_hook_failures` is renamed
  `retain_drop_failures` to match what it now actually measures).

  `pgpm.hook`'s `pre_drop` loop is removed from `retire()` entirely -- nothing in `pgpm_core` calls a
  registered hook anymore. **`pgpm.hook`/`hook_register`/`hook_unregister` are deliberately NOT
  dropped**: `pgpm_archive`'s existing gate-only architecture still registers `archive.file_gate`
  through them, and removing the table/functions now would break that before `pgpm_archive` migrates
  onto the `archive_fn` contract (#239/#240). A registered hook simply never runs anymore; full
  removal is #240's job. This is a real, known regression for `pgpm_archive`'s `gate_only` and
  `self_driving`-with-a-failing-hook scenarios in the meantime (documented in
  `pgpm_archive/README.md` and `docs/strategies-overview.md`; `tests/archive/db/01` and `06` are
  `skip()`ped with a clear reason rather than rewritten, since re-expressing those scenarios on the
  new contract is #241's job, not this one's).

  Rewrote `tests/58` (proves a registered `pre_drop` hook, even one that always raises, no longer
  blocks anything -- the opposite of what it proved before this issue), `tests/59` (the `retain_batch`
  wedge demonstration now uses a not-yet-archive-covered child instead of a failing hook, and
  explicitly asserts `retain_drop_failures` stays zero throughout -- the key new distinction), and
  `tests/60` (removed hook-blocks-a-drop assertions; added write-block-ensured and
  archive-coverage-gate assertions). New `tests/64_retire_archive_gate_test.sql` (8 assertions, the
  issue's own test plan): a child crosses the boundary, is write-blocked immediately but stays
  undropped while chunked archiving is still incomplete, and drops the moment coverage completes (in
  the very same tick); a `none`-strategy child drops on the very next eligible cycle, exactly as
  `retain()` always behaved before this whole stack existed.

- **Docs: `docs/retention-write-block-and-merge.md`, the positioning doc for a retention/archiving
  merge stack (#242).** Chunked archiving (#213, #221) can now take several `maintain()` ticks to
  fully archive one large partition, and nothing today stops a backdated write into that
  still-attached, still-writable span -- `archive.file_gate`'s recount only catches the divergence
  reactively, after the fact. The doc lays out the fix (a `BEFORE INSERT OR UPDATE OR DELETE`
  trigger that write-blocks a partition the instant it crosses the retention boundary, independent
  of archiving), the two mechanisms ruled out first with the concrete evidence (`REVOKE` only
  checks the parent's ACL on a parent-routed write; a spanning lock defeats the point of chunking),
  the target end state (a pluggable `archive_fn` contract on `pgpm.config`, ledger-driven chunked
  archiving as the built-in strategy, a unified `retire()` drop precondition, `pgpm.hook` retired),
  and the implementation order for #235-#241 that follow it. Also settles the module-split question
  from the prior harmonization stack (#217-#222): the dependency surface a hard `pgpm_core`/archive
  split would leave behind isn't small enough to be worth it, so `archive` stays a namespace inside
  the same install, not an independently versioned module. Documentation only -- no code changes,
  no behavior changes; every mechanism the doc describes is still a plan.

- **Port byte-budget chunked archiving and its ledger onto the `archive_fn` contract (#237).**
  `pgpm_archive`'s `archive._next_range_byte_budget`/`archive.archive_range`/`archive.ledger`
  (#213, #221) proved that archiving a large partition safely means chunking it instead of doing it
  as one giant operation; this ports that mechanism, unchanged in intent, onto `pgpm.config.archive_fn`
  (#236) and the write-block trigger (#235). New `pgpm.archive_ledger` (successor to
  `archive.ledger`, same shape: `parent_table`, `lo`, `hi`, `child_name`, `s3_key`, `etag`,
  `rows_archived`, `archived_at` -- `s3_key`/`etag` stay null until a real transport strategy, #239,
  has something to put there). New `pgpm._next_archive_chunk(p_parent, p_child)` picks the next
  chunk within one already-write-blocked child's own `[lo, hi)` (the one real adaptation from the
  original, which picked ranges across the whole table since nothing else gated eligibility yet --
  here that gating is the write-block trigger's job). New `pgpm._archive_fully_covered(p_parent,
  p_child)`: true once the ledger's ranges for that child reach its own `hi`, or the strategy is
  `none` -- the intended `retire()` drop precondition once #238 wires it in, not consulted by
  anything yet. New `pgpm._archive_step(p_parent)` -- one `maintain()` tick's worth: for every
  attached child that **already has the write-block trigger installed** (checked directly against
  `pg_trigger`, never re-derived from the boundary formula) and is not yet fully covered, picks its
  next chunk, runs `pgpm._run_archive_strategy`, and records the result. `pgpm.maintain()` now runs
  this right after write-blocking, ahead of `retain()`; its summary gains an `archived=N` field.
  `archive.ledger`/`archive.archive_range`/`archive.tick` in `pgpm_archive` are completely untouched
  and keep working exactly as before -- they are deleted only once this path replaces them (#240).
  New `tests/63_archive_chunk_ledger_test.sql` (14 assertions): a multi-chunk partition archives
  across several `maintain()` ticks with bounded per-tick progress; `_archive_fully_covered` flips
  true only once the last chunk lands; resuming across ticks never duplicates or skips a range; a
  child holding real data but not yet write-blocked is never touched even though `archive_fn` is set
  for the whole table; a `none`-strategy table is immediately fully covered with nothing ever
  ledgered. Caught and fixed one real bug along the way: `archive_ledger.hi` is `text`, so a plain
  `max(hi)` compares lexicographically (`'91' > '1000'`) instead of numerically/temporally --
  `_next_archive_chunk`/`_archive_fully_covered` now cast to the native type first, the same fix
  `archive._file_watermark` already needed for the identical reason.

- **Write-block a partition the instant it crosses the retention boundary (#235).** Chunked
  archiving can take several `maintain()` ticks to fully archive one large partition, and for the
  whole span between crossing `_retain_boundary()` and the last chunk landing, the partition sat
  attached and, with nothing to stop it, fully writable -- a backdated write into that span,
  including into a range some earlier chunk already archived and ledgered, would silently diverge
  the archive from what is live. `REVOKE` on the child does nothing (a parent-routed write is
  checked against the *parent's* ACL, never the child's), and a lock spanning the whole archiving
  window defeats the reason chunking exists, so instead: a `BEFORE INSERT OR UPDATE OR DELETE`
  trigger (`pgpm._install_write_block`) is installed on a child the moment its whole range is
  at/below the horizon, and removed (`pgpm._remove_write_block`) if an operator loosens
  `config.retain` and the child becomes ineligible again -- both idempotent, so a repeat
  `_enforce_write_blocks` tick never raises a duplicate-trigger error. `pgpm.maintain()` now runs
  `_enforce_write_blocks` every tick, ahead of `retain()`'s own drop logic. Purely additive: not
  wired into `retire()`'s drop precondition yet (that's #238), and `pgpm.hook` is untouched -- a
  write-blocked partition still drops exactly as before, the trigger going with the table on
  `DROP TABLE`. New `tests/61_write_block_test.sql` (22 assertions): a child crossing the boundary
  gets the trigger; parent-routed and direct-to-child inserts, updates, and deletes are all
  rejected; a sibling child still under the boundary is unaffected; reads through the parent are
  unaffected; re-running `maintain()` is idempotent; loosening `config.retain` removes the trigger.
  First rung of the retention/archiving merge stack positioned in #242
  (`docs/retention-write-block-and-merge.md`).

- **`pgpm.config.archive_fn`: a pluggable archive strategy contract, the first step toward
  replacing `pgpm.hook`'s `pre_drop` registry (#236).** `pgpm.hook` is generic (any event, any
  number of hooks) but has only ever had one real use: archiving before a drop. `archive_fn` is a
  nullable `regprocedure` column narrowing that to one archive strategy per managed table (`null` =
  strategy `none`, immediately drop-ready) -- casting the reference validates the function exists
  with exactly this signature at assignment time, not later when a maintenance tick tries to call
  it, the same reasoning `hook_register`'s `p_hook` parameter already uses. The calling contract:
  `archive_fn(p_parent regclass, p_child name, p_lo text, p_hi text) returns pgpm.archive_result`
  (`covered_hi text, rows_archived bigint`), expected to be **resumable** -- called once per tick,
  making bounded incremental progress and reporting how much of `[p_lo, p_hi)` is now durably
  archived, not finishing the whole range in one call. New `pgpm._run_archive_strategy` dispatches
  to `config.archive_fn` (or synthesizes an immediate "already covered" result for the `none`
  strategy); new `pgpm._archive_noop` is a trivial built-in strategy that exists only to exercise
  real dispatch (an actual regprocedure call, not the null special case) in tests. Schema and
  contract only: nothing yet calls `_run_archive_strategy` from `retire()`/`retain()`, and
  `pgpm.hook` is completely untouched -- both continue to work exactly as before. New
  `tests/62_archive_fn_contract_test.sql` (10 assertions). Positioned in #242
  (`docs/retention-write-block-and-merge.md`), the next rung after #235's write-block trigger.

- **`archive.configure`/`archive.unconfigure`/`archive.schedule`/`archive.unschedule`: a real
  operator interface for `pgpm_archive`, replacing raw SQL against `archive.config` and a bare
  `cron.schedule` call.** Normal operation should never need a hand-written `insert`/`update`
  against a catalog table -- `archive.configure(parent, bucket, ...)` upserts a table's connection
  settings and knobs (an idempotent, re-callable setup, same shape as `pgpm.transmute`'s
  many-named-parameters-with-defaults style), `archive.unconfigure(parent)` removes them, and
  `archive.schedule`/`unschedule` wrap `cron.schedule_in_database` exactly the way
  `pgpm.schedule`/`unschedule` already do (same guard when `pg_cron` isn't installed, same
  idempotent re-scheduling). Deliberately does *not* also register a `pre_drop` hook: which one
  (`archive.file_gate` for the paced worker, `archive.to_s3`/`archive.to_s3_parquet` for the
  synchronous hook) depends on which architecture a table uses, so that stays its own explicit
  `pgpm.hook_register` call. New `tests/archive/db/07_configure_and_schedule_test.sql` (13
  assertions); `tests/archive/fixtures.sql`'s `mk_archive_config` now calls `archive.configure`
  instead of its own raw insert, and every doc/`README.md` snippet showing the old
  `insert into archive.config` pattern was updated to match.

- **Move the archive docs under `pgpm_archive/` and stop referencing archival from the root
  `README.md`.** Archiving to S3 is a downstream concern from partition lifecycle management, not
  part of `pg_partition_magician` core -- it started as worked examples embedded in markdown and
  later graduated into an installable module, but the root README had kept linking to it as though
  it were a core feature. Fixed: the four archive docs (`archive-strategies-overview.md`,
  `archive-to-s3.md`, `archive-assistant.md`, `archive-chunked-parquet.md`) moved from `docs/` to
  `pgpm_archive/docs/` (`strategies-overview.md`, `to-s3.md`, `assistant.md`, `chunked-parquet.md`),
  every cross-reference among them and from `docs/guide.md`/`docs/reference.md`/
  `prototypes/parquet-writer/README.md`/`pgpm_archive/install.sql` updated to match; the root
  `README.md`'s "Documentation" section no longer mentions archiving at all. In their place,
  `pgpm_archive/README.md` is a new front door -- what the module is, why it's separate from core,
  install + configure + register in one place, the two-architecture picture, and links into its own
  `docs/`. Together, these leave `pgpm_archive/` reorganizable into its own repo with near-zero
  further effort, which was the whole point.

- **Point `docs/archive-*.md` at `pgpm_archive/install.sql` as the installable source of truth
  (#222, 3 of 3 -- closes the six-issue archive harmonization stack, #217-#222).** The three
  implementation pages (`archive-to-s3.md`, `archive-assistant.md`, `archive-chunked-parquet.md`)
  and the overview (`archive-strategies-overview.md`) keep every line of hand-rolled SQL, their
  original names, and everything they verified exactly as written -- they remain the design
  rationale, the honest limits, and the live-verification story. Each of the three implementation
  pages gets a short callout near its top plus an updated "Install"/"Register and pace it" section
  showing the module-based path (install `pgpm_archive/install.sql`, configure one `archive.config`
  row per table) as the recommended way to deploy, with the original hand-rolled instructions kept
  as the alternative. `archive-strategies-overview.md` gets a new "Installing the module" section
  with the full name-mapping table (`archive.partition` -> `archive.archive_partition`,
  `archive.scan()` -> `archive.tick()`, `archive._chunk_one` -> `archive._tick_one`,
  `archive.chunk_all` -> `archive.run_all`, `c_self_driving`/`c_format`/`c_compress`/... ->
  `archive.config` columns), and its "Positioning" section now reflects that #222 actually closed
  the "two entry points remain unmerged" gap that section used to flag as still open.

- **Permanent CI infrastructure for `pgpm_archive` (#222, 2 of a planned 2-3 PR sequence):
  a `./test.sh archive` track, replacing the ad hoc Postgres 17 + `pgsql-http` + MinIO harness
  #217-#221 and #222's first PR were hand-verified against.** The shared `Dockerfile` grows an
  opt-in `WITH_PGSQL_HTTP` build arg (default `false`, so the existing pg15-18 matrix images are
  byte-for-byte unaffected); `docker-compose.yml` grows a `minio` service and an `archive` PG17
  service (own profile, excluded from `all`, matching the `timescale` service's own pattern).
  `test.sh` gets a `run_archive` function modeled on `run_timescale`'s disposable-database-per-file
  shape, not `run_observe`'s begin/rollback shape: `archive.tick()` and
  `archive._encode_upload_ndjson_commits` commit internally, and PL/pgSQL only allows that when the
  call chain traces to a top-level `CALL`, which rules out wrapping them in `begin`/`rollback` (or
  in any pgTAP assertion function -- `lives_ok`/`throws_ok` are themselves functions, so a
  commit-issuing procedure must be invoked as a bare top-level `CALL`, its success proven by
  separate assertions afterward, not by the wrapper).

  New `tests/archive/fixtures.sql`: a `vault.decrypted_secrets` stub (the module reads S3
  credentials via Supabase Vault's public view; the test image is plain Postgres with no
  pgsodium/Vault available) seeded with the test MinIO's root credentials, plus small
  managed-table and `archive.config`-row builders wired to the harness's MinIO bucket/endpoint. Six
  `tests/archive/db/*.sql` pgTAP files cover the worker end to end: the happy path via
  `archive.tick()` (`gate_only`), a `self_driving` table dropping partitions in the same `tick()`
  call that archived them, the `byte_budget` boundary rule chunking a span that does not align to
  any partition, the `parquet` format plus the structurally separate synchronous
  `archive.to_s3_parquet` hook, the forward-only guard on `archive.archive_partition`, and --
  the highest-value regression -- the unconditional retire sweep fix from #222's first PR, proven
  the same way it was live-verified there: a second `pre_drop` hook fails one partition's drop, a
  first `tick()` leaves it stuck while archiving and retiring the other two, and a second `tick()`
  -- with nothing new to archive -- still retries and drops it.

  A standalone, path-filtered `.github/workflows/archive.yml` runs the new track on push/PR
  touching `pgpm_archive/install.sql`, `pgpm_core/install.sql`, `tests/archive/**`, or the harness
  itself, mirroring `observe.yml`'s non-gating model (not wired into `test.yml`/`release.yml`),
  since archival is fully optional user-land and depends on external MinIO infrastructure that
  should not gate releases. Verified locally end to end (`./test.sh archive`, all green) and that
  `WITH_PGSQL_HTTP` defaulting to `false` is a true no-op for the existing matrix
  (`./test.sh 17`, unaffected).

  Next in this sequence: update the existing `docs/archive-*.md` pages to point at this module as
  the installable source of truth, keeping their narrative, honest-limits, and live-verification
  write-ups.

- **New `pgpm_archive/install.sql`: the archival harmonization stack (#217-#221), packaged as a
  real, installable, optional add-on (#222, 1 of a planned 2-3 PR sequence).** Mirrors
  `pgpm_hypertable/`/`pgpm_observe/`'s existing shape (one `install.sql`, no config table of its
  own to copy from -- both siblings take parameters directly or read an external catalog, so the
  config table here is a genuine new design, not a port). Ports every `archive.*` object out of
  `docs/archive-to-s3.md`/`archive-assistant.md`/`archive-chunked-parquet.md`'s embedded SQL
  (58 functions/procedures, verbatim where unchanged) into one file, replacing every
  "deployment constants: edit these N" block with one real table, `archive.config`: one row per
  managed table, carrying connection settings (bucket/region/endpoint/prefix/vault secret names)
  and the three knobs the harmonization stack built (`boundary_rule`, `drop_trigger`, `format` +
  `compress`).

  This is also where the stack's own remaining gap finally closes: `archive.partition` and
  `archive._chunk_one` -- kept as two separate, hand-built entry points through #217-#221
  specifically to avoid packaging today's two-implementation shape twice -- are now one truly
  unified worker. `archive.archive_range`/`archive.archive_partition` do the actual archiving
  (dispatching to whichever encode/upload step `archive.config.format` names); `archive._tick_one`
  picks the next range per `archive.config.boundary_rule`; `archive.tick()` (the standing pg_cron
  entry point) and `archive.run_all(parent)` (the operator's "do it now") both work for every
  table regardless of which knobs it's configured with.

  Building the true unified worker surfaced one more real gap, caught live before shipping:
  #220's self-driving retire only ever ran right after a fresh chunk was archived, so a
  byte-budget-aligned table that quiesced (no new data, so no new chunks, ever) could never retry
  a partition whose `retire()` failed once for a reason unrelated to archiving -- the same
  category of gap #219 already fixed for the partition-aligned rule specifically, just not
  generalized to the other one. Fixed by running the retire sweep unconditionally, every tick, for
  every self-driving table, regardless of whether that table archived anything new this cycle.
  Reproduced live: registered a second `pre_drop` hook that fails one specific partition's drop
  (simulating an unrelated external failure), confirmed it stayed stuck through one `tick()` call
  that successfully archived and retired everything else, removed the failing hook, and confirmed
  a *second* `tick()` call -- with nothing new to archive, watermark unchanged -- still retried and
  correctly dropped the previously-stuck partition.

  Live-verified end-to-end against the same Postgres 17 + `pgsql-http` + MinIO harness used for
  #217-#221: all four boundary-rule x drop-trigger-rule combinations plus both new format
  cross-combinations, driven entirely through `archive.config` rows; the tie-break fix and the
  forward-only guard, unaffected by the config-driven rewiring; and the synchronous hooks
  (`archive.to_s3`/`archive.to_s3_parquet`) reading their connection settings from
  `archive.config` too, for one consistent configuration story across every archival strategy in
  the module. `install.sql` applies cleanly from empty and re-applies idempotently.

  Next in this sequence: permanent CI infrastructure (a MinIO service, a `pgsql-http`-enabled test
  image, a `./test.sh archive` track, `tests/archive/`'s pgTAP suite) to replace the ad hoc harness
  this PR (and #217-#221) verified against by hand; then the existing `docs/archive-*.md` pages
  updated to point at this module as the installable source of truth, keeping their narrative,
  honest-limits, and live-verification write-ups.

- **Docs: pluggable encode/upload step for the paced worker -- format x compression x commit
  strategy (#221, closes #213, #214).** The last hardwired piece after #217-#220: *how* a range
  becomes bytes and lands in S3. Adds three shared, matching-shaped steps -- `(p_parent, p_lo,
  p_hi, p_compress)` in, `(s3_key, etag, rows_archived)` out -- defined once in
  `docs/archive-assistant.md`'s "The archiver": `archive._encode_upload_ndjson_single` (one read,
  one `PUT`, optionally one gzip member), `archive._encode_upload_ndjson_commits` (the per-part-
  commit technique, generalized off any range instead of always exactly one partition), and
  `archive._encode_upload_parquet` (a thin wrapper around the chunker's own range encoder). Both
  `archive.partition` and `archive._chunk_one` get a `c_format` constant dispatching to whichever
  step is configured (`'ndjson_commits'` / `'parquet'` respectively by default, unchanged); Parquet
  with internal commits is named explicitly as impossible, not a gap -- its footer needs every row
  group's byte offset, known only once the whole file exists.

  Generalizing the per-part-commit reader past "always one partition" surfaced a real,
  previously-latent bug, not just a mechanical lift: the original ordered its keyset pagination by
  the control column alone with a strict `>` resume predicate, correct only if no two rows share a
  control-column value across a page boundary. Reproduced directly -- a 21-row, time-kind fixture
  (mostly 3-4 rows per timestamp) read page-by-page with the original query returned only 16 of 21
  rows, 5 silently dropped at a page boundary tie. Every prior test of `archive.partition` had used
  a unique id-kind control column, where this gap can never manifest. Fixed by ordering and
  resuming on a `text[]` of `(control column, real key columns)` -- Postgres compares arrays
  lexicographically, so this is a genuine composite tiebreak without dynamic-arity `ROW()`
  construction -- using `archive._key_columns` (relocated from `archive-chunked-parquet.md` to
  `archive-to-s3.md`, since both the Parquet and NDJSON range readers need the identical key
  discovery now). The same fixture through the fixed reader returned all 21 rows, verified by id.

  Compressing an NDJSON-with-commits range gzips each part independently and lets S3 multipart's
  own byte-range concatenation produce the final object -- a valid multi-member gzip stream (RFC
  1952 permits concatenating independent gzip members; standard decompressors read through all of
  them transparently) -- verified against a 30,000-row fixture forced into several 6MiB+ parts,
  decompressing cleanly with a stock `gunzip` into all 30,000 rows, no loss or duplication.

  Live-verified end-to-end: the unchanged defaults for both pages; the two newly-possible
  combinations (`archive.partition` with `c_format := 'parquet'`, `archive._chunk_one` with
  `c_format := 'ndjson_single'`); the tie-break bug reproduced and then confirmed fixed;
  compression on the commits variant; and the #218 forward-only guard and #220 self-driving retire
  both unaffected by the new dispatch layer. The S3 key naming changed as a side effect of no
  encode/upload step knowing a child name anymore: newly archived objects are now keyed by
  `(parent, lo)` rather than `(child name)` -- already-archived objects and their ledger rows are
  unaffected.

- **Docs: add a drop-trigger toggle (gate-only vs self-driving) to the paced worker (#220).** Fills
  the two previously-unbuilt cells in `docs/archive-strategies-overview.md`'s boundary-rule x
  drop-trigger-rule table. Adds a shared `archive._retire_covered(p_parent, p_up_to)` procedure
  (kind-aware, claim-guarded via `pgpm.retire()`, one `commit` per drop) that retires every
  attached partition whose bounds fit inside `p_up_to`. Both `archive.scan()` and
  `archive._chunk_one` get a `c_self_driving` deployment constant: `archive.scan()` defaults to
  `true` (unchanged, self-driving) and can be set `false` for gate-only, becoming a pure archiver
  that leaves drop timing to `retain()`'s own schedule; `archive._chunk_one` defaults to `false`
  (unchanged, gate-only) and can be set `true` to call `archive._retire_covered` with the chunk's
  own newly-advanced watermark right after its ledger row commits -- the byte-budget-aligned,
  self-driving configuration [#212](https://github.com/dventimisupabase/pg_partition_magician/issues/212)
  asked about, generalized to both boundary rules at once. `archive.scan()`'s retire sweep was
  also simplified in the same change: it now loops managed tables directly and calls the shared,
  committing `archive._retire_covered` per table, rather than materializing every table's targets
  into one list first (a live cursor calling a committing procedure per iteration is exactly the
  pattern PG11 added transaction control in procedures to support). Live-verified all four
  boundary-rule x drop-trigger-rule combinations: the assistant self-driving (unchanged) and
  gate-only (new, archives without retiring, `retain()`+`archive.file_gate` pick up the drop
  later); the chunker gate-only (unchanged) and self-driving (new, retires three partitions in one
  call right after a chunk that happened to span all three); and the restructured retire sweep
  across two managed tables in one `archive.scan()` call.

- **Docs: extract the paced worker's boundary rule as a pluggable step (#219).** Factors "pick the
  next range to archive" out of both archivers into two matching-shaped functions --
  `archive._next_range_partition_aligned(p_parent)` (the assistant's existing eligibility logic:
  the first attached, retention-eligible partition whose ledger row is missing or stale) and
  `archive._next_range_byte_budget(p_parent, c_byte_budget, c_probe_sample)` (`archive._chunk_one`'s
  existing byte-budget computation, unchanged) -- both `(p_parent)` in, `(lo, hi)` or no rows out.
  `archive._chunk_one` now calls the byte-budget picker instead of inlining its computation, with
  byte-identical results (re-verified: single-file and 334-file/5,000-row fixtures, same ranges,
  same counts, same gap-free contiguity). `archive.scan()` now calls the partition-aligned picker
  in a loop until exhausted for the archiving half of its work, with one honest, deliberate
  restructuring: archiving and retiring are no longer interleaved per partition -- the picker drains
  first, then the existing retire sweep (unchanged) attempts every eligible partition, not just the
  ones just archived. Re-verified this preserves the one guarantee that split had to keep: a
  partition archived on an earlier cycle but left un-retired (a drop deferred for a reason unrelated
  to archiving) is correctly *not* re-archived by the picker but still retried by the retire sweep.
  Stale-veto self-repair and the #218 forward-only guard were both re-run through the new
  picker-driven call path with identical results.

- **Docs: unify `archive.gate` and `archive.file_gate` into one gate (#218).** `archive.file_gate`
  (`docs/archive-chunked-parquet.md`'s fast-path-watermark-plus-decrement veto) replaces the
  retired `archive.gate` (`docs/archive-assistant.md`'s simpler per-child recount) everywhere; both
  pages now register the identical function, defined once alongside the ledger in
  `docs/archive-assistant.md`'s "The ledger and the gate". Live verification against a Postgres 17,
  `pgsql-http`, and MinIO harness caught a real gap before it shipped: `archive.gate` looked up one
  partition by `child_name`, independent of anything else, so nothing could fool it; swapping in
  `archive.file_gate` unmodified let a later partition archived out of order (bypassing
  `archive.scan`'s own in-order sweep) push the shared watermark past an earlier, still-unarchived
  partition, and `pgpm.retire()` dropped that earlier partition **with no error and no log entry**.
  Fixed with a forward-only guard in `archive.partition`: it now refuses to write a ledger row out
  of order (exempting a legitimate re-archive of an already-ledgered, stale partition), the same
  discipline `archive._chunk_one` already keeps by construction. Re-verified end-to-end: happy path
  and both vetoes with `archive.file_gate` registered on the assistant's own tables, the
  out-of-order sequence now failing fast instead of silently dropping unarchived data, and a second
  table run through the chunker concurrently with no cross-talk in the shared ledger.

- **Docs: unify `archive.ledger` and `archive.file_ledger` (#217).** The archive assistant
  (`docs/archive-assistant.md`) and the chunked Parquet archiver (`docs/archive-chunked-parquet.md`)
  each recorded the same underlying fact -- a `[lo, hi)` range of the control column durably
  archived to an S3 key -- in two different table shapes, one keyed by `child_name` and one by
  `lo`. A partition's own bounds are already a native-grid `[lo, hi)` range, so `archive.ledger`
  now adopts `archive.file_ledger`'s shape (`lo` as the primary key) with `child_name` kept as an
  optional, nullable convenience column populated only when a range happens to equal exactly one
  partition's bounds; `archive.file_ledger` is gone (nothing was deployed against either shape
  yet, so there was no migration to preserve). `archive.partition` now looks up its partition's
  `lo`/`hi` from `pgpm.part` before writing the ledger row.
  `archive.gate`, `archive.scan`, `archive._file_watermark`, `archive.file_gate`, and
  `archive._chunk_one` needed no behavior change -- only the table each already pointed at. First
  rung of a six-issue stack (#217-#222) toward one paced-worker mechanism parameterized by the two
  knobs `docs/archive-strategies-overview.md` names (boundary rule, drop-trigger rule).

- **Docs: chunked, cross-partition Parquet archival (`docs/archive-chunked-parquet.md`).** A third
  archival strategy alongside `archive-to-s3.md` and `archive-assistant.md`: decouples Parquet file
  boundaries from partition boundaries entirely, so the vacuum-horizon hold is bounded by a chosen
  target file size instead of emergent partition size (a busy month's partition can be far bigger
  than a quiet one's under time-cut partitioning). Adds `archive.file_ledger` (an additive table
  recording one row per archived file, `[lo, hi)` ranges always contiguous and gap-free from the
  parent's grid anchor, the watermark derived as `max(hi)`), a cross-partition range-query variant
  of the Parquet encoder (`archive._pq_to_parquet_range`, reading straight off the parent and
  relying on Postgres's own partition pruning, ordering by `(control column, real key)` instead of
  `ctid` since a range can span more than one child's heap and a time-kind control column routinely
  repeats; key discovery mirrors `pgpm.regrain_step`'s own PK/unique-constraint contract exactly,
  refusing keyless tables the same way), a two-part `archive.file_gate` (a derived-watermark fast
  path plus a whole-file defense-in-depth recount), and `archive._chunk_one`/`archive.chunk_step`/
  `archive.chunk_all` (the chunker itself, stopping each file at the smallest of a byte-budget
  estimate, the frozen floor, and the retention horizon, mirroring `pgpm.regrain_step`/`regrain`'s
  two driving modes).

  Verification surfaced a real correctness gap beyond the original design: a naive gate that
  recounts a file's live range against a *static* `rows_archived` misfires the moment two
  partitions sharing a file are dropped in separate `retire()` calls (the ordinary case, since
  `retain_batch` paces drops one at a time) -- partition A's legitimate drop makes the file's live
  count permanently look "short" to partition B's later check, indistinguishable from a real stray.
  The fix keeps `rows_archived` in lockstep by decrementing it (under `FOR UPDATE`) by exactly the
  dropped partition's overlap with each file it touches, verified against the constructed failure
  case directly. Verified end-to-end against a live MinIO instance through the real
  `pgpm.retire()`/`retain()` path: a 1,000-row/20-day fixture chunked into 57 files, every one
  fetched back and read by both pyarrow and DuckDB, the union exactly reconstructing the source
  (zero dup, zero drop, contiguous ranges confirmed programmatically); the sequential-sibling-drop
  fix proven against the exact adversarial sequence that breaks the naive version; a real stray
  (a row deleted out of an already-archived partition) caught through the actual `retain()` path
  and logged via the standard `retain_hook_fail` contract; single-writer confirmed under real
  concurrency; and both driving modes (paced one-file-per-tick, and drain-the-backlog-now)
  exercised. Prototype + its own from-scratch test suite (13 cases) live alongside the existing
  whole-relation encoder in `prototypes/parquet-writer/`.

- **The metaphor gets its cast sorted, and the archival examples leave `public`.** The drain is no
  longer called the magician's "assistant" anywhere: pgpm does its own drain work (it is all one big
  act), and **assistant** now names the archive-then-retire scanner (`docs/archive-janitor.md` is now
  `docs/archive-assistant.md`). Separately, every object in the worked archival examples moved from
  `public` into a dedicated `archive` schema (`archive.to_s3`, `archive.s3_signed_request`,
  `archive.ledger`, `archive.gate`, `archive.partition`, `archive.scan`): on Supabase, `public` is
  typically exposed through the Data API, which serves tables over REST and functions as RPC
  (PostgreSQL grants `EXECUTE` to `PUBLIC` on new functions by default); archival machinery has no
  business being API-visible. The relocated SQL was re-verified end-to-end against MinIO (both hooks'
  happy paths and the assistant's full matrix: vetoes, self-repair, crash cleanup).
- **Docs: the archive assistant (`docs/archive-assistant.md`).** The scanner variant of the S3 archival
  example: a standing pg_cron procedure that archives aged partitions **with per-part commits**, so
  the vacuum horizon is held for one part's network time instead of a whole partition's upload, and
  then drops each partition itself via `pgpm.retire()`, with the lean `archive.gate` `pre_drop` hook
  keeping `retain()` an honest backstop (defers unarchived or changed partitions loudly). Ledger
  table records the fact; the gate owns the veto; the archiver owns the repair. Verified end-to-end
  against MinIO: happy path (multipart + empty fast-path, retired via `retire()`), the unarchived
  veto, the stale veto + self-repair (a backdated row caught by the row-count contract), crash
  cleanup (a mid-part failure leaks an in-flight upload; the next scan's cleanup-on-entry aborts it,
  since PL/pgSQL forbids transaction control inside a block with an `EXCEPTION` clause, so a
  committing procedure cannot abort-on-exit), and the horizon claim measured directly: 1 distinct
  `backend_xmin` across the synchronous hook's whole run versus 11 advancing values under the
  assistant, same ~110MB payload, same ~1s wall-clock. Re-verified on a live Supabase project against
  Supabase Storage (same matrix, same deterministic ETags; the full-scale measurement: a ~110MB
  10-part archive over the real network showed 20 advancing `backend_xmin` values in 27 samples for
  the assistant versus one pinned value for the synchronous hook). The live run surfaced two Supabase
  ceilings, now documented loudly on both archival pages: Storage enforces the project upload file
  size limit (default 50MB, `HTTP 413` `EntityTooLarge`, boundary-verified at 49MB pass / 51MB fail,
  raised under Dashboard Storage -> Files -> Settings) on the S3 protocol per whole object, multipart
  included; and `statement_timeout` is 2 minutes (server configuration file, pooler and direct
  alike), the synchronous hook's wall-clock ceiling, which the assistant's per-part statements
  sidestep.

- **`pgpm.retire(parent, child)`: the sanctioned single-partition drop.** `retain()`'s per-partition
  body -- claim, `pre_drop` hooks in registration order, `DROP`, catalog + log, per-partition failure
  isolation -- factored into a public verb, so an external assistant (e.g. an archive-then-drop scanner)
  or several cooperating ones can drive retirement directly without hand-rolling pgpm's protocol.
  `retire` never widens what retention may drop (it refuses anything not entirely past the retention
  horizon; a caller only picks which eligible partition and when), and the `pgpm.part` row is claimed
  `FOR UPDATE SKIP LOCKED`, giving each partition exactly one owner at a time: concurrent assistants, or
  an assistant and `retain()`, never double-invoke hooks and never log a spurious `retain_hook_fail` from
  a lock race. `retain()` is now a loop over `retire()`, with its signature, return value,
  `retain_batch` pacing, and failure isolation unchanged. (issues #195, #188; tests/60, including a
  live two-session claim test via dblink)

- **Docs: a worked S3-archival `pre_drop` hook (`docs/archive-to-s3.md`).** A complete, user-supplied
  hook that copies a partition's rows to S3 as NDJSON before `retain()` drops it, and blocks the drop
  when the copy fails: the `http` extension for the synchronous PUT (with the honest account of why
  `pg_net` cannot do this job), AWS SigV4 signing via `pgcrypto`, credentials in Vault, paced by
  `retain_batch = 1`. The exact function was verified end-to-end through the real `retain()` path,
  twice: against MinIO's SigV4 enforcement (archive + drop, outage blocking the drop, the paced backlog
  draining after recovery), and against a live Supabase project archiving to Supabase Storage's
  S3-compatible endpoint (same lifecycle, plus a real S3 rejection logged verbatim and deferring the
  drop). The Storage run hardened the example's path-style branch: an endpoint may carry a path prefix
  (Storage's `/storage/v1/s3`), so the Host header and the canonical URI are split out of the endpoint
  instead of assuming a bare host. A **multipart variant** lifts the single-PUT memory ceiling: it
  keyset-paginates the partition on the control column and streams it through S3 multipart upload
  holding at most one ~8MiB part in memory (small/empty partitions short-circuit to the plain PUT),
  aborting the in-flight upload on any failure so no invisible incomplete parts accrue. Verified
  through the real `retain()` path against both MinIO and a live Supabase project on Supabase
  Storage's S3 endpoint: 3-part uploads with every row account-checked across part seams (identical
  composite ETags on both stores), the fast path, a simulated mid-part network failure (abort
  confirmed on the store via `ListMultipartUploads`, drop blocked), and a clean retry. Linked from
  the guide's pre-drop-hooks section, `hook_register` in the reference, and the README.
- **`retain_batch`: pace retention drops across maintenance ticks.** `config.retain_batch` caps how many
  eligible partitions one `retain()` call will attempt (hooks + drop), oldest first; the rest of an
  aged-out backlog waits for later ticks, each its own transaction on the `pg_cron` path -- the
  `drain_batch` shape, applied to drops. `null` (the default) is unbounded, the prior behavior. The cap
  bounds attempts, not successes: a failing `pre_drop` hook at the head of the backlog defers everything
  behind it until it clears. The motivating case is a slow synchronous `pre_drop` hook (e.g. copying a
  partition to long-term storage before it ages out): `retain_batch = 1` bounds each tick's lock and
  transaction time to one partition's hooks + drop. `pgpm.status()` gains `retain_backlog` -- eligible
  partitions not yet dropped; falling tick over tick is a paced backlog draining, flat with
  `retain_hook_failures` climbing is retention wedged on a failing hook. (issue #189; tests/59)
- **Lifecycle hooks: a `pre_drop` hook fires before `retain()` drops a partition.** The first hook in what
  is meant to grow into a general registry (`pgpm.hook`), for use cases like copying a partition's
  contents to long-term storage (e.g. S3) before it ages out. Register with `pgpm.hook_register(parent,
  'pre_drop', hook_fn)`, where `hook_fn` is a `function(parent regclass, child name, lo text, hi text)
  returns void`; `hook_register` validates the function exists with that exact signature up front
  (`regprocedure`), instead of discovering a bad reference the next time `retain()` calls it. Each
  partition's hooks + drop are isolated in their own subtransaction inside `retain()`'s loop: a hook that
  raises blocks only that partition's drop (logged `retain_hook_fail`, retried on the next `retain()`
  call) without undoing drops already committed earlier in the same call, and without re-invoking hooks
  already run for other partitions (not assumed idempotent). Multiple hooks on the same event run in
  registration order; a disabled hook (`hook_register(..., p_enabled => false)`) never runs.
  `pgpm.status()` gains `retain_hook_failures`, counted the same since-last-progress way as `drain_skips`.
  (tests/58)
- **`from_hypertable` builds the cutover key index once.** With `p_track_changes`, the destination's
  reused-key index was built twice off the lock: once as a throwaway for the online delta drain's per-batch
  key lookups, then again as the real `PRIMARY KEY`/`UNIQUE` index the cutover adopts. Now `from_hypertable_copy`
  pre-builds the reused-key index once -- with the same temp name and definition the cutover adopts -- so the
  delta drain uses it and the cutover's index pre-build loop, now re-entrant, **adopts** it (`USING INDEX`,
  metadata-only) instead of rebuilding. One key-index build instead of two, all still off the lock, so no
  change to the brief `ACCESS EXCLUSIVE` window (it removes redundant `O(rows*log rows)` work from total
  migration time, which matters at large scale). Append-only / non-tracking and keyless paths are unaffected.
  (issue #175; tests/timescale/db/14)
- **`from_hypertable` pre-drains the append-only catch-up online too (default, non-tracking path).** Without
  `p_track_changes`, the cutover caught up every row appended past the copy watermark in one `insert ...
  where control > watermark` *under the lock*, so that window grew with the copy -- the same wound #170
  closed for the tracking path, still open for the default. New `from_hypertable_drain_appends` (a `_step` +
  driver, mirroring the #170 delta drain) copies that tail **online, in bounded batches that advance the
  watermark**, so the locked catch-up applies only the final tail. It is purely additive (append-only means
  copied rows never change), so unlike the delta drain it needs no delta, no reconcile, no key, and no dest
  index, and works on a **keyless** hypertable (the common shape); each batch is bounded to the control
  value `p_batch` rows past the watermark and **inclusive of ties** at that bound (so no tie straddling a
  batch boundary is dropped), as literal constants for chunk exclusion. The cutover runs it automatically
  (`p_predrain`, default `true`) for the non-tracking path, and the watermark read that drives the under-lock
  catch-up now happens **before** the lock, so an `O(rows)` `max()` seqscan on a keyless dest is no longer in
  the blocking window. (issue #174; tests/timescale/db/15)
- **`from_hypertable` drains the change-capture delta online, before the cutover lock.** With
  `p_track_changes`, the cutover reconciled the *entire* delta under the `ACCESS EXCLUSIVE` lock -- and the
  delta is every key touched for the whole online-copy duration, so the locked window grew with the table it
  is meant to migrate quickly. New `from_hypertable_drain_delta` (a `_step` + driver pair, mirroring
  `drain`) reconciles the delta **online, in bounded micro-batches, while the source stays live**, chasing
  the backlog down so the lock applies only a tiny residual. The reconcile is idempotent and
  order-independent per key, which makes incremental draining safe; it delete-RETURNS each batch from the
  delta as the authority and reconciles exactly those keys against the live source (so a change is never
  deleted-without-applying), bounded per batch to the touched control range for chunk exclusion. The cutover
  now runs this pre-drain automatically (best-effort, new `p_predrain` default `true`); under sustained write
  load it stops at a residual threshold and the under-lock pass -- still the correctness backstop -- finishes
  the rest, or a convergence budget fails loudly. The delta gains a monotonic `pgpm_seq` ordering column for
  the batch watermark. Also closes a pre-existing silent-loss hole: tracking is now refused on a key with a
  nullable (non-control) column, since a `NULL` key component can never be reconciled. (issue #170,
  supersedes #165; tests/timescale/db/14)
- **`transmute` and `untransmute` preserve an identity sequence's exact position.** Both reseeded the
  identity sequence to `max(id) + 1`, which is correct only when the sequence sits at its max. A sequence
  **ahead** of `max(id)` -- from rolled-back inserts, sequence caching, or deleted high rows -- would then
  re-issue ids it had already handed out. Both now capture the original sequence's next value up front and
  seed to the greater of `max(id) + 1` and that value, so a transmute (and a transmute/untransmute round
  trip) never moves the sequence backward over ids already issued. The common case (a sequence at its max)
  is unchanged. (This generalises the `from_hypertable`-specific preservation to plain `transmute`.)
  (tests/56)
- **`from_hypertable` warns about transient disk use up front.** The online copy writes a full second table
  before cutover, so the migration transiently needs roughly the source's current size in extra disk
  (reclaimed when the old hypertable is dropped at cutover). `from_hypertable_preflight` now raises a
  `NOTICE` with that estimate, and a new `from_hypertable_disk_estimate(p_hypertable)` returns it as `bigint`
  (the total on-disk size across all chunks) so a volume can be sized ahead of time. (tests/timescale/db/12)
- **`from_hypertable` preserves the source identity sequence's exact position.** `transmute` seeds a
  migrated identity sequence to `max(id) + 1`, which is correct only when the sequence sits right at its
  max. A sequence that is **ahead** of `max(id)` -- from rolled-back inserts, sequence caching, or deleted
  high rows -- would then re-issue ids the source had already moved past. `from_hypertable` now captures each
  source sequence's next value before the cutover and advances the migrated sequence to it (when higher)
  after the transmute handoff, so the next generated id continues from where the source left off. (Plain
  `transmute` of a non-hypertable still seeds to `max(id) + 1`; this preservation is specific to the
  `from_hypertable` path, which discards the source sequence object during the copy.) (tests/timescale/db/11)
- **`from_hypertable` can migrate update/delete workloads online (trigger-based change capture).** The
  default cutover catch-up is append-only (rows past the copy watermark), which silently loses UPDATEs and
  DELETEs to already-copied rows that arrive during the online window. Pass `p_track_changes => true` and
  `from_hypertable_copy` installs an `AFTER INSERT/UPDATE/DELETE` row trigger on the source that logs the
  touched key values to a `<rel>_pgpm_delta` table; the cutover reconciles every touched key against the
  live source (delete each dirty key's copied row, then re-insert its current source row, which is
  idempotent and order-independent and covers inserts, updates, and deletes). The cutover auto-detects the
  apparatus, so the two phases cannot disagree, and cleans it up inside the swap transaction. Reconciliation
  is by the key `transmute` reuses (a primary key or unique constraint), so tracking is refused up front on
  a keyless table rather than silently falling back. Default stays `false` (append-only, no trigger
  overhead). (tests/timescale/db/10)
- **CHECK constraints reach the partitioned parent (bug fix).** `transmute` built the parent with `LIKE`
  but without `INCLUDING CONSTRAINTS`, so the user's CHECK constraints stayed on the monolith child only --
  the parent, the DEFAULT, and future forward partitions did not enforce them (a silent gap: new rows in
  new partitions escaped the CHECK). The parent is now built `INCLUDING CONSTRAINTS`; the transient
  `pgpm_monolith_bound` CHECK that `LIKE` also copies is dropped from the parent (the monolith keeps its
  own copy for the metadata-only attach). CHECK constraints now propagate to every partition. (tests/55;
  tests/timescale/db/07)
- **Generated columns are supported (bug fix).** `drain`, `regrain`, and `from_hypertable` move rows by
  building an explicit column list, which wrongly **included generated columns** -- so the move failed
  with `cannot insert a non-DEFAULT value into a generated column`. Two fixes: omit generated columns from
  those INSERT lists (they recompute on insert), and create the destination/partition child with
  `INCLUDING GENERATED` so its generated column matches the parent (otherwise the attach failed with
  `column ... must be a generated column`). A table with a STORED generated column now drains, regrains, and
  migrates correctly, with the generated value recomputed on the destination. (tests/54;
  tests/timescale/db/09)
- **`from_hypertable` hardening tests.** Added retention translation (a `drop_chunks` policy becomes pgpm
  `retain`), schema fidelity (the parent carries the primary key including the control column, secondary
  indexes, column defaults, and NOT NULL), and abort/rollback (nothing is irreversible before cutover; a
  failure inside the cutover transaction rolls back whole and leaves the source intact) -- run across both
  fleet TimescaleDB versions. (tests/timescale/db/06-08)

- **The `from_hypertable` CI track runs against the fleet's TimescaleDB versions, not just one.** It is now
  a matrix over the two big Supabase clusters, **2.9.1** (~224 projects) and **2.16.1** (~434), on PG15
  (set `TS_VERSIONS` to override). The full track passes on both, confirming the migration (including the
  `drop_chunks` retention auto-translation, which reads the version-sensitive jobs catalog) works on 2.9.1.
- **`from_hypertable` exposes its phases, with an online append-only catch-up.** The migration is split
  into `from_hypertable_copy` (build the destination and bulk-copy the existing chunks to a watermark,
  source stays live) and `from_hypertable_cutover` (catch up rows that arrived after the watermark, swap
  the copy in, hand off to transmute); `from_hypertable` runs both back to back. Driving them separately
  lets writes keep arriving during the migration: appends written between copy and cutover (control > the
  copy watermark) are caught up at cutover, so no row is lost. (tests/timescale/db/05)
- **`from_hypertable` preserves identity columns.** A hypertable with an identity/sequence column (e.g. a
  composite `(id, ts)` PK with `id GENERATED ... AS IDENTITY`) kept losing it on migration: `CREATE TABLE
  (LIKE ...)` does not carry identity, so the destination's column became a plain column and inserts that
  omitted it failed. `from_hypertable` now captures the source's identity columns and re-establishes the
  property on the destination before the transmute handoff (which reseeds the sequence past the max
  migrated value), so writes that omit the column keep auto-generating without collision. Normalised to
  `GENERATED BY DEFAULT`, matching transmute. (tests/timescale/db/04)

- **`transmute` partitions keyless tables; `from_hypertable` migrates keyless hypertables.** The key is
  now optional: the only hard requirement is a **`NOT NULL` control column**. A primary key or unique
  constraint that includes the control column is still reused in place when present, but a table with
  neither is now partitioned **keyless** (no key synthesized, faithful to the source) instead of refused.
  This is the common "Timescale as a partition manager" shape -- `create_hypertable` makes the time column
  `NOT NULL` but adds no key -- so `from_hypertable` drops its keyless refusal and migrates those
  hypertables (tests/timescale/db/03; tests/timescale/db/01 updated). A nullable control column, a key that
  *excludes* the control column, and a bare unique index are still refused with guidance. One limitation:
  `regrain` is unavailable on a keyless monolith (no key to dedup a resumable copy), so its history stays as
  one coarse, queryable child; `regrain` raises a clear error rather than failing obscurely. (tests/52;
  tests/32 removed as obsolete, tests/25 updated.)
- **`regrain` reuses the same key `transmute` did (bug fix).** `regrain`'s resumable copy identifies rows by
  the reused key, but it was built from the **primary key only** -- so on a monolith whose reused key is a
  *unique constraint* (the case the previous entry added) it produced malformed SQL (`... where )`) and
  failed. It now uses the primary key or the unique constraint, matching `transmute`. (tests/53)
- **`transmute` reuses a unique constraint, not just a primary key.** The key contract is relaxed: the
  control column must be part of a **primary key OR a unique constraint** (Postgres requires a partitioned
  table's key only to *include* the partition key). `transmute` reuses whichever exists in place, with no
  rebuild: the parent adopts the monolith's existing constraint index (`ADD PRIMARY KEY` adopts a child PK
  index, `ADD UNIQUE` adopts a child unique-constraint index; both metadata-only, verified on PG 15-18).
  This is faithful -- no primary key is synthesized when the source had only a unique constraint -- and it
  unblocks tables (e.g. time-series with a `UNIQUE (device_id, ts)` and no PK) that previously could not be
  partitioned at all. The control column it covers is required to be `NOT NULL` (a primary key guarantees
  this; for a unique constraint it is checked, never scanned). A *bare* unique index (not a constraint) is
  refused with guidance to promote it metadata-only via `ADD CONSTRAINT ... UNIQUE USING INDEX` (`ADD
  UNIQUE` would otherwise rebuild it); a table with no primary key and no usable unique constraint is still
  refused. Incoming-FK preservation now accepts an FK that references the reused unique constraint, not
  only the primary key. (tests/49-51; tests/32 updated for the relaxed contract)
- **The bounded-child transmute redesign: the original table becomes a "monolith" partition, not the
  `DEFAULT`; the history is split on demand by `regrain`.** This supersedes the metadata-only-cutover and
  `DEFAULT`-as-store framing of the entries below. `transmute` now renames the original aside and attaches
  it, intact, as one bounded coarse **monolith** child covering `[grid_floor(min), B)`, under a fresh
  **empty `DEFAULT`** safety net: still no row movement, but the cutover does one online, read-only
  `VALIDATE` scan (under a non-blocking `SHARE UPDATE EXCLUSIVE` lock) before the brief metadata-only
  rename/attach. The historical bulk no longer drains row-by-row; it stays in the monolith until
  **`regrain()`** splits it into proper partitions by **copying** (no dead tuples, no vacuum), atomically
  (synchronous `regrain` / `regrain_history`) or paced across maintenance ticks (`set_regrain` auto-regrain,
  budget-feathered like the drain). Regrain is retention-aware (below-horizon sub-ranges are skipped, not
  materialized) and optional (a coarse monolith is a correct, permanent state). The drain is demoted to a
  **sideline**: it keeps the empty `DEFAULT` empty by evacuating strays, so `obtain` takes a cheap
  scan-free attach. `status()` gains `coarse_partitions` and `history_unregrained` (the regraining backlog);
  `untransmute`'s gate is now monolith/data-based (reversible until a row lands outside the monolith or
  regraining begins); `maintain` suspends preserve-managed incoming FKs around the drain's row movement (a
  copy-`regrain` needs no such leash; its swap handles the FK atomically -- see the regrain-copy fix below).
  Partitions wider than one step are named `_p<lo>_to_<hi>`. (PRs #116-#119, #123; tests/42-47; REDESIGN.md)
- **`regrain` copies instead of moving (correctness fix for the redesign above).** The first implementation
  of `regrain_step` was inadvertently a clone of the drain: it `DELETE`d rows out of the coarse source and
  re-`INSERT`ed them into unattached children, contradicting the design's *copy, never delete*. That bloated
  the source with dead tuples and reopened the `snapshot()` read gap that copy-then-swap exists to avoid --
  a paced auto-regrain **undercounted** the parent mid-regrain. `regrain_step` now **copies** each frozen
  sub-range into a standalone born-validated child (budget-sized anti-join `INSERT`s resumed from the
  child's high-water mark, progress tracked across ticks by a new `config.regrain_cursor`) and **skips**
  below-horizon sub-ranges without deleting (discarded with the source at the swap); the source stays whole
  and **attached** until one atomic swap, so a read of the parent is never short. Three consequences follow
  from the source staying attached: `snapshot()` no longer unions a regrain's copy-children (their rows are
  still in the monolith, so it would double-count); `restore_incoming_fks` no longer counts them as in-flight
  drain children; and `maintain` no longer suspends an incoming FK for a regrain. The multi-tick copy needs no
  FK leash -- only the swap's `DETACH` does (Postgres refuses to detach a partition whose rows are still
  referenced), so the swap transiently drops and re-adds the FK within its one atomic transaction (no visible
  RI window, unlike the drain's). Log actions are `regrain_copy` / `regrain_aged` (were `regrain_move` /
  `regrain_reclaim`). (PR #128; new tests/48, tests/47 rewritten, tests/07/45/46 updated)
- **Docs rewritten for the monolith model; `DESIGN.md` retired.** The reference, guide, README, and runbook
  are rewritten from scratch against the current API; `REDESIGN.md` is now the canonical design note (the
  original `DESIGN.md`'s enduring supply/demand operating model is folded into it) and `DESIGN.md` is
  removed.

- **The `transmute` redesign: one function, metadata-only, never rewrites the primary key.** The three
  entry points (`transmute` / `transmute_by_id` / `transmute_by_uuidv7`) collapse into a single overloaded `transmute`:
  a `bigint` width selects the integer grid, an `interval` width the time grid, with `time` vs `uuidv7`
  inferred from the control column's type. Bare interval literals must cast: `transmute(t, c, interval '1
  month')`. `transmute` no longer drops or rebuilds the primary key, so the cutover is always metadata-only:
  it reuses the existing PK when the control column is a member of it (Postgres requires only that a
  partitioned PK include the partition key, not lead it, so `PK (tenant_id, id)` partitioned by `id`
  qualifies), and refuses (with a suggested migration) a table whose primary key excludes the control
  column, or that has no primary key at all (pgpm does not support no-PK tables), betting on a
  time-ordered primary key (Snowflake bigint / UUIDv7 / ULID) as the data model. Forbidding PK rewrites removed `build_pk_concurrently`, the composite-FK recovery
  path (`generate_fk_recovery`, the `'drop'` incoming-FK mode, the `dropped_fk` composite columns), and
  the build-path complexity; every incoming FK is now the `preserve` path. (tests/25)
- **Retention reclaims the un-drained `DEFAULT` tail (issue #91).** When the drain lags, an interval
  that ages past `retain` while still in the `DEFAULT` is now reclaimed in place: the drain `DELETE`s it
  straight out of the `DEFAULT` (paced like a microbatch, logged as `retain_reclaim`) instead of
  materializing a partition that `retain` would immediately drop. Retention now bounds storage even on a
  never-completing drain, and the materialize-then-drop churn is gone. `retain()` itself is unchanged (a
  cheap `DROP` of materialized partitions). (tests/34)
- **`status()` distinguishes a wedged drain from a slow one (issue #92).** It gains `closed_rows` (the
  drainable backlog, the same value `check_default` reports), `last_drained` (when the drain last made
  progress), and `drain_skips` (deferrals logged since that progress). A non-zero `closed_rows` with a
  stale `last_drained` and a climbing `drain_skips` is a wedged drain (e.g. the upsert/duplicate-key
  wedge); a healthy slow drain shows `closed_rows` falling and `drain_skips` near zero. (tests/35)
- **transmute refuses a random-uuid control column (issue #96).** A `uuid` control column is treated as
  `uuidv7` on assumption; when it samples as overwhelmingly random (UUIDv4 -- a plausibility fraction
  below 0.5), transmute now refuses rather than only warning, since range-partitioning a
  non-time-ordered key scatters rows across meaningless partitions on a garbage frontier (mirroring the
  float-key and PK refusals). A new `p_force_uuidv7 => true` overrides it for an operator certain the
  column is time-ordered. (tests/13, tests/39)
- **The block budget no longer disables itself when row stats are missing (issue #93).**
  `drain_max_blocks` translates to a row cap via the default's average bytes/row. When `reltuples <= 0`
  (a freshly transmuted or never-analyzed default -- the early-drain window when it is largest and
  widest) the budget previously fell back to the raw `drain_batch` row count, so a batch of wide
  incompressible rows could be the multi-GB spike the feature exists to prevent. It now estimates the
  average by sampling `pg_column_size` (cheap and TOAST-aware), so the budget holds even before ANALYZE.
  (tests/36)
- **The adaptive ambient signal no longer depends on `pg_monitor` (issue #98); pg_cron is again the only
  runtime dependency.** The consumer-priority signal previously read `pg_stat_activity.wait_event`, which
  Postgres masks for other roles unless the reader holds `pg_monitor`. It is rebuilt from two
  role-independent terms, OR'd, on catalogs any unprivileged role reads in full: a **lock-wait** count
  from `pg_locks` (non-pgpm backends blocked on an ungranted lock) and a **read-I/O latency** from
  `pg_stat_database` (ms/block, inert when `track_io_timing` is off). Both are self-calibrating (EWMA
  baseline + relative surge) like before; the `drain_ambient_*` knobs are unchanged, with new controller
  state `drain_ambient_io_baseline` / `drain_io_read_time` / `drain_io_blks_read`. `_ambient_io_waiters()`
  is replaced by `_ambient_lock_waiters()`. (tests/26, tests/41)
- **A non-PK UNIQUE secondary index is no longer silently dropped (issue #90).** transmute now carries
  it onto the parent as a partitioned unique index when its key includes the partition key (global
  uniqueness genuinely preserved, exactly as the PK is reused), and refuses with guidance when it
  excludes the partition key, or is partial/expression (global uniqueness cannot be enforced on a
  partitioned table) -- the same refuse-or-preserve contract as the PK and incoming-FK cases, instead of
  a `raise notice` that quietly lost the guarantee. (tests/33)
- **An in-flight (unattached) drain child is now tracked in pgpm's catalog (issue #94).** The drain
  creates each child standalone and attaches it only when the interval has fully moved; that child is
  now recorded in `pgpm.part` with a new `attached` column set `false` at creation and flipped `true` at
  the attach, instead of being discoverable only by scanning `pg_class`. `status()` gains
  `inflight_partitions` (and `n_partitions` now counts only attached partitions); `pgpm.partitions`
  exposes `attached`; `retain` only drops attached partitions, never an in-flight one. (tests/37)
- **A preserve-managed incoming FK can no longer be permanently bricked by an orphan, and its state is
  visible (issue #95).** `restore_incoming_fks` now splits the re-add: `ADD CONSTRAINT ... NOT VALID`
  (enforces every new write, always succeeds) is committed separately from `VALIDATE`. An orphan written
  while the FK is suspended (RI is off for the drain's duration -- inherent) used to make `VALIDATE` fail
  and roll the whole re-add back, so the FK was never restored, silently. Now the FK comes back enforcing
  new writes immediately and a blocked `VALIDATE` leaves it `NOT VALID`, surfaced by the new
  `status().fks_unvalidated`. New `pgpm.incoming_fk_orphans(parent)` lists the blocking rows and
  `pgpm.validate_incoming_fks(parent)` finishes validation once they are cleared; `status().fks_suspended`
  surfaces the RI-off window. `pgpm.dropped_fk` gains a `validated_at` column. (tests/38)
- **Docs: clarified that retention is a standing floor, not just an aging process (issue #97, closed as
  working-as-intended).** A row inserted with a control value already past the horizon (a backdated or
  late-arriving event) is reclaimed by the next maintenance cycle, exactly as any retention system would
  drop it -- the `INSERT` succeeds and a later transaction removes it per the policy you set. To keep
  late-arriving data, retain on an ingestion timestamp or widen the window. Pinned by tests/40.
- `transmute(..., p_incoming_fks => 'preserve')` + `pgpm.restore_incoming_fks` / `pgpm.suspend_incoming_fks`:
  keep incoming foreign keys across the conversion. Since `transmute` never rewrites the PK, the referenced
  unique key always survives, so `'preserve'` drops each incoming FK for the conversion, records it in
  `pgpm.dropped_fk`, and re-adds it verbatim against the new parent (`NOT VALID` + `VALIDATE`) once the
  drain is idle. `maintain` manages the lifecycle: a managed FK is live only while the closed tail is
  empty, so it suspends (re-drops) a live FK before a drain that would move referenced rows and restores
  it after, and a later obtain-miss drain neither stalls (`NO ACTION`) nor silently deletes/nulls the
  referencing rows (`CASCADE` / `SET NULL`). Referential actions, `DEFERRABLE`-ness, and self-referential
  FKs are preserved (the self-ref re-add is validating, not online). `pgpm.dropped_fk.restored_at` tracks
  the live/dropped state. (tests/19-24)
- `transmute` no longer runs `obtain` inside its transaction. Attaching a partition to a
  parent whose DEFAULT already holds data makes Postgres scan the default, and inside
  transmute's `ACCESS EXCLUSIVE` transaction that scan blocked all access for its duration
  (~minutes per premade partition at scale). `transmute` now does the metadata-only cutover
  only (a fresh parent with just the DEFAULT attached scans nothing), so it stays online
  even on a 100GB+ table. Run `pgpm.obtain()` / `pgpm.maintain()` afterward to build
  the future partitions online (their `VALIDATE` scans run under a non-blocking lock).
  Until then, writes route to the DEFAULT (correct, just not yet split into future cells).
- `maintain` no longer lets an obtain/retain failure abort the drain. Obtaining a
  future partition needs `ACCESS EXCLUSIVE` on the parent plus a scan of the DEFAULT, which
  contends with concurrent inserts into the default's open cell; under sustained write load
  the two sides could deadlock, and because obtain ran first in the same transaction the
  deadlock aborted the whole maintenance run, so the drain never made progress. `maintain`
  now caps lock waits (`lock_timeout`, turning a would-be deadlock into a fast retryable miss)
  and isolates obtain, retain, and the drain in separate subtransactions: a step that
  loses the lock race is deferred (logged as `*_skip`, retried next tick) without aborting the
  drain. The closed-tail drain attaches via the scan-skip path, so it keeps converting the
  table online even while obtain repeatedly defers under load. Two further safeguards keep
  obtain from disrupting the workload under sustained writes: (a) obtain/retain use a very
  short `lock_timeout` so a lost lock race fails in milliseconds -- barely blocking the workload,
  and bailing before obtain's `VALIDATE` scan of the default; (b) after a deferral, obtain
  backs off (a window recorded in `pgpm.config.obtain_retry_after`) instead of retrying every
  tick. The drain keeps a longer `lock_timeout` so its infrequent, must-win attach isn't starved.
- `drain_step`'s "any rows left in this range?" check now uses `EXISTS` instead of `count(*)`.
  The old `count(*)` re-scanned the entire remaining range after every microbatch -- O(rows^2 /
  batch) work, and while the default is not all-visible mid-drain the planner seq-scans the
  range each step (a sequential-scan storm that dominates I/O at scale). `EXISTS` stops at the
  first row (index scan), which is all the drain needs to decide between draining and attaching.
- `transmute` no longer scans the table to advance identity sequences. After the cutover it advances
  each identity sequence past the largest existing value -- but transmute has just swapped the PK to
  `(control, id)`, leaving no id-leading index, so the old `select max(id)` seq-scanned the whole
  DEFAULT under transmute's `ACCESS EXCLUSIVE` lock: O(rows), a multi-minute blocking step at 100GB+
  scale that undercut the metadata-only cutover. `transmute` now captures `max(identity)` up front --
  while the table's original id index still exists, so it is an index lookup -- and reuses it to
  advance the (freshly recreated) parent sequence. The cutover stays metadata-only at any size.
- `transmute` reuses the existing PK when the partition key already covers it. For `id` / `uuidv7`
  tables the computed PK columns equal the existing PK, so transmute no longer drops and rebuilds an
  identical index -- it reuses the index in place. In the common case the one-time setup cost center
  collapses to zero and only the drain remains. Flat (single-digit ms) to ~40M rows. (tests/15)
- `drain_max_blocks` config: block-budgeted drain batching. Batching by a fixed row count is unsafe
  when row width varies (20 000 rows each carrying a 2 MB document is tens of GB rewritten in one
  microbatch). When set, `drain_step` caps each microbatch at roughly that many heap+TOAST blocks
  (translated to a row limit via the default's average bytes/row) and takes the smaller of that and
  `drain_batch`; when null it falls back to the row cap unchanged. (tests/17)
- `pgpm.check_time_monotonic(parent, key_col, time_col)`: an additive, read-only co-monotonicity
  check, the tier-2 safety gate for a future key-to-time retention bridge (calendar retention on an
  id-partitioned table). It samples whether the id and timestamp rise together and reports the
  fraction in order, analogous to `check_uuidv7`'s plausibility sampling. (tests/16)
- `transmute` now refuses up front when an orphaned child-partition table exists. A drain creates each
  child as a standalone table (`CREATE TABLE ... LIKE`) and ATTACHes it only at the end of that
  child's drain, so an interrupted drain leaves an un-attached child -- which `DROP TABLE <parent>
  CASCADE` does not remove (no dependency on the parent). Re-transmuting the recreated table would let
  the next drain reuse the orphan by name and collide on its stale keys, surfacing as a cryptic
  mid-drain "duplicate key" deep inside `drain_step`. `transmute` now detects any standalone
  (un-attached) table whose name matches this parent's child-partition naming and raises a clear,
  actionable error instead. (tests/18)

## [0.1.0] - 2026-06-19

Initial release of pg_partition_magician.

- Pure-SQL online RANGE-partition manager (schema `pgpm`); only runtime dependency is pg_cron.
- Partition dimensions: `time`, `id` (bigint/numeric, incl. Snowflake-style), `uuidv7`/ULID-as-uuid. float/double rejected.
- `transmute` / `transmute_by_id` / `transmute_by_uuidv7`: online conversion of an existing table (attach as DEFAULT, no rebuild of the default's PK index).
- obtain ahead of the write frontier; paced microbatch drain of the DEFAULT's closed tail (scan-skip attach); retain; maintenance via pg_cron.
- Incoming-FK handling: refuse by default, opt-in drop+record, and `generate_fk_recovery()`.
- Three install channels (psql / bundle / dbdev-TLE) built from one source; PG 15-18 channel test matrix; 53 pgTAP tests.

-- =============================================================================
-- pg_partition_magician  --  a lightweight, pure-SQL range-partition manager
--
--   * Only runtime dependency: pg_cron (and only for scheduling). No compiled
--     extension. Install with: psql -f this_file.sql.  Schema: pgpm.
--   * Manages the full lifecycle of native RANGE-partitioned tables: transmute an
--     existing (possibly huge, live) table online, obtain ahead of the write
--     frontier, archive, retain, regrain, all via maintenance.
--
-- Control-type contract -- a column works as the partition key if it is:
--   (a) RANGE-partitionable (btree-ordered),
--   (b) monotonic with insertion within a bounded lag,
--   (c) has EXACT, reproducible grid arithmetic (gapless, stable boundaries),
--   (d) free of unordered/extreme values that poison the frontier (NaN/Inf/wrap).
--
-- Supported control_kind:
--   'time'      -- timestamptz/timestamp/date, interval step (calendar-aligned)
--   'id'        -- int/bigint/NUMERIC, integer step (covers Snowflake-style ids)
--   'uuidv7'    -- uuid whose leading 48 bits are a ms timestamp (also ULID-as-uuid);
--                  time grid, boundaries encoded as uuids
--   'text_time' -- text/varchar shaped <constant prefix><fixed-width base-N encoded
--                  count>: classic cuid, KSUID, ULID-as-text, MongoDB ObjectId. The
--                  shape is declared (p_tt_prefix/width/radix/unit, plus
--                  p_tt_alphabet/discard_bits/epoch for formats that need them), not
--                  detected.
-- float/double are explicitly rejected (imprecise boundaries; NaN/Inf).
--
-- The engine is kind-agnostic: all type-specific logic lives in a small adapter
-- (_grid_floor/_grid_next/_encode/_decode/_frontier_native/_part_name). Bounds are
-- carried as text so one code path serves every kind.
--
-- NAMING: a local ending in `_q` holds text whose identifiers are ALREADY QUOTED --
-- typically `string_agg(quote_ident(attname), ', ')` over a column list. Splice those
-- with `%s`; `%I` would quote them a second time, into garbage. A local WITHOUT the
-- suffix is raw and needs `%I`. The suffix exists because the two look identical at
-- the call site, so an edit could swap one for the other and nothing would read as
-- wrong (issue #409). scripts/check_quoted_splices.py enforces it in both directions
-- across this file, pgpm_hypertable and pgpm_archive, and CI runs it.
-- =============================================================================

create schema if not exists pgpm;

create table if not exists pgpm.config (
  parent_table     regclass    primary key,
  control_column   name        not null,
  control_kind     text        not null default 'time'
                   check (control_kind in ('time', 'id', 'uuidv7', 'text_time')),
  partition_step   text        not null,    -- '1 month' (time/uuidv7/text_time) | '10000000' (id)
  partition_anchor text        not null,    -- '2000-01-01...' (time/uuidv7/text_time) | '0' (id)
  obtain          int         not null default 30,
  retain        text,                    -- interval (time/uuidv7) | bigint count (id); null = keep
  regrain_batch    int         not null default 5000,   -- rows per regrain COPY microbatch
  paused           boolean     not null default true,
  created_at       timestamptz not null default now(),
  -- when maintenance may next attempt obtain for this parent. Under sustained write contention obtain
  -- keeps losing the ACCESS EXCLUSIVE race on the parent, so on a deferral maintenance backs it off
  -- instead of retrying every tick. null = attempt now.
  obtain_retry_after timestamptz,
  -- optional block budget for a regrain microbatch: cap it at ~this many heap+TOAST blocks (translated
  -- to a row limit via the coarse child's average bytes/row), so wide rows cannot make a single batch
  -- huge. null = cap by regrain_batch rows only (default).
  regrain_max_blocks int,
  -- text_time only (general opaque-sortable-TEXT-id support: cuid, KSUID, ULID-as-text, ObjectId): the
  -- value is <text_time_prefix><fixed-width base-text_time_radix encoded count>. Null for every other
  -- kind. _encode/_decode are the only functions that ever read these -- grid math operates on the
  -- already decoded native timestamptz, identically to time/uuidv7, so nothing else needs them.
  text_time_prefix       text,
  text_time_width        int,
  text_time_radix        int,
  text_time_unit         text,       -- 'ms' or 's'
  -- alphabet/discard_bits/epoch cover formats the plain cuid/ULID case does not need: a custom digit
  -- alphabet (null = the default contiguous 0-9a-z convention; ULID's Crockford base32 and KSUID's
  -- base62 are NOT that), and a timestamp that is the top bits of a WIDER encoded value rather than the
  -- whole field (KSUID base62-encodes its entire 160-bit payload as one number and a non-Unix epoch;
  -- discard_bits drops the low bits after decoding the whole field, epoch is the zero-point).
  text_time_alphabet     text,
  text_time_discard_bits int,
  text_time_epoch        timestamptz
);
-- upgrade path for installs that predate these columns
alter table pgpm.config add column if not exists obtain_retry_after timestamptz;
alter table pgpm.config add column if not exists text_time_prefix text;
alter table pgpm.config add column if not exists text_time_width  int;
alter table pgpm.config add column if not exists text_time_radix  int;
alter table pgpm.config add column if not exists text_time_unit   text;
alter table pgpm.config add column if not exists text_time_alphabet text;
alter table pgpm.config add column if not exists text_time_discard_bits int;
alter table pgpm.config add column if not exists text_time_epoch timestamptz;
-- the control_kind check predates 'text_time' (issue #325 follow-up); widen it for installs that
-- already have the narrower constraint. Named per Postgres's default inline-CHECK convention
-- (<table>_<column>_check), which is what a fresh pre-text_time install actually produced.
alter table pgpm.config drop constraint if exists config_control_kind_check;
alter table pgpm.config add constraint config_control_kind_check
  check (control_kind in ('time', 'id', 'uuidv7', 'text_time'));
-- #288: the fourteen adaptive-feathering columns are gone with the closed loop they fed, and so are
-- keep_default and default_table. drain_batch/drain_max_blocks survive under regrain_* names: they are
-- regrain's microbatch knobs now, and the old names described a machine that no longer exists.
alter table pgpm.config drop column if exists drain_adaptive;
alter table pgpm.config drop column if exists drain_budget;
alter table pgpm.config drop column if exists drain_ckpt_seen;
alter table pgpm.config drop column if exists drain_wal_lsn;
alter table pgpm.config drop column if exists drain_wal_at;
alter table pgpm.config drop column if exists drain_wal_high_water;
alter table pgpm.config drop column if exists drain_ambient_max_waiters;
alter table pgpm.config drop column if exists drain_ambient_factor;
alter table pgpm.config drop column if exists drain_ambient_alpha;
alter table pgpm.config drop column if exists drain_ambient_floor;
alter table pgpm.config drop column if exists drain_ambient_baseline;
alter table pgpm.config drop column if exists drain_ambient_io_baseline;
alter table pgpm.config drop column if exists drain_io_read_time;
alter table pgpm.config drop column if exists drain_io_blks_read;
alter table pgpm.config drop column if exists keep_default;
alter table pgpm.config drop column if exists default_table;
alter table pgpm.config add column if not exists regrain_batch int not null default 5000;
alter table pgpm.config add column if not exists regrain_max_blocks int;
-- auto-regrain (REDESIGN.md section 12): when set, maintenance feathers the oldest frozen coarse child
-- toward this target step, one budget-sized microbatch per tick. null = off (regrain is operator-driven).
alter table pgpm.config add column if not exists regrain_to text;
-- regrain copy progress (REDESIGN.md section 10): the NATIVE-grid lo of the sub-range currently being
-- copied out of the coarse child under regraining -- a cross-tick high-water mark. regrain COPIES (never
-- deletes), so the source never shrinks and cannot drive progress the way deletes would; this
-- cursor is the explicit progress state instead. null = no regrain in flight; reset to null at the swap.
alter table pgpm.config add column if not exists regrain_cursor text;
-- retain() pacing (issue #189): cap how many eligible partitions ONE retain() call will attempt
-- (write-block, archive-coverage check, drop), so an aged-out backlog spreads across maintenance
-- ticks (each tick its own transaction via pg_cron) instead of one call carrying the whole backlog
-- -- the drain_batch shape, applied to drops. The cap bounds ATTEMPTS, oldest first: with an
-- unexpected drop failure at the head, the partitions behind it are not attempted that call
-- (bounded per-tick work is the point; the wedge is surfaced by status().retain_drop_failures
-- alongside a flat retain_backlog -- issue #238). null = unbounded (prior behavior). A table whose
-- chunked archiving is genuinely still catching up on a large backlog is not a wedge at all: that is
-- retain_backlog falling tick over tick with retain_drop_failures flat at zero.
alter table pgpm.config add column if not exists retain_batch int;
-- the pluggable archive strategy (issue #236): null = strategy 'none' (no archiving, drop as soon as
-- write-blocked). regprocedure (not text/regproc) so a bad reference is refused right here at
-- assignment, not discovered later when a maintenance tick tries to call it. Contract:
-- archive_fn(p_parent regclass, p_child name, p_lo text, p_hi text) returns pgpm.archive_result,
-- called once per tick, expected to make bounded incremental progress and report how much of
-- [lo, hi) is now durably archived (not to finish the whole range in one call). retire()'s drop
-- precondition consults this via pgpm._archive_fully_covered (#238) -- see
-- pgpm._run_archive_strategy and pgpm._archive_noop below.
alter table pgpm.config add column if not exists archive_fn regprocedure;
-- byte-budget chunking knobs (issue #237, porting archive._next_range_byte_budget's own
-- c_byte_budget/c_probe_sample constants): archive_byte_budget estimates how many rows make up
-- roughly this many bytes (via a sampled average row width), and archive_probe_sample caps how many
-- rows that sample scans. Same defaults as the original. Ignored entirely by a 'none' strategy.
alter table pgpm.config add column if not exists archive_byte_budget bigint not null default 8 * 1024 * 1024;
alter table pgpm.config add column if not exists archive_probe_sample int not null default 1000;
-- caps how many DIFFERENT partitions one _archive_step call touches (issue #351; same shape as
-- retain_batch, same "caps attempts, not successes" semantics, and the same null-means-unlimited
-- escape hatch), but a different default: retain_batch's own unlimited default is safe because DROP TABLE is
-- cheap and roughly constant-cost regardless of how many run per tick. Archiving is not -- each
-- partition costs a real read, encode and (with compress on) CPU-bound compression pass, so
-- fanning out over every eligible partition in one tick makes a single maintain() call's duration
-- scale with the SIZE OF THE BACKLOG, not just archive_byte_budget's own per-partition cost. That
-- is invisible until a bulk regrain or backfill leaves many partitions simultaneously eligible at
-- once, at which point it can itself cross statement_timeout regardless of how conservatively
-- archive_byte_budget is tuned. Defaulting to 1 makes archiving strictly sequential -- one
-- partition fully archived (and so retirable) before the next one is even touched -- at the cost
-- of a large backlog taking longer to fully catch up than fanning out would. Raise it (or set it
-- null for the old unlimited behavior) if faster catch-up matters more than that bound.
alter table pgpm.config add column if not exists archive_batch int default 1;

-- Registry of managed partitions (excludes the DEFAULT). lo/hi are NATIVE-grid
-- values as text (timestamptz for time/uuidv7, numeric for id).
create table if not exists pgpm.part (
  parent_table regclass    not null,
  child_name   name        not null,
  lo           text        not null,
  hi           text        not null,
  created_at   timestamptz not null default now(),
  -- false while regrain is still copying rows into this child (created standalone, not yet ATTACHed to
  -- the parent); flipped true at the swap. Lets an in-flight (or stalled, or interrupted) regrain child
  -- be tracked in pgpm's catalog and surfaced by status(), instead of being discoverable only by
  -- scanning pg_class for the name pattern. obtain creates partitions already attached, so the default
  -- is true; only regrain inserts a row with attached=false. (issue #94)
  attached     boolean     not null default true,
  -- When retirement of this child BEGAN -- set as retire() dispatches a CONCURRENT DETACH for it, never
  -- refreshed by a retry, and cleared with the row when the drop completes (issue #268). It doubles as
  -- the tiebreak that keeps exactly one detach in flight, which is why it must not move. Retiring a REFERENCED partition cannot happen in one step: a bare
  -- DROP is refused on the referencing table's per-partition constraint, and the DETACH that severs
  -- it must be CONCURRENT (a plain one holds ACCESS EXCLUSIVE on the managed parent for the whole
  -- O(referencing table) scan) -- which PostgreSQL refuses to run from a function, so pgpm dispatches
  -- it to pg_cron and finishes on a later tick. This marker is what makes that recoverable: a detach
  -- left pending by a dead backend is finalized by _detach_reap, and this says whether the retirement
  -- behind it was pgpm's to complete or an operator's to keep. null for every unreferenced partition,
  -- which never leaves the one-step bare-DROP path at all.
  retiring_at  timestamptz,
  -- WHICH object that retirement meant, by OID, recorded in the same transaction that dispatches the
  -- detach (issue #407). The dispatched command is a fully-formed `ALTER TABLE ... DETACH PARTITION
  -- schema.child CONCURRENTLY` sitting on cron.job until pg_cron's scheduler picks it up a tick or
  -- more later, in a session of its own, and a NAME is all a command text can carry: nothing bridges
  -- that gap, no lock is held on the child across it. If the object answering to schema.child at
  -- execution time is not the one pgpm resolved at dispatch, the detach acts on whatever now holds
  -- the name and the executing session cannot tell the difference -- the same shape as the
  -- SPLIT/MERGE time-of-check/time-of-use bug the #346 audit was about.
  --
  -- Preventing the substitution inside that window is not available to pgpm (see _dispatch_detach for
  -- why the statement has to leave the process at all), so this makes it DETECTABLE at the two points
  -- that still belong to pgpm: retire() refuses to re-dispatch, and refuses the DROP that follows a
  -- successful detach, unless the name still resolves to exactly this OID. The DROP is the
  -- destructive half, and it is the half this anchors.
  --
  -- Null means "no OID was recorded", which is true of every partition on the ordinary one-step drop
  -- path and of a retirement that was already in flight when this column was added. Both read as
  -- unanchored and are left to behave exactly as they did before, rather than wedging an upgrade
  -- mid-retirement on a check that has nothing to compare against.
  retiring_oid oid,
  -- WHICH RELATION this row is about, by OID, recorded where the partition ENTERS this catalog --
  -- obtain's _create_partition, regrain's standalone child, transmute's monolith (issue #421).
  -- child_name is a NAME, and every consumer of it re-resolves that name independently: the archive
  -- step picks a candidate out of this table, _is_write_blocked matches it against pg_class,
  -- _next_archive_chunk reads %I.%I to size the chunk, and the archive_fn is handed the bare string.
  -- None of them could tell that the relation answering to it is the one this row was written for.
  --
  -- That needs no race to go wrong. A name that has stopped meaning what it meant -- an operator
  -- renamed the partition aside, something else took the name -- is a state pgpm already knows is
  -- reachable, which is why pgpm.forget_missing exists; #346 accepted forget_missing's own name-only
  -- matching precisely BECAUSE it is read-only reporting. The archive path is not: a chunk sized
  -- from a substitute's rows becomes a pgpm.archive_ledger row claiming coverage of a range those
  -- rows never came from, and _archive_fully_covered consults that ledger as retire()'s drop
  -- precondition. A bad export therefore does not merely put a wrong object in the bucket -- it
  -- satisfies the gate that authorises a DROP.
  --
  -- Recorded at CREATION rather than at retirement, which is what separates this from retiring_oid
  -- above: that one is set as retire() dispatches a detach, so it is null for every partition the
  -- archive step ever touches. A rename does not change an OID, so regrain's own transitional rename
  -- (#266) updates child_name and leaves this correct with nothing to do.
  --
  -- Null means "no OID was recorded", which reads as unanchored and behaves exactly as before. The
  -- backfill below fills it for every row an upgrade finds resolvable, so an existing install is
  -- anchored from the moment it upgrades rather than only for partitions minted afterward -- but it
  -- can only adopt what is true AT THAT MOMENT. An install upgraded after a substitution has already
  -- happened records the substitute; there is nothing in the catalog that could tell it otherwise.
  child_oid    oid,
  primary key (parent_table, child_name)
);
-- upgrade path for installs that predate these columns
alter table pgpm.part add column if not exists attached boolean not null default true;
alter table pgpm.part add column if not exists retiring_at timestamptz;
alter table pgpm.part add column if not exists retiring_oid oid;
alter table pgpm.part add column if not exists child_oid oid;

-- Backfill child_oid (issue #421). `where child_oid is null` makes this a one-time adoption per row:
-- re-running this installer never re-adopts, so a row anchored at one upgrade is not silently
-- re-pointed at whatever holds its name at the next one.
--
-- An ATTACHED partition is resolved through pg_inherits, not by name, so what gets adopted is a
-- partition OF THIS PARENT by construction -- strictly better than to_regclass, which would take any
-- relation of that name in the schema. A not-yet-attached regrain child is not in pg_inherits at all
-- (it is standalone until the swap), so it has nothing but its name to go on; a row whose name does
-- not resolve is left null and stays unanchored, which is exactly the state forget_missing clears.
update pgpm.part p set child_oid = i.inhrelid
  from pg_inherits i join pg_class c on c.oid = i.inhrelid
 where i.inhparent = p.parent_table and c.relname = p.child_name
   and p.attached and p.child_oid is null;
update pgpm.part p set child_oid = to_regclass(format('%I.%I', n.nspname, p.child_name))::oid
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.oid = p.parent_table and not p.attached and p.child_oid is null;

-- In-flight conversions (issue #275). transmute runs in three transactions -- add the bound, validate it,
-- cut over -- so that the O(rows) validation scan is not held under the ACCESS EXCLUSIVE lock the ADD
-- takes. The cost of that split is that a failure between phases leaves a live `pgpm_monolith_bound` CHECK
-- on the operator's table, which REJECTS any write outside [lo, hi) (a NOT VALID check still enforces new
-- rows). This table is what lets maintenance find and undo that: a half-converted table is not in
-- pgpm.config yet, because registration happens in the cutover, so there is nothing else to look it up by.
--
-- lo/hi are recorded so a resumed transmute reuses the SAME bound rather than recomputing one against a
-- frontier that has since moved.
--
-- owner_pid/owner_backend_start identify the session that claimed the conversion (#405). The row itself is
-- the exclusion -- one per parent_table, by the primary key -- and these two columns are what make the claim
-- releasable without a heartbeat. See pgpm._session_alive.
create table if not exists pgpm.transmute_inflight (
  parent_table  regclass    not null primary key,
  nsp           name        not null,
  rel           name        not null,
  control_kind  text        not null,
  lo            text        not null,
  hi            text        not null,
  started_at    timestamptz not null default now(),
  owner_pid           int,
  owner_backend_start timestamptz
);
-- upgrade path for installs that predate these columns. A claim recorded before they existed has both null,
-- which pgpm._session_alive reads as "no live owner" -- so an old abandoned claim stays reapable rather than
-- becoming permanently stuck behind a liveness check it has no data for.
alter table pgpm.transmute_inflight add column if not exists owner_pid int;
alter table pgpm.transmute_inflight add column if not exists owner_backend_start timestamptz;

-- Is the session that claimed a conversion still alive? (#405)
--
-- This is the liveness signal transmute's claim protocol rests on. It has to tell "the conversion is still
-- running" from "its session died mid-way" with no heartbeat and no timeout guess -- exactly what the session
-- advisory lock it replaces gave for free, since PostgreSQL released that automatically when the session
-- ended, however it ended.
--
-- The trap, measured on stock PostgreSQL 17.10: backend_start is MASKED for a backend owned by ANOTHER role.
-- It reads NULL rather than the real value (pid and usename stay visible; backend_start, backend_type and
-- query do not). The reaper runs from pg_cron under whatever role scheduled it, which need not be the role
-- that ran transmute, so a plain `backend_start = p_backend_start` evaluates to NULL for a perfectly live
-- cross-role conversion -- and the reaper would then undo it out from under itself, dropping the bound and
-- deleting the claim while phase 2's validation scan is still running.
--
-- So the match DEGRADES instead of failing: pid AND backend_start where backend_start is visible to us, pid
-- alone where it is not. The residual failure is UNDER-reaping -- a recycled pid can look like a live
-- conversion, leaving an abandoned bound for an operator's transmute_abort -- and never OVER-reaping a live
-- one. That is the same discipline #98 established for the ambient sensors: read what every role can see,
-- never a column pg_monitor masks (tests/41_no_pg_monitor_dep_test.sql pins it).
--
-- A null p_pid is never alive: there is no session to be alive. That covers both a pre-#405 claim and a row
-- constructed by a test to stand in for a died-mid-run conversion.
create or replace function pgpm._session_alive(p_pid int, p_backend_start timestamptz)
returns boolean language sql stable as $$
  select p_pid is not null
     and exists (select 1 from pg_stat_activity
                  where pid = p_pid
                    and (backend_start = p_backend_start or backend_start is null));
$$;

-- The audit trail. NAMING RULE for `action`: non-success events are PREFIXED, never suffixed --
-- `skip_<mechanism>` for a deferral, `fail_<mechanism>` for a failure. So no non-success action is ever
-- a prefix-extension of the success it corresponds to, and both query styles are safe: `action =
-- 'obtain'` and `action like 'drain%'` match successes only, while `action like 'skip_%'` collects every
-- deferral across all mechanisms without enumerating them.
--
-- This was the other way round (`drain_skip`) and it bit: a guard asserting a tick had drained matched
-- `drain%`, which also matched `drain_skip` -- the exact row a tick writes when it was starved of its
-- locks and did nothing. The guard passed on a tick that had done no work. Do not reintroduce a suffix.
create table if not exists pgpm.log (
  id           bigint generated always as identity primary key,
  parent_table regclass,
  action       text,
  lo           text,
  hi           text,
  method       text,
  rows         bigint,
  at           timestamptz not null default now()
);

create table if not exists pgpm.dropped_fk (
  id                  bigint generated always as identity primary key,
  parent_table        regclass    not null,
  referencing_table   regclass    not null,
  constraint_name     name        not null,
  definition          text        not null,
  -- lifecycle markers for a preserve-managed incoming FK (issue #95):
  --   restored_at null                     => DROPPED (RI off: after the transmute cutover, until restored).
  --   restored_at set, validated_at null   => RE-ADDED as NOT VALID: enforces RI for all NEW writes, but
  --                                            pre-existing rows are not yet verified (orphans, if any,
  --                                            are tolerated-but-flagged -- surfaced by status().fks_unvalidated
  --                                            and pgpm.incoming_fk_orphans(), cleared via validate_incoming_fks()).
  --   restored_at set, validated_at set    => fully VALIDATED.
  -- The FK is dropped once, by the cutover, and re-added by restore_incoming_fks on a later tick; nothing
  -- in a maintenance tick suspends it again (#288 removed the drain that used to). Regrain's swap is the
  -- one remaining suspend/restore, and it does both inside one transaction. Splitting the re-add from the VALIDATE
  -- is what stops a pre-existing orphan from permanently bricking restoration: the FK comes back
  -- enforcing new writes immediately, and validation is a separate, loud step.
  restored_at         timestamptz,
  validated_at        timestamptz,
  dropped_at          timestamptz not null default now()
);
-- upgrade path for installs that predate these columns
alter table pgpm.dropped_fk add column if not exists restored_at timestamptz;
alter table pgpm.dropped_fk add column if not exists validated_at timestamptz;
-- #265: when a VALIDATE fails on a pre-existing orphan, do not retry it on the very next tick -- the
-- attempt re-scans the whole referencing table each time. Set a window instead, like config.obtain_retry_after.
alter table pgpm.dropped_fk add column if not exists validate_retry_after timestamptz;
-- backfill validated_at for FKs already re-added by an older pgpm (which validated in one step): mark
-- them validated iff the actual constraint is currently convalidated. Keyed off pg_constraint, not a
-- blanket update, so a genuinely re-added-NOT-VALID FK (convalidated = false) is never wrongly marked.
update pgpm.dropped_fk d set validated_at = d.restored_at
 where d.restored_at is not null and d.validated_at is null
   and exists (select 1 from pg_constraint c
                where c.conrelid = d.referencing_table and c.conname = d.constraint_name
                  and c.contype = 'f' and c.convalidated);

-- the lifecycle hook registry (issue #236's pre_drop event, superseded by config.archive_fn) is
-- fully retired (issue #240): retire() stopped consulting it at all in #238, and #239 gave
-- pgpm_archive's gate-only architecture (archive.file_gate, the registry's last real registrant) a
-- replacement on the archive_fn contract. Nothing depends on it anymore.
drop function if exists pgpm.hook_register(regclass, text, regprocedure, boolean);
drop function if exists pgpm.hook_unregister(regclass, text, regprocedure);
drop table if exists pgpm.hook;

-- =============================== adapter layer ===============================

-- uuidv7/ULID codec (pure SQL; works on PG 15 -- no native uuidv7() needed):
-- the leading 48 bits are a Unix-ms timestamp, compared byte-wise == time order.
create or replace function pgpm._uuid_to_ts(p_uuid uuid)
returns timestamptz language sql stable as $$
  select to_timestamp(
    ('x' || lpad(substr(replace(p_uuid::text, '-', ''), 1, 12), 16, '0'))::bit(64)::bigint / 1000.0
  );
$$;

-- A UUIDv7 carries its timestamp in the leading 48 bits, so the grid it can express STOPS at
-- 2^48 - 1 ms after the epoch: 10889-08-02 05:31:50.65504+00. Past that, `to_hex` returns 13 hex digits
-- and `lpad(..., 12, '0')` TRUNCATES rather than pads -- silently dropping the high nibble, so a LATER
-- timestamp encodes as a SMALLER uuid (issue #299):
--
--   _ts_to_uuid(ceiling)         -> ffffffff-ffff-0000-0000-000000000000
--   _ts_to_uuid(ceiling + 1 ms)  -> 10000000-0000-0000-0000-000000000000
--
-- Monotonicity is the one property every caller assumes, and losing it silently produced partition
-- bounds with lo > hi -- surfacing as PostgreSQL's `empty range bound specified for partition`, an error
-- that names neither the cause nor the ceiling. Refusing here fixes it once for every caller instead of
-- at each bound-computing site.
--
-- Note the inverse can never overflow: a uuid's leading 48 bits cannot exceed the 48-bit maximum, so
-- _uuid_to_ts always returns a representable timestamp. Only stepping FORWARD off the end is possible.
create or replace function pgpm._ts_to_uuid(p_ts timestamptz)
returns uuid language plpgsql stable as $$
declare v_ms numeric; v_h text;
begin
  v_ms := floor(extract(epoch from p_ts) * 1000);
  if v_ms < 0 or v_ms > 281474976710655 then
    raise exception 'pg_partition_magician: % is outside the range a UUIDv7 timestamp can express (the leading 48 bits stop at 10889-08-02 05:31:50.65504+00); a uuidv7 grid cannot reach it', p_ts
      using errcode = 'datetime_field_overflow';
  end if;
  v_h := lpad(to_hex(v_ms::bigint), 12, '0') || repeat('0', 20);
  return (substr(v_h,1,8)||'-'||substr(v_h,9,4)||'-'||substr(v_h,13,4)||'-'||substr(v_h,17,4)||'-'||substr(v_h,21,12))::uuid;
end;
$$;

-- text_time codec: an opaque TEXT id shaped <constant prefix><fixed-width base-N encoded epoch>, the
-- general form uuidv7 is one instance of (48 bits, base16-ish, embedded in a uuid type) and classic
-- cuid is another (prefix 'c', 8 base36 digits, ms). _radix_decode/_radix_encode are the bottom
-- primitive; _text_time_to_ts/_ts_to_text_time are the timestamp-shaped wrapper transmute will use.
--
-- Lowercase 0-9a-z only (radix 2-36) for now -- covers cuid outright; a wider alphabet (base62 for
-- KSUID, Crockford base32 for ULID-as-text) is future work, not a redesign, since it only touches the
-- digit<->character mapping here, nothing upstream.
-- p_alphabet overrides the default 0-9a-z digit set (e.g. Crockford base32 for ULID, base62 for
-- KSUID -- neither is contiguous-0-9-then-lowercase, so they cannot use the default). null = the
-- original convention, capped at radix 36; a supplied alphabet's own length IS the radix ceiling, so a
-- wider one (up to base62 and beyond) is exactly as valid as a narrow one. Returns numeric, not bigint:
-- KSUID's whole-payload encoding is a 160-bit number, far past a 64-bit bigint's range.
create or replace function pgpm._radix_decode(p_digits text, p_radix int, p_alphabet text default null)
returns numeric language plpgsql stable as $$
declare v_alphabet text; v_c text; v_d int; v_acc numeric := 0;
begin
  if p_alphabet is not null then
    if length(p_alphabet) <> p_radix then
      raise exception 'pg_partition_magician: alphabet % has length %, which does not match radix %', p_alphabet, length(p_alphabet), p_radix;
    end if;
    v_alphabet := p_alphabet;
  else
    if p_radix < 2 or p_radix > 36 then
      raise exception 'pg_partition_magician: radix % is out of range for the default 0-9a-z alphabet (supported: 2-36; supply p_alphabet for a wider or different one)', p_radix;
    end if;
    v_alphabet := substr('0123456789abcdefghijklmnopqrstuvwxyz', 1, p_radix);
  end if;
  for i in 1..length(p_digits) loop
    v_c := substr(p_digits, i, 1);
    v_d := position(v_c in v_alphabet) - 1;
    if v_d < 0 then
      raise exception 'pg_partition_magician: % is not a valid base-% digit string for alphabet %', p_digits, p_radix, v_alphabet
        using errcode = 'invalid_text_representation';
    end if;
    v_acc := v_acc * p_radix + v_d;
  end loop;
  return v_acc;
end;
$$;

-- The inverse: zero-padded (using the alphabet's own zero-digit character) to EXACTLY p_width
-- characters. Refuses (rather than truncates -- the same issue #299 lesson applied generally) when
-- p_value needs more than p_width base-p_radix digits, since a truncated high end would silently
-- encode a LATER instant as a SMALLER string and break the monotonicity every bound-computing caller
-- assumes.
create or replace function pgpm._radix_encode(p_value numeric, p_radix int, p_width int, p_alphabet text default null)
returns text language plpgsql stable as $$
declare v_alphabet text; v_n numeric := p_value; v_s text := ''; v_d int;
begin
  if p_alphabet is not null then
    if length(p_alphabet) <> p_radix then
      raise exception 'pg_partition_magician: alphabet % has length %, which does not match radix %', p_alphabet, length(p_alphabet), p_radix;
    end if;
    v_alphabet := p_alphabet;
  else
    if p_radix < 2 or p_radix > 36 then
      raise exception 'pg_partition_magician: radix % is out of range for the default 0-9a-z alphabet (supported: 2-36; supply p_alphabet for a wider or different one)', p_radix;
    end if;
    v_alphabet := substr('0123456789abcdefghijklmnopqrstuvwxyz', 1, p_radix);
  end if;
  if p_value < 0 then
    raise exception 'pg_partition_magician: % is negative; _radix_encode only supports non-negative values', p_value;
  end if;
  if v_n = 0 then v_s := substr(v_alphabet, 1, 1); end if;
  -- div()/mod(), not floor(v_n / p_radix): general numeric division computes non-terminating
  -- quotients to a BOUNDED number of decimal digits, and at KSUID scale (~48 decimal digits) that
  -- rounding compounds across the loop into a wrong, sometimes NEGATIVE, digit -- reproduced and
  -- diagnosed by hand while building this. div()/mod() are exact integer operations for numeric
  -- regardless of magnitude, which floor(a/b) is not.
  while v_n > 0 loop
    v_d := mod(v_n, p_radix::numeric)::int;
    v_s := substr(v_alphabet, v_d + 1, 1) || v_s;
    v_n := div(v_n, p_radix::numeric);
  end loop;
  if length(v_s) > p_width then
    raise exception 'pg_partition_magician: % needs % base-% digit(s), which does not fit in the configured width %', p_value, length(v_s), p_radix, p_width
      using errcode = 'numeric_value_out_of_range';
  end if;
  return lpad(v_s, p_width, substr(v_alphabet, 1, 1));
end;
$$;

-- p_prefix is the CONSTANT literal characters before the timestamp field (e.g. 'c' for classic cuid),
-- verified here rather than assumed: a value that does not start with it is refused, the same
-- discipline as uuidv7's plausibility sampling but at the single-value level.
-- p_discard_bits + p_epoch cover formats (KSUID) whose timestamp is not the WHOLE decoded field but
-- the top bits of a wider one -- KSUID base62-encodes its entire 160-bit payload (32-bit timestamp +
-- 128 bits of random) as one number, so the timestamp is recovered by decoding all of it and discarding
-- the low 128 bits, against a non-Unix epoch. Both default to the cuid/ULID case (the decoded field IS
-- the timestamp already, against the standard epoch), so neither changes behavior when omitted.
create or replace function pgpm._text_time_to_ts(p_value text, p_prefix text, p_width int, p_radix int, p_unit text,
  p_alphabet text default null, p_discard_bits int default 0, p_epoch timestamptz default '1970-01-01 00:00:00+00')
returns timestamptz language plpgsql stable as $$
declare v_digits text; v_wide numeric; v_count numeric;
begin
  if p_unit not in ('ms', 's') then
    raise exception 'pg_partition_magician: unknown text_time unit % (expected ms or s)', p_unit;
  end if;
  if p_value is null or left(p_value, length(p_prefix)) <> p_prefix
     or length(p_value) < length(p_prefix) + p_width then
    raise exception 'pg_partition_magician: % does not have the expected text_time shape (prefix %, % base-% digit(s))', p_value, p_prefix, p_width, p_radix
      using errcode = 'invalid_text_representation';
  end if;
  v_digits := substr(p_value, length(p_prefix) + 1, p_width);
  v_wide := pgpm._radix_decode(v_digits, p_radix, p_alphabet);
  v_count := floor(v_wide / power(2::numeric, p_discard_bits));
  if p_unit = 'ms' then return p_epoch + (v_count / 1000.0) * interval '1 second';
  else return p_epoch + v_count * interval '1 second'; end if;
end;
$$;

-- The boundary this produces is deliberately MINIMAL: prefix + the zero-padded digits, nothing
-- appended after. That is still a correct half-open range edge, because any REAL value sharing that
-- exact prefix+timestamp with a nonempty suffix (the counter/fingerprint/random fields real ids carry)
-- sorts strictly after it -- a string is always less than any longer string that extends it. So this
-- needs no knowledge of the source format's total width or trailing fields at all, which is what makes
-- it general rather than cuid-specific.
create or replace function pgpm._ts_to_text_time(p_ts timestamptz, p_prefix text, p_width int, p_radix int, p_unit text,
  p_alphabet text default null, p_discard_bits int default 0, p_epoch timestamptz default '1970-01-01 00:00:00+00')
returns text language plpgsql stable as $$
declare v_count numeric; v_wide numeric;
begin
  if p_unit = 'ms' then v_count := floor(extract(epoch from (p_ts - p_epoch)) * 1000);
  elsif p_unit = 's' then v_count := floor(extract(epoch from (p_ts - p_epoch)));
  else raise exception 'pg_partition_magician: unknown text_time unit % (expected ms or s)', p_unit;
  end if;
  if v_count < 0 then
    raise exception 'pg_partition_magician: % is before % (the configured epoch), which a % text_time encoding cannot express', p_ts, p_epoch, p_unit
      using errcode = 'numeric_value_out_of_range';
  end if;
  v_wide := v_count * power(2::numeric, p_discard_bits);
  return p_prefix || pgpm._radix_encode(v_wide, p_radix, p_width, p_alphabet);
end;
$$;

-- native grid type for comparisons: numeric for id, timestamptz otherwise
create or replace function pgpm._native_type(p_kind text)
returns text language sql immutable as $$
  select case when p_kind = 'id' then 'numeric' else 'timestamptz' end;
$$;

create or replace function pgpm._native_gt(p_kind text, a text, b text)
returns boolean language plpgsql immutable as $$
begin
  if p_kind = 'id' then return a::numeric > b::numeric;
  else return a::timestamptz > b::timestamptz; end if;
end;
$$;

-- floor a native value to the partition-grid lower bound
create or replace function pgpm._grid_floor(p_kind text, p_step text, p_anchor text, p_native text)
returns text language plpgsql immutable as $$
declare
  v_months int; v_fixsecs double precision; v_secs double precision;
  k bigint; ts timestamptz; anc timestamptz;
begin
  if p_kind in ('time', 'uuidv7', 'text_time') then
    anc := p_anchor::timestamptz; ts := p_native::timestamptz;
    v_months  := (extract(year from p_step::interval) * 12 + extract(month from p_step::interval))::int;
    v_fixsecs := extract(epoch from (p_step::interval - make_interval(months => v_months)));
    v_secs    := extract(epoch from p_step::interval);
    if v_months > 0 then
      if v_fixsecs <> 0 then
        raise exception 'pg_partition_magician: mixed month + duration interval unsupported (%)', p_step;
      end if;
      k := ((extract(year from ts) - extract(year from anc)) * 12
          + (extract(month from ts) - extract(month from anc)))::bigint;
      k := (floor(k::numeric / v_months) * v_months)::bigint;
      return (date_trunc('month', anc) + make_interval(months => k::int))::text;
    else
      k := floor(extract(epoch from (ts - anc)) / v_secs)::bigint;
      return (anc + make_interval(secs => k * v_secs))::text;
    end if;
  elsif p_kind = 'id' then
    return (floor((p_native::numeric - p_anchor::numeric) / p_step::numeric) * p_step::numeric + p_anchor::numeric)::text;
  else
    raise exception 'pg_partition_magician: unknown control_kind %', p_kind;
  end if;
end;
$$;

create or replace function pgpm._grid_next(p_kind text, p_step text, p_lo text)
returns text language plpgsql immutable as $$
begin
  if p_kind in ('time', 'uuidv7', 'text_time') then return (p_lo::timestamptz + p_step::interval)::text;
  elsif p_kind = 'id' then return (p_lo::numeric + p_step::numeric)::text;
  else raise exception 'pg_partition_magician: unknown control_kind %', p_kind; end if;
end;
$$;

-- native grid value -> a literal of the COLUMN type. The 4 trailing params are text_time-only
-- (default null for every other kind, which never reads them) -- see pgpm.config's text_time_* columns.
create or replace function pgpm._encode(p_kind text, p_native text,
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00')
returns text language plpgsql immutable as $$
begin
  if p_kind = 'uuidv7' then return pgpm._ts_to_uuid(p_native::timestamptz)::text;
  elsif p_kind = 'text_time' then
    return pgpm._ts_to_text_time(p_native::timestamptz, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit,
                                  p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);
  else return p_native; end if;
end;
$$;

-- a stored COLUMN value -> native grid value. Same text_time_* trailing params as _encode.
create or replace function pgpm._decode(p_kind text, p_colvalue text,
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00')
returns text language plpgsql immutable as $$
begin
  if p_colvalue is null then return null; end if;
  if p_kind = 'uuidv7' then return pgpm._uuid_to_ts(p_colvalue::uuid)::text;
  elsif p_kind = 'text_time' then
    return pgpm._text_time_to_ts(p_colvalue, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit,
                                  p_tt_alphabet, p_tt_discard_bits, p_tt_epoch)::text;
  else return p_colvalue; end if;
end;
$$;

-- _part_name maps a partition's NATIVE [lo, hi) to its child table name. A one-step range (hi is the
-- next grid value after lo, the common fine partition) keeps the historical name _p<lo>; a wider range
-- (a coarse / monolith child, REDESIGN.md section 6) is named _p<lo>_to_<hi> so it can never collide
-- with the fine child at its low edge. Both bounds are formatted at the step's granularity. hi is
-- optional: omitted (or equal to the one-step value) yields the fine name, so existing callers are
-- unchanged. The name is a human-facing LABEL only -- pgpm.part holds the authoritative bounds, so the
-- 63-byte identifier limit is cosmetic, never a correctness concern (a hash fallback is future work).
drop function if exists pgpm._part_name(name, text, text, text);
create or replace function pgpm._part_name(p_relname name, p_kind text, p_step text, p_lo_native text,
                                           p_hi_native text default null)
returns name language plpgsql immutable as $$
declare v_months int; v_secs double precision; fmt text; v_coarse boolean; v_lo text; v_hi text;
begin
  v_coarse := p_hi_native is not null
          and pgpm._native_gt(p_kind, p_hi_native, pgpm._grid_next(p_kind, p_step, p_lo_native));
  if p_kind in ('time', 'uuidv7', 'text_time') then
    v_months := (extract(year from p_step::interval) * 12 + extract(month from p_step::interval))::int;
    v_secs   := extract(epoch from p_step::interval);
    if    v_months >= 12 and v_months % 12 = 0 then fmt := 'YYYY';
    elsif v_months > 0                          then fmt := 'YYYY_MM';
    elsif v_secs  >= 86400                       then fmt := 'YYYY_MM_DD';
    elsif v_secs  >= 3600                        then fmt := 'YYYY_MM_DD_HH24';
    else                                              fmt := 'YYYY_MM_DD_HH24MI';
    end if;
    v_lo := to_char(p_lo_native::timestamptz, fmt);
    if v_coarse then
      v_hi := to_char(p_hi_native::timestamptz, fmt);
      return (p_relname || '_p' || v_lo || '_to_' || v_hi)::name;
    end if;
    return (p_relname || '_p' || v_lo)::name;
  else
    v_lo := lpad(floor(p_lo_native::numeric)::text, 19, '0');
    if v_coarse then
      v_hi := lpad(floor(p_hi_native::numeric)::text, 19, '0');
      return (p_relname || '_p' || v_lo || '_to_' || v_hi)::name;
    end if;
    return (p_relname || '_p' || v_lo)::name;
  end if;
end;
$$;

-- the write frontier in native terms: now() (time), max(control) (id/uuidv7)
create or replace function pgpm._frontier_native(p_parent regclass)
returns text language plpgsql as $$
declare cfg pgpm.config; v_max text; v_decoded text;
begin
  -- The relation can be gone: pgpm.config.parent_table is a regclass, and DROP TABLE on a managed parent
  -- leaves the row pointing at an oid with no pg_class entry (only untransmute clears pgpm state). A dead
  -- regclass renders as its BARE OID, which the EXECUTE below would interpolate into a FROM clause, so
  -- Postgres reported `syntax error at or near "17379"` -- blaming a syntax error on an integer, with
  -- nothing to tell an operator what actually happened (#296). Checked here rather than in each of the
  -- four callers, so obtain, _retain_boundary, regrain_step and maintain all inherit the real message.
  -- Deliberately BEFORE the control_kind branch: a `time` table returns now() without touching the
  -- relation, so it used to sail past this point and fail further downstream instead.
  if not exists (select 1 from pg_class c where c.oid = p_parent) then
    raise exception 'pg_partition_magician: managed table with oid % no longer exists (dropped without pgpm.untransmute); run pgpm.forget_missing() to clear its pgpm state', p_parent::oid;
  end if;
  select * into cfg from pgpm.config where parent_table = p_parent;
  if cfg.control_kind = 'time' then return now()::text; end if;
  -- ORDER BY ... LIMIT 1 (not max()) so it works for uuid too; uses the index.
  -- Qualify with an alias so ORDER BY binds to the (typed) column, not the ::text projection.
  execute format('select t.%I::text from %s t order by t.%I desc limit 1',
                 cfg.control_column, p_parent::text, cfg.control_column) into v_max;
  if v_max is null then
    return case when cfg.control_kind = 'id' then cfg.partition_anchor else now()::text end;
  end if;
  v_decoded := pgpm._decode(cfg.control_kind, v_max,
                             cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
  -- #325: uuidv7 (and text_time, the same shape of thing) is a TIME grid fed by DATA. Left as plain
  -- max(control), a table whose writes go quiet (a restored dump, a stale clone, a drought) has a
  -- frontier stuck wherever the data ended while now() keeps moving -- obtain measures itself against
  -- its own past output and finds nothing to do, so the grid stalls exactly where the drought began and
  -- every write past it is refused, permanently and silently. greatest() with now() makes both kinds
  -- self-healing the same way `time` already is: the grid can never fall further behind the clock than
  -- one maintenance tick, drought or not. `id` is untouched below -- it has no clock, so its frontier
  -- can only be where the data actually put it.
  if cfg.control_kind in ('uuidv7', 'text_time') then
    return greatest(v_decoded::timestamptz, now())::text;
  end if;
  return v_decoded;
end;
$$;

-- ============================== engine ==============================

-- ANALYZE a freshly minted + bulk-loaded table so the planner has real row stats before anything relies
-- on it. A CREATE TABLE LIKE'd child that has just been INSERT'd into still shows reltuples = -1 (unknown)
-- until autovacuum catches up, so any plan that touches it in the interim -- a later regrain batch,
-- the swap/attach, or a user query right after -- misplans against a phantom-empty table. That is exactly
-- the seqscan that made the from_hypertable cutover reconcile O(rows) (#164/#166). ANALYZE is sampled, so
-- its cost is bounded by default_statistics_target, not the table size; call it everywhere a table is
-- minted-then-populated, and (where possible) on the still-private child before any exclusive lock.
create or replace function pgpm._analyze(p_rel regclass)
returns void language plpgsql as $$
begin
  execute format('analyze %s', p_rel::text);
end;
$$;

-- Give a freshly minted child the PARENT's owner (#277). A table belongs to whoever created it, and
-- anything minted after the conversion is created by whatever role runs maintenance, so without this a
-- table's partitions drift into being owned by the maintenance role while the parent keeps the real owner.
--
-- The no-op guard is not just an optimisation: when maintenance already runs AS the owner the roles match
-- and no DDL is issued at all, so this never needs a privilege the caller lacks. When they differ, the
-- caller necessarily owns the parent already (adding a partition requires it), so the ALTER is permitted.
create or replace function pgpm._own_like_parent(p_parent regclass, p_child regclass)
returns void language plpgsql as $$
declare v_owner name;
begin
  select pg_get_userbyid(relowner) into v_owner from pg_class where oid = p_parent;
  if v_owner is distinct from (select pg_get_userbyid(relowner) from pg_class where oid = p_child) then
    execute format('alter table %s owner to %I', p_child::text, v_owner);
  end if;
end;
$$;

-- Create an EMPTY partition for native [p_lo, p_hi).
--
-- One statement. With the DEFAULT gone (#288) there is nothing to prove empty, so the whole
-- NOT VALID/VALIDATE exclusion dance is gone with it, along with the phase commits, the fixed
-- pgpm_obtain_excl name and the restart-on-leftover logic that #280 needed. CREATE TABLE ... PARTITION OF
-- against a parent with no default partition is pure catalog work: it takes a brief ACCESS EXCLUSIVE on
-- the parent and scans nothing.
create or replace function pgpm._create_partition(
  p_cfg pgpm.config, p_nsp name, p_rel name, p_default regclass, p_name name, p_lo text, p_hi text
)
returns void language plpgsql as $$
declare v_lo_lit text; v_hi_lit text;
begin
  v_lo_lit := pgpm._encode(p_cfg.control_kind, p_lo,
                            p_cfg.text_time_prefix, p_cfg.text_time_width, p_cfg.text_time_radix, p_cfg.text_time_unit, p_cfg.text_time_alphabet, p_cfg.text_time_discard_bits, p_cfg.text_time_epoch);
  v_hi_lit := pgpm._encode(p_cfg.control_kind, p_hi,
                            p_cfg.text_time_prefix, p_cfg.text_time_width, p_cfg.text_time_radix, p_cfg.text_time_unit, p_cfg.text_time_alphabet, p_cfg.text_time_discard_bits, p_cfg.text_time_epoch);
  execute format('create table %I.%I partition of %I.%I for values from (%L) to (%L)',
                 p_nsp, p_name, p_nsp, p_rel, v_lo_lit, v_hi_lit);
  perform pgpm._own_like_parent(format('%I.%I', p_nsp, p_rel)::regclass,
                                format('%I.%I', p_nsp, p_name)::regclass);
  -- child_oid: WHICH relation this row is about (#421), recorded in the same statement that first
  -- names it, resolved from the CREATE TABLE two lines up rather than trusted from anywhere else.
  insert into pgpm.part (parent_table, child_name, lo, hi, child_oid)
    values (format('%I.%I', p_nsp, p_rel)::regclass, p_name, p_lo, p_hi,
            format('%I.%I', p_nsp, p_name)::regclass::oid) on conflict do nothing;
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (format('%I.%I', p_nsp, p_rel)::regclass, 'obtain', p_lo, p_hi, 'plain');
end;
$$;

-- #280: obtain became a PROCEDURE because _create_partition commits. Drop the old function first.
-- #288: obtain is a plain FUNCTION again. It became a procedure for #280 only so _create_partition could
-- commit between the phases of its exclusion-constraint dance; with the DEFAULT gone there is no dance,
-- nothing to prove empty, and nothing to recover from. The advisory lock, the stranded-constraint sweep
-- and the deferral reporting all went with it.
drop procedure if exists pgpm.obtain(regclass, int, boolean);

-- obtain(): build the empty forward partitions ahead of the frontier.
--
-- This is now pgpm's ONLY defence against a write with nowhere to go, since there is no DEFAULT to catch
-- one. config.obtain x partition_step is therefore both the slack for maintenance falling behind and a
-- hard ceiling on how far ahead an application may write. The default is 30 steps for that reason.
create or replace function pgpm.obtain(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name;
  v_frontier text; v_lo text; v_hi text; v_name name;
  v_made int := 0; k int;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  v_frontier := pgpm._frontier_native(p_parent);
  v_lo       := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier);

  for k in 0 .. cfg.obtain loop
    if k > 0 then v_lo := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo); end if;
    v_hi   := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo);
    -- The grid can RUN OUT (issue #299). A uuidv7 grid stops at the 48-bit ceiling, and no uuid can
    -- express a bound past it. That is a terminal state, not a failure: EXIT with whatever was built
    -- rather than raising, so a tick keeps working and the lookahead is simply shorter. transmute
    -- refuses up front when the monolith's own bound is unreachable, so a table only gets here by
    -- legitimately advancing toward the ceiling over its lifetime. Deliberately NOT logged: obtain runs
    -- every tick and the condition is permanent, so logging it would bury real failures under identical
    -- rows forever. A write past the grid is already refused loudly by PostgreSQL.
    begin
      perform pgpm._encode(cfg.control_kind, v_hi,
                            cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
    exception when datetime_field_overflow or numeric_value_out_of_range then
      exit;
    end;
    v_name := pgpm._part_name(v_rel, cfg.control_kind, cfg.partition_step, v_lo, v_hi);
    continue when to_regclass(format('%I.%I', v_nsp, v_name)) is not null;
    -- skip a candidate that overlaps an EXISTING attached partition (e.g. the coarse monolith that
    -- covers the active interval, REDESIGN.md section 7). Half-open [v_lo,v_hi) overlaps [p.lo,p.hi)
    -- iff p.hi > v_lo and v_hi > p.lo. Creating it would error on an overlapping partition; pgpm.part
    -- is the source of truth, and the non-overlap invariant holds over attached rows only.
    continue when exists (
      select 1 from pgpm.part p
       where p.parent_table = p_parent and p.attached
         and pgpm._native_gt(cfg.control_kind, p.hi, v_lo)
         and pgpm._native_gt(cfg.control_kind, v_hi, p.lo));

    perform pgpm._create_partition(cfg, v_nsp, v_rel, null, v_name, v_lo, v_hi);
    v_made := v_made + 1;
  end loop;
  return v_made;
end;
$$;

-- extend_to(): pre-extend the forward grid to cover a known future value (issue #290).
--
-- obtain() is pgpm's ONLY defence against a write with nowhere to go, and its lookahead
-- (config.obtain x partition_step) is a hard ceiling since the DEFAULT partition is gone (#288). That
-- ceiling is fine for `time`/`uuidv7`/`text_time` grids, whose frontier is wall-clock driven and advances
-- predictably, but an `id` grid's frontier is DATA-driven and can jump arbitrarily (a sequence restart, a
-- non-dense Snowflake/ULID generator, a bulk import, a backfill) -- and the write that would advance the
-- frontier past the ceiling is the write that fails, permanently, with no recovery path. extend_to is the
-- relief valve: an operator or application names a value it KNOWS is coming, and pgpm builds every
-- missing partition on the existing grid up to and including the range that would hold it. It never moves
-- the frontier or touches data -- it only makes a future write legal.
--
-- p_value is in the CONTROL COLUMN's own representation (a uuid literal, a text_time id, a bigint id, a
-- timestamptz-parseable string) -- decoded the same way pgpm._frontier_native decodes max(control), so a
-- caller passes exactly what it would have inserted.
--
-- p_max caps how many NEW partitions this call may create. The check runs BEFORE any DDL: a wildly-off
-- p_value (a typo, an off-by-a-few-zeros id) is refused loudly and immediately, creating nothing, rather
-- than silently truncated to p_max partitions short of the requested value -- the house rule about not
-- trading a loud failure for a silent one.
create or replace function pgpm.extend_to(p_parent regclass, p_value text, p_max int default 10000)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name;
  v_native text; v_target_lo text;
  v_frontier text; v_lo text; v_hi text; v_name name;
  v_needed int := 0; v_made int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  v_native := pgpm._decode(cfg.control_kind, p_value,
                cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
  v_target_lo := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_native);

  v_frontier := pgpm._frontier_native(p_parent);
  v_lo       := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier);

  -- count-only dry run: how many grid steps stand between the current forward edge and the target.
  -- Deliberately ignorant of which of those already exist (a conservative, cheap upper bound) -- the
  -- point is refusing BEFORE touching the catalog, not computing the tightest possible cap.
  while pgpm._native_gt(cfg.control_kind, v_target_lo, v_lo) loop
    v_lo := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo);
    v_needed := v_needed + 1;
    exit when v_needed > p_max;
  end loop;
  if v_needed > p_max then
    raise exception 'pg_partition_magician: extend_to(%, %) would need more than % new partitions to reach it; refusing rather than partially extending (raise p_max, or check p_value for a typo)',
      p_parent, p_value, p_max;
  end if;

  v_lo := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier);
  loop
    v_hi := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo);
    -- the grid can run out (#299): a uuidv7 grid stops at the 48-bit ceiling. obtain() exits quietly
    -- there because its lookahead is opportunistic, but here the caller named a specific value it needs
    -- covered, so silence would hide a real failure -- raise instead.
    begin
      perform pgpm._encode(cfg.control_kind, v_hi,
                            cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
    exception when datetime_field_overflow or numeric_value_out_of_range then
      raise exception 'pg_partition_magician: extend_to(%, %) reaches the % grid''s ceiling before covering it; cannot extend that far',
        p_parent, p_value, cfg.control_kind;
    end;
    v_name := pgpm._part_name(v_rel, cfg.control_kind, cfg.partition_step, v_lo, v_hi);
    if to_regclass(format('%I.%I', v_nsp, v_name)) is null
       and not exists (
         select 1 from pgpm.part p
          where p.parent_table = p_parent and p.attached
            and pgpm._native_gt(cfg.control_kind, p.hi, v_lo)
            and pgpm._native_gt(cfg.control_kind, v_hi, p.lo))
    then
      perform pgpm._create_partition(cfg, v_nsp, v_rel, null, v_name, v_lo, v_hi);
      v_made := v_made + 1;
    end if;
    exit when not pgpm._native_gt(cfg.control_kind, v_target_lo, v_lo);
    v_lo := v_hi;
  end loop;

  return v_made;
end;
$$;

-- drain_step / drain_all removed with the DEFAULT partition (#288). With a complete forward grid there
-- is nothing for a row to land in except a real partition, so there is nothing to evacuate.

-- #288: both drain routines are gone; drop whichever form a prior version left behind.
drop function  if exists pgpm.drain_all(regclass, int, boolean);
drop procedure if exists pgpm.drain_all(regclass, int, boolean, int);
drop function  if exists pgpm.drain_step(regclass, int, boolean);



-- the retention horizon on the native grid: the grid-floored boundary at/below which a partition's
-- whole range has aged out. null = no retention policy. Shared by retain() (what to drop now) and
-- status() (retain_backlog: what is eligible but not yet dropped).
create or replace function pgpm._retain_boundary(cfg pgpm.config)
returns text language plpgsql as $$
begin
  if cfg.retain is null then return null; end if;
  if cfg.control_kind = 'id' then
    return pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                            (pgpm._frontier_native(cfg.parent_table)::numeric - cfg.retain::numeric)::text);
  else
    return pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                            (now() - cfg.retain::interval)::text);
  end if;
end;
$$;

-- ==================== retiring a REFERENCED partition (issue #268) ====================
--
-- `p_incoming_fks => 'preserve'` and a `retain` policy were both supported and both documented, and
-- the combination never reclaimed anything: every retain() failed on the oldest eligible partition and
-- returned 0, forever, while the write block was already installed. Frozen AND unreclaimable.
--
-- `DROP TABLE <partition>` is refused on a pure CATALOG dependency. An FK against a partitioned parent
-- puts one pg_constraint row per referenced partition ON the referencing table, and the refusal is
-- data-INDEPENDENT: identical whether one row references, zero rows reference, or the referencing
-- table is empty. DETACH is the only phase that consults data, and a successful one severs the
-- per-partition constraint, after which the DROP is completely unguarded. So: detach, then drop. The
-- referencing table's own FK survives and still enforces.
--
-- The detach must be CONCURRENT. Measured on PG 17.10, 8M-row referencing table:
--
--   ALTER TABLE ... DETACH PARTITION               AccessExclusiveLock on the MANAGED PARENT, ~1.5 s;
--                                                  a concurrent read of the parent dies with 55P03
--   ALTER TABLE ... DETACH PARTITION CONCURRENTLY  ShareUpdateExclusiveLock; the parent stays readable
--                                                  and writable throughout
--
-- Plain DETACH would make retention block the table pgpm exists to keep online, for a duration set by
-- the size of a table pgpm does not own. That is exactly the shape the project's acceptance rule
-- forbids. And PostgreSQL refuses to run the concurrent form from any of the contexts pgpm has:
--
--   ERROR:  ALTER TABLE ... DETACH CONCURRENTLY cannot be executed from a function
--
-- not from a procedure that has already committed, not from a DO block, and not via dynamic EXECUTE:
-- it is a check on execution CONTEXT, and pgpm is pure SQL. So pgpm DISPATCHES it. pg_cron is already
-- pgpm's one runtime dependency, and a cron job's command runs as a top-level statement in its own
-- session, where the statement is legal. retire() repoints a single standing job at the specific
-- detach and completes the DROP on a later tick.
--
-- ONE STANDING JOB, rewritten in place, not one job per retirement: pg_cron has no one-shot schedule,
-- so a per-retirement job would keep firing after it succeeded and log `is not a partition` failures
-- until something unscheduled it. pgpm.schedule() creates `pgpm_detach` idle (`select 1`); retire()
-- points it at a detach when it needs one and returns it to idle once the drop lands. At most one
-- detach is in flight, which retention's existing retain_batch pacing already assumes.
--
-- What this costs, stated plainly: retirement of a REFERENCED partition is asynchronous, spanning at
-- least one cron tick, and it requires pgpm.schedule() to have been run. Retention was already
-- eventual, so this lengthens a delay rather than introducing one. Writes to the REFERENCING table are
-- blocked for O(that table) by the detach's ShareLock, once per retirement -- readers of it, and the
-- managed parent entirely, are unaffected. That part is irreducible: it is PostgreSQL proving the FK
-- still holds. An index on the referencing FK column does NOT reduce it (measured: 1368 ms without,
-- 1634 ms with).
--
-- And what it costs in IDENTITY, which is the other half of the bill (issue #407). Dispatching means
-- the statement leaves this process as TEXT and is re-resolved BY NAME, later, somewhere else, with
-- no lock held on the child in between -- the time-of-check/time-of-use shape the #346 audit went
-- looking for. pgpm cannot close that window: the reason the statement is dispatched at all is that
-- PostgreSQL will not let pgpm hold anything while it runs. So the retirement is anchored to the
-- child's OID instead (pgpm.part.retiring_oid), and the two steps that remain pgpm's -- re-dispatching
-- on a later tick, and the DROP that follows a successful detach -- refuse to act unless the name
-- still resolves to it. The detach itself can still land on a substitute; the DROP, which is the
-- irreversible half, cannot.

-- _crossing_keys: the control-column values inside [p_lo, p_hi) that some incoming foreign key still
-- references -- the rows where the operator's two promises, the FK and the retention horizon,
-- genuinely contradict.
--
-- Identification runs FIRST and unconditionally, rather than attempting the detach and catching its
-- error, because a FAILING detach is only cheap when the referencing FK column happens to be indexed.
-- Measured, 8M-row referencing table: identifying costs 0.7 ms indexed and 141.9 ms unindexed, against
-- a failing DETACH's 1.9 ms indexed but 1176 ms unindexed -- a near-full scan under ShareLock paid
-- purely to discover the operation cannot proceed, with the locks already taken. Pre-identifying also
-- reports every crossing key at once, where PostgreSQL names one at a time.
create or replace function pgpm._crossing_keys(p_parent regclass, p_lo text, p_hi text)
returns text[] language plpgsql as $$
declare
  cfg pgpm.config; r record;
  v_ctrl_attnum smallint; v_refcol name; v_pos int;
  v_lo_lit text; v_hi_lit text; v_vals text[] := '{}'; v_more text[];
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;

  select a.attnum into v_ctrl_attnum from pg_attribute a
   where a.attrelid = p_parent and a.attname = cfg.control_column and not a.attisdropped;

  v_lo_lit := pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
  v_hi_lit := pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);

  -- conparentid = 0 picks the top-level constraint. An FK referencing a PARTITIONED table also gets
  -- one pg_constraint row per partition of the referenced side, so an unfiltered scan would visit the
  -- same foreign key once per partition.
  for r in
    select c.conname, c.conrelid::regclass as referencing, c.conkey, c.confkey
      from pg_constraint c
     where c.confrelid = p_parent and c.contype = 'f' and c.conparentid = 0
  loop
    -- Which referencing column maps to the CONTROL column? A foreign key can only reference a unique
    -- constraint, and every unique constraint on a partitioned table must include the partition key,
    -- so this position always exists in pgpm's shape. Say so loudly if it ever does not, rather than
    -- silently reporting no crossing and going on to a detach that will refuse.
    v_pos := array_position(r.confkey, v_ctrl_attnum);
    if v_pos is null then
      raise exception 'pg_partition_magician: foreign key % on % references % without its control column %, so pgpm cannot tell which rows cross the retention horizon',
        r.conname, r.referencing, p_parent, cfg.control_column;
    end if;
    select a.attname into v_refcol from pg_attribute a
     where a.attrelid = r.referencing and a.attnum = (r.conkey)[v_pos];

    -- A plain range predicate: a row whose key falls in [lo, hi) references a row in THIS partition,
    -- by the definition of range partitioning, whatever else the key carries.
    execute format(
      'select coalesce(array_agg(distinct %I::text), ''{}''::text[]) from %s where %I >= %L and %I < %L',
      v_refcol, r.referencing::text, v_refcol, v_lo_lit, v_refcol, v_hi_lit)
      into v_more;
    v_vals := v_vals || v_more;
  end loop;
  return v_vals;
end;
$$;

-- #407 changed p_child from `name` to `regclass`, and gave _idle_detach_job a parameter.
-- `create or replace` cannot change either, so the old signatures would otherwise stay installed
-- beside the new ones on an upgrade -- and a zero-argument call would then be AMBIGUOUS against a
-- one-argument version with a default, which is why _idle_detach_job's parameter has none.
drop function if exists pgpm._dispatch_detach(regclass, name);
drop function if exists pgpm._idle_detach_job();

-- The one place the dispatched command's text is built. Both _dispatch_detach (which arms the job)
-- and retire() (which disarms it, and has to recognise its own command to do that safely) go through
-- here, so the two cannot drift into disagreeing about what was armed.
--
-- Returns null for a p_parent with no pg_class row, which _idle_detach_job reads as "disarm
-- unconditionally" -- degrading to exactly the pre-#407 behaviour, not to something worse. retire()
-- cannot reach it that way regardless: it resolves the parent's schema, and reads the frontier off
-- the relation, well before either call site.
create or replace function pgpm._detach_cmd(p_parent regclass, p_child_nsp name, p_child_rel name)
returns text language sql stable as $$
  select format('alter table %I.%I detach partition %I.%I concurrently',
                n.nspname, c.relname, p_child_nsp, p_child_rel)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
$$;

-- _dispatch_detach: point the standing `pgpm_detach` job at this partition's concurrent detach.
-- Returns null on success, or the REASON it could not dispatch -- pg_cron not installed, pgpm.schedule()
-- never run, no privilege on cron.job. All three are configuration problems the operator has to see and
-- fix, so the reason is carried back verbatim to be logged rather than flattened into a bare false.
--
-- Dynamic EXECUTE because the `cron` schema is only resolved at call time, so this file still installs
-- cleanly where pg_cron is not enabled. Both relations are schema-qualified in the command: the cron
-- job runs in its own session, with its own search_path.
--
-- BOTH RELATIONS ARE PASSED AS OIDS AND RENDERED FROM THEM (issue #407), so the text that lands on
-- cron.job can only ever name relations the caller actually resolved in its own transaction. That is
-- the most this function can do about the gap it opens: the command it writes is picked up by pg_cron
-- a tick or more later, in another session, and re-resolved BY NAME there, with no lock held on
-- either relation across the interval and no way for a command text to carry an OID. The rest of the
-- defence is pgpm.part.retiring_oid, which lets retire() DETECT at its next two decision points that
-- the name no longer means what it meant here. See the column's comment.
create or replace function pgpm._dispatch_detach(p_parent regclass, p_child regclass)
returns text language plpgsql as $$
declare v_cnsp name; v_crel name; v_cmd_q text; v_n int;
begin
  select n.nspname, c.relname into v_cnsp, v_crel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_child;
  v_cmd_q := pgpm._detach_cmd(p_parent, v_cnsp, v_crel);
  begin
    execute format(
      'select count(*)::int from (select cron.alter_job(jobid, command => %L) from cron.job'
      || ' where jobname = ''pgpm_detach'' and database = current_database()) s', v_cmd_q)
      into v_n;
  exception when others then
    return left(sqlerrm, 160);
  end;
  if v_n > 0 then return null; end if;
  return 'no pgpm_detach cron job in this database; run pgpm.schedule()';
end;
$$;

-- the reverse: put the standing job back to idle once a retirement completes, so it is not left
-- re-running a detach that has already happened (which logs `is not a partition` every tick).
--
-- p_cmd null disarms whatever is there. Pass a command instead to disarm ONLY IF THAT IS STILL WHAT
-- IS ARMED (issue #407). At most one detach is in flight, so the caller completing a retirement is
-- normally the owner of the armed command and null is right; but a retirement WEDGED on an identity
-- mismatch revisits this on every tick forever, and an unconditional disarm there would clobber some
-- other parent's freshly-dispatched detach every tick for as long as the wedge lasts. Build p_cmd
-- through pgpm._detach_cmd, the same function that armed it. A mismatch skips the disarm, which is
-- the safe direction: the next successful dispatch overwrites the command anyway.
create or replace function pgpm._idle_detach_job(p_cmd text)
returns void language plpgsql as $$
begin
  if p_cmd is null then
    execute 'select cron.alter_job(jobid, command => ''select 1'') from cron.job'
         || ' where jobname = ''pgpm_detach'' and database = current_database()';
  else
    execute 'select cron.alter_job(jobid, command => ''select 1'') from cron.job'
         || ' where jobname = ''pgpm_detach'' and database = current_database() and command = $1'
      using p_cmd;
  end if;
exception when others then
  null;   -- no pg_cron, or no such job: there is nothing to quiesce
end;
$$;

-- retire(): the sanctioned single-partition drop (issue #195) -- retain()'s per-partition body,
-- public and claim-guarded, so an external assistant (e.g. an archive-then-drop scanner) or several
-- cooperating ones can drive retirement themselves through the same protocol retain() uses: claim,
-- ensure write-blocked, gate on archive coverage, DROP, catalog + log. It never widens what
-- retention may drop: the child's whole range must sit at/below the retention horizon, so a caller
-- only picks WHICH eligible partition and WHEN. Returns true iff this call dropped the partition.
--
-- Drop precondition, as of issue #238: past the retention horizon (as before), write-blocked, and
-- pgpm._archive_fully_covered. Write-blocking is ENSURED here (pgpm._install_write_block is
-- idempotent), not merely asserted: retire() is called by more than one path -- retain()'s own loop,
-- an external assistant, pgpm_archive's self-driving sweep -- and only maintain() is guaranteed to
-- have run _enforce_write_blocks first. Asserting (raising) instead would make retire() fail for
-- every caller that reaches an eligible partition some other way, which defeats the entire point of
-- retire() being independently callable. Archive coverage is different: a child mid-chunked-archive
-- is a normal, expected, RETRYABLE state, not a failure -- retire() just returns false, the same way
-- it already does for a concurrently-claimed partition, so retain()'s batch loop skips it this cycle
-- without logging anything.
--
-- The pgpm.hook pre_drop registry this used to consult (hooks ran in registration order
-- immediately before the DROP) is gone entirely as of issue #240 -- archive coverage via
-- config.archive_fn is the only gate a drop precondition has now.
--
-- Returns false, without side effects, when the pgpm.part row is absent (already retired by another
-- actor) or claimed by a concurrent transaction: FOR UPDATE SKIP LOCKED (issue #188) gives each
-- partition exactly one owner at a time. The claim is taken OUTSIDE the DROP's own subtransaction,
-- so an unexpected drop failure (retain_drop_fail, logged, retried on a later call) keeps the row
-- claimed until the caller's transaction ends.
--
-- IDENTITY ACROSS THE DISPATCH GAP (issue #407). A referenced partition's retirement spans sessions:
-- this function dispatches a detach as command TEXT, pg_cron runs it a tick or more later, and a
-- later call of this function completes the DROP. p_child is a name for the whole of that, so every
-- step after the first re-resolves it, and the object it lands on is only the object pgpm meant if
-- nothing took the name in between. pgpm.part.retiring_oid records which object that was, and the
-- check below -- once, before the first side effect of a call, so it covers re-dispatch and DROP
-- alike -- refuses to go on when the name has stopped resolving to it.
create or replace function pgpm.retire(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_boundary text; r record;
  v_referenced boolean; v_child regclass; v_now regclass; v_why text;
  v_cross text[]; v_coltype text; v_lo_lit text; v_hi_lit text; v_deleted int; v_reason text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.retain is null then
    raise exception 'pg_partition_magician: % has no retention policy (config.retain is null); retire() drops only what retention allows', p_parent;
  end if;

  -- the claim: one owner per partition at a time
  select p.lo, p.hi, p.attached, p.retiring_at, p.retiring_oid, p.child_oid into r
    from pgpm.part p
   where p.parent_table = p_parent and p.child_name = p_child
     for update skip locked;
  if not found then return false; end if;
  if not r.attached then
    raise exception 'pg_partition_magician: %.% is not an attached partition (an in-flight regrain child is not retirable)', p_parent, p_child;
  end if;

  v_boundary := pgpm._retain_boundary(cfg);
  if pgpm._native_gt(cfg.control_kind, r.hi, v_boundary) then
    raise exception 'pg_partition_magician: % is not entirely past the retention horizon (hi %, horizon %)', p_child, r.hi, v_boundary;
  end if;

  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- IDENTITY, BEFORE ANY SIDE EFFECT (issues #407 and #428). Everything from here down acts on
  -- p_child by NAME -- installing the write block, deleting crossing keys, re-pointing the cron job,
  -- and finally the DROP -- so the name has to be proved to still mean the right relation before the
  -- first of them, not just before the last.
  --
  -- TWO ANCHORS, CHECKED INDEPENDENTLY, because they record different things and each catches a
  -- substitution the other cannot see:
  --
  --   retiring_oid (#407) is which object THIS RETIREMENT dispatched a detach for. It exists because
  --   the detach leaves the session as command TEXT and is re-resolved by pg_cron later, with no
  --   lock held across the gap. It is null for every partition not being retired through a detach --
  --   which is every unreferenced one, i.e. the ordinary one-step DROP path.
  --
  --   child_oid (#421) is which object this pgpm.part ROW has always been about, recorded when the
  --   partition entered the catalog. It is populated for every partition, so it is what covers the
  --   one-step path retiring_oid leaves open (#428) -- the path that ends in a bare `drop table
  --   schema.child` with nothing else between it and the write block.
  --
  -- Coalescing them would be wrong, not merely weaker. retiring_oid is itself resolved BY NAME, out
  -- of pg_inherits at dispatch time, so a substitution that landed BEFORE the dispatch is adopted by
  -- that anchor: comparing the name against it then passes forever, and `coalesce(retiring_oid,
  -- child_oid)` would never reach the one anchor that still remembers the original. Checking both
  -- means a disagreement with EITHER refuses, and the message says which, so an operator is not left
  -- to guess whether they are looking at a stale dispatch or a stale row.
  --
  -- In each case two independent facts have to agree: the name resolves, and it resolves to the
  -- recorded OID. Either alone is forgeable -- a name can be taken by a new relation, and a pg_class
  -- OID can in principle be reused once its original is gone. `is distinct from` so a name that
  -- resolves to nothing at all trips this too. A null anchor is unanchored and is simply not
  -- consulted, which is what keeps an upgrade from wedging a partition it has nothing to compare.
  --
  -- Fails closed and STAYS closed: logged, false, partition untouched, every tick. There is no later
  -- tick on which the name goes back to meaning the right object, so this is a wedge an operator has
  -- to look at, not a deferral -- and status() counts it as one. On the way out the standing job is
  -- disarmed IF it is still holding this retirement's own command, which by now names the
  -- substitute; conditionally, because this branch runs on every tick for as long as the wedge
  -- lasts, and an unconditional disarm would clobber another parent's dispatch just as often. Only
  -- when retiring_oid is set, because that is the only case in which a detach was ever armed -- on
  -- the one-step path there is nothing to disarm and nothing that could be holding the job.
  if r.retiring_oid is not null or r.child_oid is not null then
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

  perform pgpm._install_write_block(p_parent, p_child);

  if not pgpm._archive_fully_covered(p_parent, p_child) then
    return false;
  end if;

  -- Is anything pointing at this parent at all (issue #268)? Without an incoming FK the bare DROP
  -- below works and costs nothing, so the overwhelmingly common path stays byte-identical: no marker,
  -- no cron round trip, no waiting a tick. Gating here also confines the concurrent detach, and the
  -- reaper hazard that comes with it, to the tables that actually need them.
  v_referenced := exists (select 1 from pg_constraint
                           where confrelid = p_parent and contype = 'f' and conparentid = 0);

  if v_referenced then
    -- Resolved to an OID, not merely counted (#407). This is both the "is it still attached?" test it
    -- has always been AND the value recorded in retiring_oid below, which is what the check at the top
    -- of every later call compares against -- so the identity being retired is pinned once, here,
    -- read out of pg_inherits and therefore a partition OF THIS PARENT by construction.
    select i.inhrelid into v_child
      from pg_inherits i join pg_class c on c.oid = i.inhrelid
     where i.inhparent = p_parent and c.relname = p_child;

    if v_child is not null then
      -- ONE DETACH IN FLIGHT AT A TIME, database-wide. There is a single standing cron job, so a
      -- second dispatch would overwrite the first and silently abandon it -- leaving a partition
      -- marked retiring_at that nothing is detaching. retain()'s batch loop walks every eligible
      -- partition, and maintain_all walks every managed parent, so this is the common case, not an
      -- exotic race: without this guard one retain() call marks the whole backlog and only the last
      -- one is real. A retirement stops holding the job the moment its partition is detached, so this
      -- yields rather than blocks: the next tick takes the next partition. Silent and retryable, like
      -- the archive-coverage gate above.
      -- Yield only to a STRICTLY OLDER in-flight retirement, on a total order. "Yield to any other" is
      -- the obvious formulation and it deadlocks: two concurrent retire() calls can both pass the check
      -- and both mark, after which each sees the other in flight and neither ever proceeds again. With a
      -- total order the oldest marker always wins, so there is always exactly one partition able to make
      -- progress and the loser simply retries. An unmarked candidate sorts last (`infinity`), so a fresh
      -- retirement always yields to one already under way.
      if exists (
        select 1 from pgpm.part p
         where p.retiring_at is not null
           and not (p.parent_table = p_parent and p.child_name = p_child)
           and (p.retiring_at, p.parent_table::text, p.child_name)
             < (coalesce(r.retiring_at, 'infinity'::timestamptz), p_parent::text, p_child)
           and exists (select 1 from pg_inherits i join pg_class c on c.oid = i.inhrelid
                        where i.inhparent = p.parent_table and c.relname = p.child_name))
      then
        return false;
      end if;

      -- THE CROSSING. A live row genuinely referencing a doomed row is the one case where retention
      -- and referential integrity contradict, and pgpm has NO policy decision to make here: the
      -- operator already chose, per constraint, in the FK's ON DELETE clause. DELETE lets PostgreSQL
      -- apply whatever was declared, with no branching -- CASCADE clears the referencing rows, SET
      -- NULL and SET DEFAULT sever them in place, NO ACTION and RESTRICT refuse and therefore block
      -- retention exactly as specified, surfacing the operator's own error rather than a pgpm one.
      -- (DETACH cannot be left to do this: it is structural, so no action triggers fire, and it
      -- unilaterally refuses for every constraint -- correct by coincidence for NO ACTION, an override
      -- of an explicit instruction for CASCADE.)
      v_cross := pgpm._crossing_keys(p_parent, r.lo, r.hi);
      if coalesce(array_length(v_cross, 1), 0) > 0 then
        select format_type(a.atttypid, a.atttypmod) into v_coltype
          from pg_attribute a where a.attrelid = p_parent and a.attname = cfg.control_column;
        v_lo_lit := pgpm._encode(cfg.control_kind, r.lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
        v_hi_lit := pgpm._encode(cfg.control_kind, r.hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
        begin
          -- The write block installed above is a BEFORE ROW trigger on this child covering DELETE
          -- too, so it would refuse this. Lift it for the delete and put it straight back: DDL is
          -- transactional and retire() does not commit, so no other session ever observes the child
          -- unblocked. Disabling triggers wholesale is NOT an option -- that would switch off the RI
          -- triggers whose actions are the entire point of doing this as a DELETE.
          perform pgpm._remove_write_block(p_parent, p_child);
          execute format(
            'delete from %s where %I >= %L and %I < %L and %I = any (%L::text[]::%s[])',
            p_parent::text, cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit,
            cfg.control_column, v_cross, v_coltype);
          get diagnostics v_deleted = row_count;
          perform pgpm._install_write_block(p_parent, p_child);
          -- Logged loudly and separately: this fires referential actions on tables pgpm was not
          -- handed, which is the one thing retirement does beyond its own partition.
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'retain_crossing', r.lo, r.hi,
                    format('%s referenced key(s), %s row(s) deleted to honour the declared ON DELETE',
                           array_length(v_cross, 1), v_deleted));
        exception when others then
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'fail_retain_crossing', r.lo, r.hi, left(sqlerrm, 200));
          return false;
        end;
      end if;

      -- Mark, then dispatch, in one transaction: the marker and the job's new command become visible
      -- together, so there is never a detach in flight that recovery cannot attribute.
      -- coalesce, NOT an unconditional stamp: retiring_at is when this retirement BEGAN, and a retry
      -- must not refresh it. Re-stamping makes the winner perpetually the newest marker, so it stops
      -- being the winner, and the total order above degenerates into no order at all -- two partitions
      -- then dispatch in the same tick and one clobbers the other's job.
      -- retiring_oid is coalesced for the same reason and records the same instant: it is the object
      -- the FIRST dispatch chose, and a retry that refreshed it would simply adopt whatever holds the
      -- name now -- which is precisely the substitution the check above exists to catch.
      update pgpm.part set retiring_at = coalesce(retiring_at, clock_timestamp()),
                           retiring_oid = coalesce(retiring_oid, v_child::oid)
       where parent_table = p_parent and child_name = p_child;

      v_reason := pgpm._dispatch_detach(p_parent, v_child);
      if v_reason is null then
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'retain_detach', r.lo, r.hi,
                  'concurrent detach dispatched; the drop completes on a later tick');
      else
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'fail_retain_detach', r.lo, r.hi,
                  format('%s -- a referenced partition cannot be retired without it', v_reason));
      end if;
      return false;   -- retirement is under way, not done
    end if;

    -- Detached but not yet dropped. Complete it only if this was pgpm's retirement: an operator's own
    -- interrupted DETACH CONCURRENTLY gets finalized by _detach_reap and then left alone, rather than
    -- having pgpm drop a table it was never asked to drop.
    if r.retiring_at is null then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_retain_drop', r.lo, r.hi,
                'detached from the parent by something other than retirement; not dropping it');
      return false;
    end if;

    -- DISARM BEFORE THE DROP, not after it (#407). The standing job still carries this partition's
    -- detach command and fires it every tick until something resets it, so the window in which a
    -- stale name sits armed is not one cron interval: it lasts until the drop SUCCEEDS, and a drop
    -- that keeps failing extends it indefinitely. Out here rather than inside the DROP's own
    -- subtransaction for the same reason -- a rolled-back drop must not roll back the disarming.
    -- Unconditional here, unlike the wedge above: this runs once per retirement rather than on every
    -- tick forever, and the identity check has just proved the name means what it meant, so the
    -- detach that landed was this retirement's and the armed command is its own.
    perform pgpm._idle_detach_job(null);
  end if;

  begin
    execute format('drop table %I.%I', v_nsp, p_child);
    delete from pgpm.part where parent_table = p_parent and child_name = p_child;
    insert into pgpm.log (parent_table, action, lo, hi) values (p_parent, 'retain_drop', r.lo, r.hi);
    return true;
  exception when others then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'fail_retain_drop', r.lo, r.hi, left(sqlerrm, 200));
    return false;
  end;
end;
$$;

create or replace function pgpm.retain(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_ncast text; r record; v_dropped int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.retain is null then return 0; end if;

  v_boundary := pgpm._retain_boundary(cfg);
  v_ncast := pgpm._native_type(cfg.control_kind);

  -- retire() carries the per-partition protocol (claim, write-block, archive-coverage gate, drop,
  -- bookkeeping -- see there); this loop only picks the eligible set, oldest first, capped by
  -- retain_batch (issue #189; 'limit all' when null). A retire() that returns false (archive
  -- coverage not yet complete -- a normal, retryable state, not a failure -- or claimed/retired by a
  -- concurrent assistant) still consumed its batch slot: the cap bounds ATTEMPTS, not successes.
  for r in execute format(
    'select child_name from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s order by lo::%s limit %s',
    p_parent::text, v_ncast, v_boundary, v_ncast, v_ncast, coalesce(cfg.retain_batch::text, 'all'))
  loop
    if pgpm.retire(p_parent, r.child_name) then v_dropped := v_dropped + 1; end if;
  end loop;
  return v_dropped;
end;
$$;

-- write-block on retain-eligibility (issue #235). A
-- partition past _retain_boundary() is drop-eligible, and for however long it takes chunked
-- archiving to finish covering it (or forever, for a table with no archive strategy at all), it
-- should not accept writes either -- a backdated write into that span, including into a range some
-- earlier archive chunk already covered, would silently diverge the archive from what is live. Two
-- alternatives were ruled out empirically, not on paper: REVOKEing INSERT/UPDATE/DELETE on the
-- child does nothing, because a parent-routed write is checked against the PARENT's ACL, never the
-- child's; and a lock spanning the whole (unbounded, chunked) archiving window defeats the reason
-- chunking exists. A BEFORE ROW trigger on the specific child is checked regardless of routing,
-- can't be bypassed by an owner or superuser the way a privilege check can, and is torn down for
-- free by the eventual DROP TABLE.
create or replace function pgpm._write_block_raise() returns trigger
language plpgsql as $$
begin
  raise exception 'pg_partition_magician: % is past its retention boundary and is no longer writable', tg_table_name;
end;
$$;

-- idempotent: a no-op if the child is already blocked, so a repeat _enforce_write_blocks tick (every
-- maintain() call revisits every attached child) never raises a duplicate-trigger error.
--
-- IDENTITY, BEFORE THE DDL (issue #429). This resolves p_child by NAME and then issues CREATE
-- TRIGGER against whatever comes back, and _enforce_write_blocks calls it for every attached child
-- on every maintain() tick. Without the check below, a relation that has taken a partition's name
-- gets a pgpm trigger rejecting all of its INSERTs, UPDATEs and DELETEs -- DDL against a relation
-- pgpm never identified, on a table it was never handed, recorded nowhere in its own catalog.
--
-- The second consequence is the one that made #421 reachable rather than theoretical:
-- _archive_step's candidate query gates on _is_write_blocked, so a substituted name is only ever
-- ELIGIBLE for archiving because this step made it so. Maintenance manufactured its own candidate.
-- Refusing here is therefore not redundant with #421's own check, it is upstream of it.
--
-- The check lives HERE rather than in _enforce_write_blocks' loop, even though that loop already
-- holds the pgpm.part row this has to re-read. The loop is only one of the callers; retire() has two
-- more, and they are safe today only because #430's identity check happens to sit upstream of them.
-- A check in the function cannot be reintroduced by a caller that did not know to make it.
--
-- Logged and RETURNS, never raises. Raising would propagate out through retire(), which calls this
-- outside any handler, and turn a wedge into an error; it would also reach _enforce_write_blocks'
-- per-child handler, which would log it as skip_write_block -- and `skip_` means a deferral a later
-- tick clears, which this is precisely not. There is no later tick on which the name goes back to
-- meaning the right relation, so it gets its own prefixed action and status() counts it with the
-- other things that stall retention: no write block means no archiving, and no drop.
--
-- A null child_oid is unanchored and skips the check, same as everywhere else, so an upgrade never
-- wedges a partition it has nothing to compare against.
--
-- `v_now is not null and ... <> ...`, NOT the `is distinct from` used by the identity checks in
-- retire() and _archive_step, and the difference is deliberate. Those two fire on a name that
-- resolves to NOTHING as well, because there the next thing they would do is act on the relation --
-- read it, or DROP it -- and failing closed is the whole point. Here there is no wrong relation to
-- act on: if the name resolves to nothing, the `::regclass` cast below raises, _enforce_write_blocks'
-- per-child handler catches it, and `skip_write_block` is logged carrying the real error. That path
-- predates this check (issue #360, and tests/94 is built on it), and intercepting it here would
-- replace a tested, accurate report with a misleading one -- this refusal means "something else
-- holds the name", which is not what a dropped partition is. A pgpm.part row whose relation is gone
-- is forget_missing's business, and retire() already counts it via fail_retain_identity.
create or replace function pgpm._install_write_block(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name; v_child regclass; v_now regclass; r record;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  select p.lo, p.hi, p.child_oid into r
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

  v_child := format('%I.%I', v_nsp, p_child)::regclass;
  if exists (select 1 from pg_trigger where tgrelid = v_child and tgname = 'pgpm_write_block') then
    return;
  end if;
  execute format(
    'create trigger pgpm_write_block before insert or update or delete on %I.%I'
    || ' for each row execute function pgpm._write_block_raise()', v_nsp, p_child);
end;
$$;

-- the reverse: an operator loosening config.retain can make a previously-eligible partition
-- ineligible again, so this needs to run just as often as _install_write_block. drop ... if exists
-- makes it just as idempotent on a child that was never blocked.
--
-- DELIBERATELY NOT ANCHORED, unlike the install above (issue #429). The asymmetry is the point.
-- Refusing to install on a relation pgpm has not identified is protective; refusing to REMOVE from
-- one is the opposite. A pre-#429 pgpm installed this trigger on whatever held the name, so an
-- install upgrading into that fix can already have one sitting on a relation it never managed,
-- rejecting every write to it -- and an anchored removal would refuse to touch the very trigger
-- pgpm itself wrongly created, leaving that relation read-only permanently. Resolving by name is
-- what lets an upgraded pgpm clean up after an older one. The statement is `drop trigger if
-- exists`, so on anything pgpm never blocked it remains a no-op.
create or replace function pgpm._remove_write_block(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  execute format('drop trigger if exists pgpm_write_block on %I.%I', v_nsp, p_child);
end;
$$;

-- reconciles every attached child's write-block state against current eligibility in one pass,
-- reusing the exact _retain_boundary() retire() itself checks so "eligible to write-block" and
-- "eligible to drop" can never disagree. A table with no retention policy (config.retain null) has
-- no boundary at all, so nothing is ever eligible and nothing is ever blocked.
--
-- Each child's install/remove attempt is isolated in its own exception scope (issue #360): a lock
-- timeout (or any other failure) on one child logs skip_write_block for that child alone and moves
-- on, rather than raising out of the whole loop and leaving every child after it -- lock-contended
-- or not -- untouched for the entire tick. `order by hi asc` means that even when repeated
-- contention does limit how far one tick's pass gets, the oldest (most overdue) children are always
-- the ones attempted first, matching _archive_step's existing oldest-first convention (#237).
create or replace function pgpm._enforce_write_blocks(p_parent regclass)
returns void language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; r record; v_eligible boolean;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_boundary := pgpm._retain_boundary(cfg);

  for r in select child_name, hi from pgpm.part where parent_table = p_parent and attached
    order by hi asc
  loop
    begin
      v_eligible := v_boundary is not null and not pgpm._native_gt(cfg.control_kind, r.hi, v_boundary);
      if v_eligible then
        perform pgpm._install_write_block(p_parent, r.child_name);
      else
        perform pgpm._remove_write_block(p_parent, r.child_name);
      end if;
    exception when others then
      insert into pgpm.log (parent_table, action, hi, method)
        values (p_parent, 'skip_write_block', r.hi, left(sqlerrm, 200));
    end;
  end loop;
end;
$$;

-- true iff the write-block trigger is actually installed on this child right now (checked directly
-- against pg_trigger, not re-derived from the boundary formula) -- shared by _archive_step (issue
-- #237, only ever archives an already-blocked child) and retire() (issue #238) below.
create or replace function pgpm._is_write_blocked(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare v_nsp name;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  return exists (
    select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
     where t.tgname = 'pgpm_write_block' and c.relname = p_child and c.relnamespace = v_nsp::regnamespace
  );
end;
$$;

-- ===================== pluggable archive strategy (issue #236) =====================
-- One archive strategy per managed table (config.archive_fn), superseding the old generic
-- pgpm.hook pre_drop registry (removed entirely, issue #240) -- archiving before a drop was its
-- only real use. pgpm._archive_step (below) drives this every maintain() tick, and retire()'s drop
-- precondition gates on pgpm._archive_fully_covered.

-- archive_fn's return shape: how much of a requested [lo, hi) a single call durably archived.
-- covered_hi is the native-grid value up to which [lo, ...) is now durably archived by THIS call --
-- may be less than hi, since a real strategy is expected to be resumable (called again next tick to
-- make further bounded progress, not to finish the whole range at once). rows_archived is how many
-- rows this call actually archived; null when nothing was actually archived (the 'none' strategy,
-- or a strategy that made no progress this tick). s3_key/etag are optional identifiers a transport
-- strategy (e.g. pgpm_archive's pgpm.archive_to_s3_ndjson/archive_to_s3_parquet, issue #239) can
-- report back for the ledger row; null for a strategy with nothing object-store-shaped to name (the
-- 'none' strategy, pgpm._archive_noop, a user-authored strategy that doesn't use S3). No CREATE OR
-- REPLACE TYPE exists in PostgreSQL, so guard creation the same way the rest of this file guards
-- idempotent DDL.
do $$ begin
  if not exists (
    select 1 from pg_type where typname = 'archive_result' and typnamespace = 'pgpm'::regnamespace
  ) then
    create type pgpm.archive_result as (covered_hi text, rows_archived bigint, s3_key text, etag text);
  end if;
end $$;

-- the trivial built-in strategy: exists only to exercise real dispatch (a real regprocedure call,
-- not a null-strategy special case) in tests. Always reports the whole requested range archived
-- immediately -- functionally what a 'none'-strategy table already gets from
-- _run_archive_strategy's null handling below, just reached via a real archive_fn call.
create or replace function pgpm._archive_noop(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_rows bigint; v_result pgpm.archive_result;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                 v_nsp, p_child, cfg.control_column, pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch),
                 cfg.control_column, pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch))
    into v_rows;
  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  return v_result;
end;
$$;

-- the dispatch stub: looks up config.archive_fn and calls it. A null archive_fn (strategy 'none')
-- never actually archives anything, so the requested range is trivially "already fully covered" --
-- there is nothing to protect against a drop.
create or replace function pgpm._run_archive_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare cfg pgpm.config; v_result pgpm.archive_result;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then
    v_result.covered_hi := p_hi;
    v_result.rows_archived := null;
    return v_result;
  end if;
  -- select * from fn(...), not select fn(...): the latter returns the composite as ONE column,
  -- which EXECUTE ... INTO a named-composite variable maps positionally (1 source column against
  -- pgpm.archive_result's 2 fields) rather than assigning the whole value -- covered_hi would end
  -- up holding the composite's own text form and rows_archived would stay null. Calling it as a
  -- FROM-item expands its fields into real output columns first.
  execute format('select * from %s($1,$2,$3,$4)', (cfg.archive_fn::oid::regproc)::text)
    into v_result using p_parent, p_child, p_lo, p_hi;
  return v_result;
end;
$$;

-- ============= byte-budget chunked archiving on the archive_fn contract (issue #237) =============
-- Ports archive._next_range_byte_budget/archive.archive_range/archive.ledger (#213, #221) -- the
-- mechanism that makes archiving a large partition safe without one giant transaction -- onto the
-- archive_fn contract, unchanged in intent. The one real adaptation: the original picked a range
-- across the WHOLE table, bounded by the frontier and the retention horizon directly, because
-- nothing else gated eligibility yet. Here that gating is already done per child by the write-block
-- trigger (#235) -- a child only becomes a candidate once _enforce_write_blocks has actually
-- installed it -- so the chunk picker only ever needs to work within ONE already-eligible child's
-- own [lo, hi), never across partition boundaries. archive.ledger/archive.archive_range/archive.tick
-- in pgpm_archive are untouched and keep working exactly as before; they are deleted only once this
-- path is proven out (#240).

-- successor to archive.ledger, same shape (parent_table, lo, hi, child_name nullable, s3_key, etag,
-- rows_archived, archived_at), primary key (parent_table, lo) since a chunk always belongs to
-- exactly one child and one parent's chunks never overlap. s3_key/etag come straight from
-- pgpm.archive_result (issue #239 widened the contract to carry them) -- populated for a real
-- transport strategy (e.g. pgpm_archive's pgpm.archive_to_s3_ndjson/archive_to_s3_parquet), still
-- null for a strategy with nothing object-store-shaped to name (pgpm._archive_noop, the 'none'
-- strategy). rows_archived is nullable (unlike the original's not null): the contract explicitly
-- allows a strategy to report no progress on a given call.
create table if not exists pgpm.archive_ledger (
  parent_table  regclass    not null,
  lo            text        not null,
  hi            text        not null,
  child_name    name,
  s3_key        text,
  etag          text,
  rows_archived bigint,
  archived_at   timestamptz not null default now(),
  primary key (parent_table, lo)
);
create index if not exists archive_ledger_parent_child_hi_idx on pgpm.archive_ledger (parent_table, child_name, hi desc);

-- picks the next chunk to archive within ONE child: resumes from wherever pgpm.archive_ledger's
-- coverage of THIS child left off (or the child's own lo, on the first call), estimates how many
-- rows fit config.archive_byte_budget via a sampled average row width (config.archive_probe_sample
-- rows), then extends to the next distinct control value past the probed boundary so a run of ties
-- never splits across two chunks -- identical reasoning to the original, just scoped to the child's
-- own table instead of the parent. Returns no rows once the child is fully covered.
create or replace function pgpm._next_archive_chunk(p_parent regclass, p_child name)
returns table(lo text, hi text)
language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_ncast text;
  v_child_lo text; v_child_hi text; v_lo text;
  v_avg numeric; v_batch int; v_batch_count int; v_probe_hi_col text; v_probe_hi text;
  v_next_distinct_col text; v_stop text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);

  select p.lo, p.hi into v_child_lo, v_child_hi from pgpm.part p
   where p.parent_table = p_parent and p.child_name = p_child;
  if not found then raise exception 'pg_partition_magician: %.% is not a tracked partition', p_parent, p_child; end if;

  -- hi is stored as text; a plain max() would compare lexicographically ('91' > '1000'), not
  -- numerically/temporally -- cast to the native type first, the same fix archive._file_watermark
  -- already needed for this exact reason.
  execute format('select max(hi::%s)::text from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L',
                 v_ncast, p_parent::text, p_child)
    into v_lo;
  v_lo := coalesce(v_lo, v_child_lo);

  if not pgpm._native_gt(cfg.control_kind, v_child_hi, v_lo) then
    return;   -- already fully covered
  end if;

  execute format(
    'select avg(pg_column_size(t.*))::numeric from (select * from %I.%I t where t.%I >= %L order by t.%I limit %s) t',
    v_nsp, p_child, cfg.control_column, pgpm._encode(cfg.control_kind, v_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch), cfg.control_column, cfg.archive_probe_sample)
    into v_avg;
  if coalesce(v_avg, 0) <= 0 then
    -- no rows remain in [v_lo, child_hi) for this child. Unlike the original (which read ahead of a
    -- still-moving frontier, where "nothing yet" could mean "not yet arrived"), this child is
    -- already write-blocked and frozen -- nothing will EVER land here again, so the rest of its
    -- range is trivially covered with zero rows archived.
    lo := v_lo; hi := v_child_hi;
    return next;
    return;
  end if;
  v_batch := greatest(1, floor(cfg.archive_byte_budget::numeric / v_avg))::int;

  execute format(
    'select count(*), max(%I)::text from (select %I from %I.%I t where t.%I >= %L order by t.%I limit %s) s',
    cfg.control_column, cfg.control_column, v_nsp, p_child, cfg.control_column,
    pgpm._encode(cfg.control_kind, v_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch), cfg.control_column, v_batch)
    into v_batch_count, v_probe_hi_col;

  if v_batch_count < v_batch then
    v_stop := v_child_hi;   -- the byte budget reaches past this child's own live end
  else
    v_probe_hi := pgpm._decode(cfg.control_kind, v_probe_hi_col, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
    -- extend to the next distinct value past the boundary, so hi never splits a run of ties (a
    -- child's own CHECK bounds every row here to < v_child_hi already, so this can never overshoot it)
    execute format('select min(%I)::text from %I.%I t where t.%I > %L',
                   cfg.control_column, v_nsp, p_child, cfg.control_column, v_probe_hi_col)
      into v_next_distinct_col;
    v_stop := case when v_next_distinct_col is null then v_child_hi
                   else pgpm._decode(cfg.control_kind, v_next_distinct_col, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch) end;
  end if;

  if not pgpm._native_gt(cfg.control_kind, v_stop, v_lo) then
    return;   -- no progress possible this call
  end if;

  lo := v_lo; hi := v_stop;
  return next;
end;
$$;

-- true once pgpm.archive_ledger's recorded ranges for this child reach its own hi, or the strategy
-- is 'none' (nothing to protect against a drop). Chunks for a given child are gapless and
-- monotonically forward by construction (_next_archive_chunk always resumes exactly where the last
-- one left off), so the ledger's own max(hi) reaching the child's hi is exactly "the union covers
-- [lo, hi)" -- the same watermark reasoning archive._file_watermark already relied on.
create or replace function pgpm._archive_fully_covered(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_child_hi text; v_watermark text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then return true; end if;

  select p.hi into v_child_hi from pgpm.part p where p.parent_table = p_parent and p.child_name = p_child;
  if not found then raise exception 'pg_partition_magician: %.% is not a tracked partition', p_parent, p_child; end if;

  -- hi is text; cast to the native type before max()'ing, same reasoning (and the same fix) as
  -- _next_archive_chunk above -- a plain max() would compare lexicographically.
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select max(hi::%s)::text from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L',
                 v_ncast, p_parent::text, p_child)
    into v_watermark;

  return v_watermark is not null and not pgpm._native_gt(cfg.control_kind, v_child_hi, v_watermark);
end;
$$;

-- one maintenance tick's worth of chunked archiving: picks up to config.archive_batch (default 1;
-- null = unlimited, same escape hatch retain_batch already has -- issue #351) attached children
-- that ALREADY have the write-block trigger installed (checked directly against pg_trigger, not
-- re-derived from the boundary formula -- this is what keeps archiving from ever running ahead of
-- write-blocking) and are not yet fully covered, oldest first, and for each picks its next chunk,
-- runs the configured strategy, and records progress. Returns how many chunks were recorded this
-- call. A 'none' strategy (archive_fn null) has nothing to do -- every child is already "covered"
-- per _archive_fully_covered above.
--
-- IDENTITY, BEFORE ANY READ OF THE CHILD (issue #421). What this loop selects out of pgpm.part is a
-- NAME, and everything downstream of it re-resolves that name independently and by itself: the
-- eligibility test above matches it against pg_class, _next_archive_chunk reads %I.%I three times to
-- size the chunk, and archive_fn is handed the bare string (its signature takes `p_child name`, a
-- published extension point that pgpm.set_archive_fn type-checks, so widening it to carry an OID is
-- not available). The check below is therefore made ONCE here, at the top of each candidate's turn,
-- which is the only place that covers all of them.
create or replace function pgpm._archive_step(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; v_nsp name; v_now regclass;
  r record; v_range record; v_result pgpm.archive_result; v_count int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then return 0; end if;

  v_ncast := pgpm._native_type(cfg.control_kind);
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- oldest first, matching retain()'s own convention -- archiving history in age order. The
  -- eligibility checks live in the WHERE clause (not a `continue` inside the loop, the old shape)
  -- specifically so `limit` bounds the right set: every row this query returns is a genuine
  -- candidate, so archive_batch caps how many DIFFERENT partitions get a turn this call, not how
  -- many rows happen to be scanned before finding that many.
  for r in execute format(
    'select p.child_name, p.child_oid, p.lo, p.hi from pgpm.part p
      where p.parent_table = %L::regclass and p.attached
        and pgpm._is_write_blocked(%L::regclass, p.child_name)
        and not pgpm._archive_fully_covered(%L::regclass, p.child_name)
      order by p.lo::%s
      limit %s',
    p_parent::text, p_parent::text, p_parent::text, v_ncast, coalesce(cfg.archive_batch::text, 'all'))
  loop

    -- Two independent facts have to agree, exactly as in retire()'s own identity check (#407): the
    -- name resolves, and it resolves to the OID recorded when this partition entered pgpm.part.
    -- `is distinct from` so a name that resolves to nothing at all trips this too. A null child_oid
    -- is unanchored (see the column's own note) and is left to behave as it did before.
    --
    -- `continue`, not a raise or a return: one partition whose name has stopped meaning what it
    -- meant is not a reason to abandon the tick, and the loop above is already the per-candidate
    -- shape that makes skipping one of them the natural thing to do. It is still fail-CLOSED for the
    -- partition itself -- no chunk is read, no ledger row is written, so _archive_fully_covered
    -- stays false and retire()'s drop precondition stays shut -- and it stays closed, because there
    -- is no later tick on which the name goes back to meaning the right relation. That makes it a
    -- wedge an operator has to resolve (pgpm.forget_missing, or putting the name back), which is why
    -- it is logged as a prefixed non-success action and counted by status() alongside the other
    -- things that stall retention. At archive_batch's default of 1 it also stops this parent's
    -- archiving behind it, which is the correct reading: pgpm's catalog is provably wrong about
    -- which relation is which, and retention should not march on past that.
    v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));
    if r.child_oid is not null and v_now::oid is distinct from r.child_oid then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_archive_identity', r.lo, r.hi,
                format('%I.%I is oid %s now, not the oid %s recorded for this partition; refusing to archive it',
                       v_nsp, r.child_name, coalesce(v_now::oid::text, 'nothing'), r.child_oid));
      continue;
    end if;

    select * into v_range from pgpm._next_archive_chunk(p_parent, r.child_name);
    if not found then continue; end if;

    v_result := pgpm._run_archive_strategy(p_parent, r.child_name, v_range.lo, v_range.hi);

    insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, etag, rows_archived)
    values (p_parent, v_range.lo, v_result.covered_hi, r.child_name, v_result.s3_key, v_result.etag, v_result.rows_archived);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ============================== regrain ==============================

-- regrain splits a FROZEN coarse child (the monolith, or a coarser child from a prior pass) into finer
-- children, by COPYING the rows into standalone children in budget-sized microbatches, then in ONE atomic
-- step detaching the coarse source, attaching the fine children, and DROPping the source. It never deletes
-- a row out of the source -- the source stays whole and ATTACHED until the swap, so every row remains
-- visible through the parent the entire time. The product has no dead tuples (the fine children only ever
-- receive inserts) and no vacuum (the source's space is reclaimed by the DROP, not by DELETE). Because the
-- rows are never moved through an unattached child, regrain NEVER opens the snapshot() read gap, and the
-- multi-tick COPY needs no FK leash (only a delete-and-move design would need one) -- REDESIGN.md
-- sections 9 and 10. The one exception is the swap's DETACH itself: Postgres refuses to detach a partition
-- whose rows are still referenced by an incoming FK (the keys leave the parent between detach and the
-- re-attach of the copies, which it will not look past), so the swap transiently drops the incoming FK(s)
-- and re-adds them within its ONE atomic transaction -- invisible to other sessions, so RI is never visibly
-- off, unlike the move-model's whole-regrain suspension. Retention-aware: a sub-range entirely below the
-- retention horizon is NOT copied (it is discarded with the source at the DROP), so retention costs no delete.
--
-- The work is a series of resumable microbatches (regrain_step). Because the source is frozen and is never
-- deleted from, it cannot drive progress the way a shrinking source would, so progress is tracked
-- explicitly by config.regrain_cursor: the native-grid lo of the sub-range currently being copied. A child is
-- built to completion (one budget batch at a time, resumed from its own high-water mark) before the cursor
-- advances to the next sub-range; when the cursor reaches the coarse hi every sub-range is copied (or aged
-- and skipped) and the swap runs. regrain() loops regrain_step in ONE transaction (atomic, gap-free) -- the
-- operator's "do it now". maintain() calls regrain_step ONCE per tick when auto-regrain is on (REDESIGN.md sec
-- 12), feathering the copy under the live workload across ticks. The cross-tick path leaves copies in
-- not-yet-attached children between ticks, but since the source still holds those rows, the parent's count
-- is never short and snapshot() must NOT union those copies (it would double-count).

-- ===================== regrain change capture and reconcile (issue #267) =====================
--
-- regrain COPIES, and its copy is resume-safe three ways: a `>= max(dest.ctl)` high-water bound, a
-- `not exists` anti-join on the reused key, and a cursor that advances past a completed sub-range and
-- never returns. NONE of the three is a reconcile -- the copy only ever ADDS rows and only ever moves
-- FORWARD -- and the swap then drops the source, so without this apparatus the copy silently becomes the
-- authority for everything that changed after it ran: a committed INSERT is destroyed, a committed DELETE
-- comes back, a committed UPDATE reverts.
--
-- "Frozen" (regrain_step's precondition) does NOT mean immutable: it only says the write frontier has
-- moved past the child. A backdated INSERT or an explicit low id routes straight into it, a
-- cross-partition UPDATE can move a row in, and DELETE/payload-UPDATE of history never involved the
-- frontier at all. So capture must be correct however much arrives, not merely for a well-behaved
-- append-only workload.
--
-- Shape: the delta table and its trigger function are PER PARENT and persistent (named from the parent,
-- which is stable -- naming from the child would break, since #266's fix renames the source mid-flight);
-- only the trigger on the source child is per regrain. Lifecycle therefore reduces to rows, not
-- relations, and an abandoned regrain leaks a trigger the janitor removes rather than an orphan table.

create or replace function pgpm._regrain_capture_names(
  p_parent regclass, out nsp name, out delta name, out fn name
) returns record language plpgsql stable as $$
declare v_rel name;
begin
  select n.nspname, c.relname into nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  delta := left(v_rel || '_pgpm_regrain_delta', 63)::name;
  fn    := left(v_rel || '_pgpm_regrain_capture', 63)::name;
end;
$$;

-- Install capture for a regrain of p_child: mint the per-parent delta table and trigger function if this
-- parent has never regrained, clear any residue from a previous regrain, and put the trigger on the source
-- child. CREATE TRIGGER takes SHARE ROW EXCLUSIVE, which conflicts with ROW EXCLUSIVE, so in-flight DML
-- blocks the install and DML afterwards sees the trigger: once this commits nothing can have slipped past
-- uncaptured. That lock is why this is its own tick -- sharing a transaction with a copy batch would hold
-- it across the batch instead of for an O(1) statement.
create or replace function pgpm._regrain_capture_install(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare
  v_nsp name; v_delta name; v_fn name; v_keyidx oid; v_keycols_q text; v_newvals_q text; v_oldvals_q text;
  v_bad_q text;
begin
  select nsp, delta, fn into v_nsp, v_delta, v_fn from pgpm._regrain_capture_names(p_parent);

  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_parent and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_parent and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is null then
    raise exception 'pg_partition_magician: cannot capture regrain changes on % -- no primary key or unique constraint', p_parent;
  end if;

  -- A NULL key component can never be matched by the row-constructor reconcile below, so its change would
  -- be silently lost -- the exact failure this apparatus exists to prevent. PK columns are NOT NULL, but a
  -- reused UNIQUE key may legitimately permit nulls, so refuse rather than lose the change.
  select string_agg(quote_ident(a.attname), ', ') into v_bad_q
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx and not a.attnotnull;
  if v_bad_q is not null then
    raise exception 'pg_partition_magician: cannot regrain % -- its reused key has nullable column(s) (%), and a NULL key component cannot be reconciled, so a concurrent change to such a row would be lost. Add NOT NULL to those columns, then re-run.',
      p_parent, v_bad_q;
  end if;

  select string_agg(quote_ident(a.attname), ', ' order by k.ord),
         string_agg('new.' || quote_ident(a.attname), ', ' order by k.ord),
         string_agg('old.' || quote_ident(a.attname), ', ' order by k.ord)
    into v_keycols_q, v_newvals_q, v_oldvals_q
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx;

  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then
    execute format('create table %I.%I as select %s from %s with no data', v_nsp, v_delta, v_keycols_q, p_parent::text);
    -- monotonic ordering column so a reconcile pass can batch by a pgpm_seq watermark: a batch processes
    -- and deletes rows at or below the watermark, and anything arriving mid-batch lands higher for the next
    -- pass. Excluded by name wherever key columns are introspected.
    execute format('alter table %I.%I add column pgpm_seq bigint generated always as identity', v_nsp, v_delta);
    execute format('create index on %I.%I (pgpm_seq)', v_nsp, v_delta);
  end if;
  execute format('truncate %I.%I', v_nsp, v_delta);   -- residue from an earlier regrain is not ours

  execute format('create or replace function %I.%I() returns trigger language plpgsql as $pgpm$
    begin
      if tg_op = ''DELETE'' then
        insert into %I.%I (%s) values (%s); return old;
      elsif tg_op = ''UPDATE'' then
        insert into %I.%I (%s) values (%s), (%s); return new;   -- old + new: a key change dirties both
      else
        insert into %I.%I (%s) values (%s); return new;
      end if;
    end $pgpm$',
    v_nsp, v_fn,
    v_nsp, v_delta, v_keycols_q, v_oldvals_q,
    v_nsp, v_delta, v_keycols_q, v_oldvals_q, v_newvals_q,
    v_nsp, v_delta, v_keycols_q, v_newvals_q);

  execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, p_child);
  execute format('create trigger pgpm_regrain_capture after insert or update or delete on %I.%I for each row execute function %I.%I()',
                 v_nsp, p_child, v_nsp, v_fn);
end;
$$;

-- true iff p_child currently carries the capture trigger
create or replace function pgpm._regrain_capture_active(p_parent regclass, p_child name)
returns boolean language plpgsql stable as $$
declare v_nsp name;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  return exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                  where t.tgname = 'pgpm_regrain_capture' and c.relname = p_child
                    and c.relnamespace = v_nsp::regnamespace);
end;
$$;

-- how many captured changes are still outstanding (used by the swap gate and by status)
create or replace function pgpm._regrain_delta_count(p_parent regclass)
returns bigint language plpgsql stable as $$
declare v_nsp name; v_delta name; v_n bigint;
begin
  select nsp, delta into v_nsp, v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return 0; end if;
  execute format('select count(*) from %I.%I', v_nsp, v_delta) into v_n;
  return v_n;
end;
$$;

-- Discard captured keys whose control has left this child's range: a cross-partition UPDATE moved the row
-- out, and its OLD-key entry (still in range) already covers the removal here. Such an entry can never
-- apply AND can never become eligible, so leaving it forever would wedge the swap gate, which counts every
-- delta row.
--
-- Deliberately NOT part of the per-tick reconcile. The predicate is a negated range, which no index serves,
-- so running it per tick meant a seq scan of the whole delta on every tick -- O(delta) work per tick and
-- O(delta^2 / batch) overall, which is the same shape #272 removed from the watermark query and which the
-- bench/regrain_perf.sh guard caught still present here. It is only the swap gate that these rows can
-- affect, so it runs once, immediately before that gate.
create or replace function pgpm._regrain_delta_purge(p_parent regclass, p_lo text, p_hi text)
returns void language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_delta name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return; end if;
  execute format('delete from %I.%I where not (%3$s >= %4$L and %3$s < %5$L)',
                 v_nsp, v_delta, quote_ident(cfg.control_column),
                 pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch), pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch));
end;
$$;

-- Reconcile up to p_batch captured keys, returning how many were consumed.
--
-- THE CONTRACT: for each captured key the SOURCE is the authority, not the recorded change. Delete the
-- key's row from its fine child, then reinsert the source's current row for that key if it still exists.
-- One rule covers all three defects, and critically it covers keys the copy has NEVER SEEN, which the
-- INSERT case needs and which any replay-the-change design would miss. It is idempotent and
-- order-independent per key, which is what makes it safe under READ COMMITTED: a synchronous
-- apply-the-change trigger is not, because it can fire against a copy that does not hold the row yet and
-- then be overwritten by a copy statement running from an earlier snapshot.
--
-- ELIGIBILITY: only keys whose control value lies strictly BELOW the cursor, i.e. in a sub-range the copy
-- has already finished. Two reasons. The copy can still reach anything at or above the cursor by itself,
-- so reconciling there is wasted work; and writing into the sub-range currently being copied would move
-- max(dest.ctl), which the copy uses as its resume point, making it skip the rows in between. At the swap
-- the cursor is at hi, so everything becomes eligible.
create or replace function pgpm._regrain_reconcile(
  p_parent regclass, p_child name, p_lo text, p_hi text, p_step text, p_cursor text, p_batch int
) returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_delta name; v_ncast text; v_keycols_q text; v_dkey_q text;
  v_skey_q text; v_cols_q text; v_wm bigint; v_elig text; v_ctl_q text; v_sub_name name; v_n int := 0; r record;
  v_lo_lit text; v_hi_lit text; v_cur_lit text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return 0; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  select string_agg(quote_ident(attname), ', ' order by attnum),
         '(' || string_agg('d.' || quote_ident(attname), ', ' order by attnum) || ')',
         '(' || string_agg('s.' || quote_ident(attname), ', ' order by attnum) || ')'
    into v_keycols_q, v_dkey_q, v_skey_q
    from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
      and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';
  -- generated columns are omitted from the reinsert: they recompute, they are never inserted into
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped and attgenerated = '';

  -- The delta is populated by a trigger and nothing analyzes it, so on its first ticks it carries no usable
  -- row estimate and the planner misplans one of the statements below into a seq scan of the WHOLE delta.
  -- Measured: 1 seq scan reading every delta row per tick without stats, 0 with them. Same failure #164
  -- fixed for freshly minted children ("it sits at reltuples = -1 until autovacuum, and anything touching
  -- it misplans"), so it gets the same treatment. One-time: once analyzed the estimate stays good enough
  -- as the delta grows (47k estimated against 50k actual still planned correctly).
  if (select coalesce(reltuples, -1) from pg_class where oid = format('%I.%I', v_nsp, v_delta)::regclass) <= 0 then
    perform pgpm._analyze(format('%I.%I', v_nsp, v_delta)::regclass);
  end if;

  -- Compare in ENCODED space -- the control column's own type, against _encode'd boundaries -- exactly as
  -- the copy does with its v_lo_lit/v_hi_lit. Decoding per row instead (pgpm._decode(...)::native) is a
  -- function call the planner cannot index, which silently turned every reconcile tick into a seq scan of
  -- the WHOLE delta rather than an indexed read of one batch: measured 272 ms to pick 5000 rows out of a
  -- 300k delta, against 1.0 ms once the pgpm_seq index is usable. That made the tick scale with the delta
  -- instead of with the budget, so draining a large delta cost O(delta^2 / batch). uuidv7 compares
  -- correctly this way because a UUIDv7 sorts by its embedded timestamp, which is why the copy can do it too.
  v_ctl_q   := quote_ident(cfg.control_column);
  v_lo_lit  := pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
  v_hi_lit  := pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
  v_cur_lit := pgpm._encode(cfg.control_kind, p_cursor, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);

  -- eligible: in this child's range AND behind the cursor
  v_elig := format('%1$s >= %2$L and %1$s < %3$L and %1$s < %4$L', v_ctl_q, v_lo_lit, v_hi_lit, v_cur_lit);

  execute format('select max(pgpm_seq) from (select pgpm_seq from %I.%I where %s order by pgpm_seq limit %s) t',
                 v_nsp, v_delta, v_elig, greatest(p_batch, 1)) into v_wm;
  if v_wm is null then return 0; end if;

  -- one pair of set-based statements per distinct fine child touched, not per key
  for r in execute format(
    'select distinct pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, %I::text, %L, %L, %L, %L, %L, %L, %L)) as sub_lo
       from %I.%I where pgpm_seq <= %s and %s',
    cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, cfg.control_column,
    cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit,
    cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch,
    v_nsp, v_delta, v_wm, v_elig)
  loop
    v_sub_name := pgpm._part_name(v_rel, cfg.control_kind, p_step, r.sub_lo,
                                  pgpm._grid_next(cfg.control_kind, p_step, r.sub_lo));
    -- No fine child means the sub-range was skipped as aged (regrain_aged): it is never materialized and
    -- its rows go with the source, so there is nothing to reconcile into. Counted, not silent.
    if to_regclass(format('%I.%I', v_nsp, v_sub_name)) is null then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'regrain_reconcile_aged', r.sub_lo, null, v_sub_name);
      continue;
    end if;
    execute format(
      'delete from %I.%I d where %s in (select %s from %I.%I k where k.pgpm_seq <= %s and %s
          and pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, k.%I::text, %L, %L, %L, %L, %L, %L, %L)) = %L)',
      v_nsp, v_sub_name, v_dkey_q, v_keycols_q, v_nsp, v_delta, v_wm, v_elig,
      cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, cfg.control_column,
      cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit,
      cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, r.sub_lo);
    execute format(
      'insert into %I.%I (%s) select %s from %I.%I s where %s in (select %s from %I.%I k where k.pgpm_seq <= %s and %s
          and pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, k.%I::text, %L, %L, %L, %L, %L, %L, %L)) = %L)',
      v_nsp, v_sub_name, v_cols_q, v_cols_q, v_nsp, p_child, v_skey_q, v_keycols_q, v_nsp, v_delta, v_wm, v_elig,
      cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, cfg.control_column,
      cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit,
      cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, r.sub_lo);
  end loop;

  execute format('delete from %I.%I where pgpm_seq <= %s and %s', v_nsp, v_delta, v_wm, v_elig);
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into pgpm.log (parent_table, action, lo, hi, rows)
      values (p_parent, 'regrain_reconcile', p_lo, p_hi, v_n);
  end if;
  return v_n;
end;
$$;

-- The janitor (#267). Change capture is installed per regrain and normally dies with the source at the
-- swap, but a regrain can be abandoned silently: the operator sets regrain_to to null mid-flight, or drives
-- a manual regrain of child A while auto-regrain is working child B and the two clobber the shared cursor.
-- A left-behind trigger taxes every write to that child and fills a delta nobody reads.
--
-- The child that legitimately carries capture is derivable with no extra state: the attached child whose
-- range covers regrain_cursor, and none at all when the cursor is null. `hi` is inclusive here because a
-- regrain awaiting its swap sits with the cursor exactly at hi. Deliberately conservative: it only tears
-- down capture it can prove is orphaned, never one that might still be live.
--
-- Mirrors _enforce_write_blocks: reconcile every child's state against current policy, once per tick.
-- Same per-child isolation as _enforce_write_blocks (issue #360), and for the same reason: the
-- `drop trigger` below takes a lock, and one child's failure to acquire it must not stop the janitor
-- from reaching every other child this tick. Logged as skip_regrain_capture, distinct from
-- skip_write_block, so pgpm.log does not conflate which of the two actually failed.
create or replace function pgpm._enforce_regrain_capture(p_parent regclass)
returns void language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_keep boolean; r record;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then return; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  for r in select child_name, lo, hi from pgpm.part where parent_table = p_parent
  loop
    begin
      if not pgpm._regrain_capture_active(p_parent, r.child_name) then continue; end if;
      v_keep := cfg.regrain_cursor is not null
            and not pgpm._native_gt(cfg.control_kind, r.lo, cfg.regrain_cursor)       -- lo <= cursor
            and not pgpm._native_gt(cfg.control_kind, cfg.regrain_cursor, r.hi);      -- cursor <= hi
      if not v_keep then
        execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, r.child_name);
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'regrain_capture_orphan', r.lo, r.hi, r.child_name);
      end if;
    exception when others then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'skip_regrain_capture', r.lo, r.hi, left(sqlerrm, 200));
    end;
  end loop;
end;
$$;

-- Stop an in-flight regrain and reclaim what it has built. Returns the number of in-flight fine children
-- dropped. The janitor above handles the silent abandonments; this is the operator's deliberate escape.
--
-- The copies MUST be dropped, not kept. Keeping them looks thriftier, but a later regrain would resume from
-- copies made before this cancel and therefore never reconciled, which is exactly the bug #267 closes. The
-- source still holds every row, so discarding them costs only the work, never data.
create or replace function pgpm.regrain_cancel(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_delta name; v_dropped int := 0; r record;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  for r in select child_name from pgpm.part where parent_table = p_parent loop
    execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, r.child_name);
  end loop;

  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is not null then
    execute format('truncate %I.%I', v_nsp, v_delta);
  end if;

  for r in select child_name from pgpm.part where parent_table = p_parent and not attached loop
    execute format('drop table if exists %I.%I', v_nsp, r.child_name);
    delete from pgpm.part where parent_table = p_parent and child_name = r.child_name;
    v_dropped := v_dropped + 1;
  end loop;

  update pgpm.config set regrain_cursor = null where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, rows) values (p_parent, 'regrain_cancel', v_dropped);
  return v_dropped;
end;
$$;

-- one resumable microbatch of regrain work on coarse child p_child toward target step p_target_step.
-- Returns: 'copied:N' (copied N rows into the current fine child), 'swapped:K' (cursor reached hi -> detached
-- the source, attached K fine children, dropped it: regrain done), or a soft no-progress status ('active' =
-- not frozen yet, 'nosubdiv' = the step does not subdivide).
create or replace function pgpm.regrain_step(
  p_parent regclass, p_child name, p_target_step text default null, p_batch int default null
) returns text language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_child regclass; v_cols_q text; v_ncast text; v_pkjoin_q text; v_keyidx oid;
  v_lo text; v_hi text; v_step text; v_frontier text; v_floor text; v_has boolean;
  v_retain_boundary text; v_batch int; v_reltuples real; v_avg numeric;
  v_cursor text; v_grid_lo text; v_sub_lo text; v_sub_hi text; v_sub_name name;
  v_lo_lit text; v_hi_lit text; v_moved bigint := 0; v_aged boolean; v_made int := 0; v_fk int := 0; r record;
  v_fk_ids bigint[];
  v_child_name name; v_src_name name; v_rec int; v_delta_n bigint; v_i int; v_delta_name name; v_busy name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);
  v_step  := coalesce(p_target_step, cfg.partition_step);

  select lo, hi into v_lo, v_hi from pgpm.part
   where parent_table = p_parent and child_name = p_child and attached;
  if not found then
    raise exception 'pg_partition_magician: % is not an attached managed partition of %', p_child, p_parent;
  end if;
  v_child      := format('%I.%I', v_nsp, p_child)::regclass;
  v_child_name := p_child;   -- may be renamed below (#266); v_child is an oid and follows it for free
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped
      and attgenerated = '';   -- omit generated columns: they recompute on insert, never inserted into
  -- the reused-key equijoin (d.<key> = s.<key>, every key column): the copy is an anti-join against it, so
  -- a resumed batch never re-copies a row already in the child even when the control column is non-unique.
  -- The key is whatever transmute reused: a PRIMARY KEY, or (relaxed key contract) a UNIQUE constraint.
  -- A truly KEYLESS monolith has no key to identify rows by, so a resumable copy cannot dedup -- regrain is
  -- refused for it below ('nokey'); the coarse monolith stays a correct, queryable permanent state.
  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_parent and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_parent and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is not null then
    select string_agg(format('d.%I = s.%I', a.attname, a.attname), ' and ' order by k.ord) into v_pkjoin_q
      from pg_index i
      cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
     where i.indexrelid = v_keyidx;
  end if;
  if v_pkjoin_q is null then return 'nokey'; end if;

  -- frozen? (whole range at/below the current grid floor, so no live write still lands in it)
  v_frontier := pgpm._frontier_native(p_parent);
  v_floor    := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier);
  if pgpm._native_gt(cfg.control_kind, v_hi, v_floor) then return 'active'; end if;
  -- the target step must actually subdivide the child
  if not pgpm._native_gt(cfg.control_kind, v_hi, pgpm._grid_next(cfg.control_kind, v_step, v_lo)) then
    return 'nosubdiv';
  end if;
  -- ONE regrain per parent at a time (#267). This is a correctness guard, not tidiness: both
  -- config.regrain_cursor and the change-capture delta are per parent, so a second regrain starting on a
  -- different child would reset the first one's cursor AND truncate its delta at prepare, silently
  -- discarding captured changes the first regrain had not applied yet. That is the same class of loss this
  -- apparatus exists to prevent. The cursor thrash alone predates capture (each child resets the cursor
  -- into its own range), so this refusal closes a pre-existing hazard too.
  --
  -- Placed BEFORE the #266 rename below, so a refused regrain mutates nothing at all -- not even the
  -- transitional rename of the child it was never going to split. After the soft statuses above, so a
  -- not-yet-frozen child still answers 'active' rather than raising.
  select p.child_name into v_busy from pgpm.part p
   where p.parent_table = p_parent and p.child_name <> v_child_name
     and pgpm._regrain_capture_active(p_parent, p.child_name)
   limit 1;
  if v_busy is not null then
    raise exception 'pg_partition_magician: cannot regrain % -- a regrain of % is already in flight on this parent, and pgpm runs one regrain per parent (config.regrain_cursor and the change-capture delta are both per parent). Let it finish, or abandon it with pgpm.regrain_cancel(%), then re-run.',
      v_child_name, v_busy, p_parent;
  end if;

  -- ...and the source must not be named as its own first fine sub-range (issue #266). _part_name gives a
  -- one-step range the bare _p<lo> and a wider one the explicit _p<lo>_to_<hi>, and the note above it says
  -- why: the wide form exists "so it can never collide with the fine child at its low edge". But "wider"
  -- was judged on the child's OWN grid. A child exactly one step wide is not wide there, so it kept _p<lo>
  -- -- and regrain then reinterprets it on a FINER grid, where its own first sub-range renders _p<lo> too.
  -- That was silent data loss, not a cosmetic clash: the "does the destination exist yet?" check below
  -- found the SOURCE, took it for an already-created destination, the anti-join copy moved nothing,
  -- v_moved < v_batch advanced the cursor as though the sub-range were done, and the swap's DROP TABLE took
  -- those rows with it.
  --
  -- Finish the design instead of refusing: rename the source to its own name as rendered on the TARGET
  -- grid. `nosubdiv` above already established v_hi > grid_next(v_step, v_lo), so on that grid the source
  -- IS wider than one step and always takes the explicit _to_ form, which no one-step sub-range can equal.
  -- This is safe precisely because of the other half of that note: the name is a human-facing LABEL and
  -- pgpm.part holds the authoritative bounds. v_child is an oid, so every later statement here follows the
  -- table with no re-resolution. Derived from v_lo rather than the cursor, so it also fires for a regrain
  -- resumed past its first sub-range instead of reaching the swap with the collision still ahead of it.
  v_grid_lo := pgpm._grid_floor(cfg.control_kind, v_step, cfg.partition_anchor, v_lo);
  v_sub_lo  := case when pgpm._native_gt(cfg.control_kind, v_lo, v_grid_lo) then v_lo else v_grid_lo end;
  v_sub_hi  := pgpm._grid_next(cfg.control_kind, v_step, v_grid_lo);
  if pgpm._native_gt(cfg.control_kind, v_sub_hi, v_hi) then v_sub_hi := v_hi; end if;
  if pgpm._part_name(v_rel, cfg.control_kind, v_step, v_sub_lo, v_sub_hi) = v_child_name then
    v_src_name := pgpm._part_name(v_rel, cfg.control_kind, v_step, v_lo, v_hi);
    if to_regclass(format('%I.%I', v_nsp, v_src_name)) is not null then
      raise exception 'pg_partition_magician: cannot regrain % at target step % -- splitting it needs the transitional name %, which is already taken by another relation. Drop or rename that relation, then re-run.',
        v_child_name, v_step, v_src_name;
    end if;
    execute format('alter table %s rename to %I', v_child::text, v_src_name);
    update pgpm.part set child_name = v_src_name
     where parent_table = p_parent and child_name = v_child_name;
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'regrain_rename', v_lo, v_hi, v_child_name || ' -> ' || v_src_name);
    v_child_name := v_src_name;
  end if;
  -- The 'default_dirty' gate is gone with the DEFAULT (#288). It guarded against a stray sitting in the
  -- range, which would make a fine-child ATTACH fail at the swap; with a complete forward grid there is
  -- nowhere for a stray to sit except a real partition of the range being regrained.

  -- #267: change capture must be installed AND COMMITTED before any copy reads the source, or every change
  -- made during the first batch is lost. Its own tick, so CREATE TRIGGER's SHARE ROW EXCLUSIVE is an O(1)
  -- hold rather than one spanning a copy batch. Setting the cursor here too keeps the janitor's invariant
  -- ("cursor null => no child carries the trigger") true from the first tick, so it cannot tear down a
  -- regrain that is one tick old.
  if not pgpm._regrain_capture_active(p_parent, v_child_name) then
    -- A cursor already set with no capture installed means copies exist that were made WITHOUT capture:
    -- an interrupted regrain from before this apparatus, or one the janitor cleaned up mid-flight. Those
    -- copies are unreconciled, so resuming from them would reintroduce exactly this bug. Discard and
    -- restart, which is cheap: the source still holds every row.
    if cfg.regrain_cursor is not null then
      for r in execute format(
        'select child_name from pgpm.part where parent_table = %L::regclass and not attached'
        || ' and lo::%s >= %L::%s and hi::%s <= %L::%s',
        p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast)
      loop
        execute format('drop table if exists %I.%I', v_nsp, r.child_name);
        delete from pgpm.part where parent_table = p_parent and child_name = r.child_name;
        v_made := v_made + 1;
      end loop;
      insert into pgpm.log (parent_table, action, lo, hi, rows, method)
        values (p_parent, 'regrain_restart', v_lo, v_hi, v_made, 'copies predate change capture');
    end if;
    perform pgpm._regrain_capture_install(p_parent, v_child_name);
    update pgpm.config set regrain_cursor = v_lo where parent_table = p_parent;
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'regrain_prepare', v_lo, v_hi, v_child_name);
    return 'prepared';
  end if;

  -- retention horizon (matches retain(), issue #91)
  if cfg.retain is not null then
    if cfg.control_kind = 'id'
      then v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (v_frontier::numeric - cfg.retain::numeric)::text);
      else v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (now() - cfg.retain::interval)::text);
    end if;
  end if;

  -- budget (rows per microbatch): regrain_batch, capped by regrain_max_blocks via the coarse child's stats
  v_batch := coalesce(p_batch, cfg.regrain_batch, 5000);
  if cfg.regrain_max_blocks is not null then
    select c.reltuples into v_reltuples from pg_class c where c.oid = v_child;
    if coalesce(v_reltuples, 0) > 0 then v_avg := pg_table_size(v_child)::numeric / v_reltuples;
    else execute format('select avg(pg_column_size(t))::numeric from (select * from %s limit 1000) t', v_child::text) into v_avg;
    end if;
    if coalesce(v_avg, 0) > 0 then
      v_batch := least(v_batch, greatest(1, floor(cfg.regrain_max_blocks::numeric * 8192 / v_avg))::int);
    end if;
  end if;
  v_batch := greatest(1, v_batch);   -- a copied:0 batch must advance the cursor (0 < batch), never stall

  -- progress cursor: the lo of the sub-range currently being copied. null (fresh) or stale (out of this
  -- child's [lo,hi)) -> start at the coarse lo. The cursor only ever advances, one grid sub-range at a time.
  v_cursor := cfg.regrain_cursor;
  if v_cursor is null
     or pgpm._native_gt(cfg.control_kind, v_lo, v_cursor)        -- cursor < coarse lo
     or pgpm._native_gt(cfg.control_kind, v_cursor, v_hi) then   -- cursor > coarse hi
    v_cursor := v_lo;
  end if;

  -- #267: reconcile captured changes before copying more. Only sub-ranges the copy has already finished
  -- are eligible (see _regrain_reconcile), so this never disturbs max(dest.ctl) in the sub-range being
  -- copied. Bounded by the same budget as the copy, and it takes the tick when there is work, so a burst
  -- of DML paces itself instead of landing in the swap.
  v_rec := pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_cursor, v_batch);
  if v_rec > 0 then return 'reconciled:' || v_rec; end if;

  -- Advance over any aged (below-horizon) sub-ranges without copying them: they would be dropped by retain()
  -- the instant they became partitions, so they are simply discarded with the source at the swap (never
  -- materialized, and never deleted out of the source either). Aged ranges are the lowest in control order, a
  -- contiguous prefix, so this loop only runs at the bottom of the child. One regrain_aged per skipped range.
  --
  -- ONLY when there is nothing to archive (#278). That "they would be dropped by retain() anyway" reasoning
  -- was written before #238 gave retire a coverage gate, and stopped being true then: with archive_fn set,
  -- retire refuses to drop a partition until archiving has fully covered it, so discarding these rows
  -- destroys exactly what the gate is holding back, unarchived. Measured: 2000 rows gone, archive ledger
  -- empty.
  --
  -- So with archive_fn set the sub-range is materialized like any other, and the EXISTING pipeline takes it
  -- from there in the right order: _enforce_write_blocks blocks it (its whole range is below the horizon
  -- now that it is a partition), _archive_step archives it, retire drops it once covered. That also closes
  -- the write-block asymmetry, since a late backdated write lands in a partition that gets archived.
  --
  -- Not "wait for coverage before skipping", which cannot work: a PARTIALLY aged child straddles the
  -- horizon, so it is never write-blocked and therefore never archived, and the regrain would wait forever
  -- for coverage nothing produces.
  --
  -- The cost when archive_fn is set is copying rows that are about to be dropped. They have to be read to
  -- archive them regardless, so it is one extra write of doomed data, and only on tables that archive.
  loop
    exit when not pgpm._native_gt(cfg.control_kind, v_hi, v_cursor);   -- cursor >= hi: nothing left to copy
    v_grid_lo := pgpm._grid_floor(cfg.control_kind, v_step, cfg.partition_anchor, v_cursor);
    v_sub_lo  := case when pgpm._native_gt(cfg.control_kind, v_lo, v_grid_lo) then v_lo else v_grid_lo end;
    v_sub_hi  := pgpm._grid_next(cfg.control_kind, v_step, v_grid_lo);
    if pgpm._native_gt(cfg.control_kind, v_sub_hi, v_hi) then v_sub_hi := v_hi; end if;
    v_aged := v_retain_boundary is not null
              and cfg.archive_fn is null                                  -- #278: see above
              and not pgpm._native_gt(cfg.control_kind, v_sub_hi, v_retain_boundary);
    exit when not v_aged;                                             -- found a sub-range to copy
    insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'regrain_aged', v_sub_lo, v_sub_hi, 0);
    v_cursor := v_sub_hi;                                             -- skip the aged sub-range (no copy, no delete)
  end loop;

  -- still a sub-range to copy: ensure its fine child exists (standalone, born with its validated bound
  -- CHECK), then COPY one budget batch into it. The copy is an anti-join against the child's PK, resumed from
  -- the child's current max(control), so it never re-copies and never deletes. row_count < batch means the
  -- remaining rows fit in this batch -> the sub-range is complete, advance the cursor to the next one.
  if pgpm._native_gt(cfg.control_kind, v_hi, v_cursor) then
    v_lo_lit := pgpm._encode(cfg.control_kind, v_sub_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
    v_hi_lit := pgpm._encode(cfg.control_kind, v_sub_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
    v_sub_name := pgpm._part_name(v_rel, cfg.control_kind, v_step, v_sub_lo, v_sub_hi);
    -- invariant (#266): the rename above makes this unreachable. Assert it anyway -- when it was false the
    -- failure was silent row destruction, so a future change to _part_name must break loudly here.
    if v_sub_name = v_child_name then
      raise exception 'pg_partition_magician: internal error regraining % -- sub-range [%, %) resolves to the source child itself; refusing rather than copying into the table about to be dropped.',
        v_child_name, v_sub_lo, v_sub_hi;
    end if;
    if to_regclass(format('%I.%I', v_nsp, v_sub_name)) is null then
      execute format('create table %I.%I (like %I.%I including defaults including generated including storage including indexes including constraints excluding identity)',
                     v_nsp, v_sub_name, v_nsp, v_rel);
      execute format('alter table %I.%I add constraint %I check (%I >= %L and %I < %L)',
                     v_nsp, v_sub_name, (v_sub_name || '_ck'), cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit);
      -- #348: give the fine child its own already-validated copy of every outgoing FK the parent
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
      -- child_oid (#421): the fine child is standalone here and joins pg_inherits only at the swap,
      -- so this is the only point at which its identity can be recorded from the CREATE that made it.
      insert into pgpm.part (parent_table, child_name, lo, hi, attached, child_oid)
        values (p_parent, v_sub_name, v_sub_lo, v_sub_hi, false,
                format('%I.%I', v_nsp, v_sub_name)::regclass::oid)
        on conflict (parent_table, child_name) do nothing;
    end if;
    execute format($f$
      insert into %7$I.%8$I (%6$s)
      select %6$s from %1$s s
       where s.%2$I >= coalesce((select max(d2.%2$I) from %7$I.%8$I d2), %3$L)
         and s.%2$I < %4$L
         and not exists (select 1 from %7$I.%8$I d where %9$s)
       order by s.%2$I
       limit %5$s
    $f$, v_child::text, cfg.control_column, v_lo_lit, v_hi_lit, v_batch, v_cols_q, v_nsp, v_sub_name, v_pkjoin_q);
    get diagnostics v_moved = row_count;
    if v_moved > 0 then
      insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'regrain_copy', v_sub_lo, v_sub_hi, v_moved);
    end if;
    if v_moved < v_batch then
      v_cursor := v_sub_hi;                                          -- sub-range fully copied: advance
      -- the fine child holds all its rows now and is still standalone (it is attached later, at the swap):
      -- ANALYZE it here, off the swap's exclusive-lock window, so the swap and any query that hits it after
      -- see real stats, not reltuples = -1 (#164).
      perform pgpm._own_like_parent(p_parent, format('%I.%I', v_nsp, v_sub_name)::regclass);   -- #277
      perform pgpm._analyze(format('%I.%I', v_nsp, v_sub_name)::regclass);
    end if;
    update pgpm.config set regrain_cursor = v_cursor where parent_table = p_parent;
    return 'copied:' || v_moved;
  end if;

  -- #267: do not ENTER the swap carrying a backlog. The residual reconcile below runs inside the swap
  -- transaction, so it must be small; the gate is what keeps it so. Checked before the DETACH, because once
  -- that holds ACCESS EXCLUSIVE no further writes can arrive and the residual is only what was in flight at
  -- that instant. Deliberately no forcing: if writes outpace reconciliation the regrain stalls here
  -- indefinitely, which is correct -- the source stays attached, reads are unaffected, the table is
  -- consistent, and status() shows it. Forcing would put an unbounded reconcile under the lock.
  perform pgpm._regrain_delta_purge(p_parent, v_lo, v_hi);   -- junk cannot be allowed to wedge the gate
  v_delta_n := pgpm._regrain_delta_count(p_parent);
  if v_delta_n > v_batch then return 'reconciling:' || v_delta_n; end if;

  -- cursor reached hi: every sub-range is copied (or aged and skipped). Swap atomically -- detach the source,
  -- attach every not-yet-attached fine child within its range (metadata-only via each child's validated
  -- CHECK), drop the source whole (no DELETE; the aged rows that were never copied go with it).
  --
  -- DETACH is refused while an incoming FK still references the source's rows (they leave the parent between
  -- detach and the re-attach of the copies). Drop the incoming FK(s) for the swap and re-add them, all inside
  -- THIS one transaction, so no other session ever observes RI off. force=true since the copy did not
  -- suspend; v_fk=0 means there was no live preserve-managed FK to drop -- either the table has none, or
  -- the conversion's drop has not been restored yet -- so leave the re-add to restore_incoming_fks.
  --
  -- #378: snapshot exactly which rows are about to be suspended, BEFORE suspending them, and pass
  -- that exact set to restore_incoming_fks below -- not every not-yet-restored row for the parent.
  -- Without this, a pre-existing "stale" FK (one this swap never suspended, e.g. left unrestored by
  -- an earlier failed restore attempt) gets swept up by restore_incoming_fks's own "restore
  -- everything unrestored" default, and re-adding it needs a FRESH lock on its referencing table,
  -- taken while the managed parent is already under ACCESS EXCLUSIVE from the DETACH below -- so a
  -- contended referencing table blocks every other session on the parent too. Scoping to what THIS
  -- call suspended costs nothing (those tables' locks are already held by the suspend below, so
  -- restoring them is never a fresh acquisition) and leaves the stale FK for the next tick's own
  -- restore_incoming_fks call, exactly like the existing v_fk=0 case already does above.
  select array_agg(id) into v_fk_ids from pgpm.dropped_fk
   where parent_table = p_parent and restored_at is not null;
  v_fk := pgpm.suspend_incoming_fks(p_parent, true);
  execute format('alter table %s detach partition %s', p_parent::text, v_child::text);
  -- #267: the correctness backstop. The DETACH above holds ACCESS EXCLUSIVE on the source, so no further
  -- writes can arrive and this terminates. The cursor is at hi, so every captured key is now eligible.
  -- Bounded by the gate; the loop only covers what landed between the gate and the DETACH.
  for v_i in 1 .. 100 loop
    exit when pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_hi, greatest(v_batch, 1000)) = 0;
  end loop;
  for r in execute format(
    'select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and not attached and lo::%s >= %L::%s and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast, v_ncast)
  loop
    execute format('alter table %s attach partition %I.%I for values from (%L) to (%L)',
                   p_parent::text, v_nsp, r.child_name,
                   pgpm._encode(cfg.control_kind, r.lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch), pgpm._encode(cfg.control_kind, r.hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch));
    execute format('alter table %I.%I drop constraint %I', v_nsp, r.child_name, (r.child_name || '_ck'));
    update pgpm.part set attached = true where parent_table = p_parent and child_name = r.child_name;
    insert into pgpm.log (parent_table, action, lo, hi, method) values (p_parent, 'regrain_attach', r.lo, r.hi, 'check_skip');
    v_made := v_made + 1;
  end loop;
  delete from pgpm.part where parent_table = p_parent and child_name = v_child_name;   -- not p_child: #266 may have renamed it
  execute format('drop table %s', v_child::text);
  -- the capture trigger went with the dropped source (#267); clear the delta so the next regrain of this
  -- parent starts from an empty one and status() does not report a phantom backlog.
  select delta into v_delta_name from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta_name)) is not null then
    execute format('truncate %I.%I', v_nsp, v_delta_name);
  end if;
  -- re-add the FK(s) this swap dropped, against the new parent (the copies now hold every key). Only if WE
  -- dropped them (v_fk > 0): v_fk = 0 means there was nothing live to drop, so there is nothing here to put
  -- back -- restore_incoming_fks owns any FK still suspended from the conversion. Scoped to v_fk_ids (#378):
  -- exactly what was snapshotted above, before the suspend -- not every not-yet-restored row for the parent.
  if v_fk > 0 then perform pgpm.restore_incoming_fks(p_parent, v_fk_ids); end if;
  update pgpm.config set regrain_cursor = null where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, lo, hi, rows, method) values (p_parent, 'regrain', v_lo, v_hi, v_made, 'copy_swap_drop');
  return 'swapped:' || v_made;
end;
$$;

-- regrain(): the synchronous "do it now" driver -- loops regrain_step in ONE transaction (atomic, gap-free)
-- until the coarse child is fully split, and returns the number of fine children created. Soft no-progress
-- statuses become a hard error here (the operator gets a clear refusal); maintain() instead just skips.
create or replace function pgpm.regrain(p_parent regclass, p_child name, p_target_step text default null)
returns int language plpgsql as $$
declare v_status text; v_iter int := 0; v_child name := p_child; v_next name; v_lo text;
begin
  -- regrain_step may rename the source child on its first pass (#266: a child exactly one step wide is
  -- renamed to its coarse-form name on the target grid so its own first sub-range can take _p<lo>). Follow
  -- it by lo, which never changes, and re-resolve the name each iteration -- otherwise every iteration after
  -- the first would look up a name that no longer exists. Only the source is attached at that lo during the
  -- copy phase (fine children stay attached = false until the swap), so the lookup is unambiguous.
  select lo into v_lo from pgpm.part
   where parent_table = p_parent and child_name = p_child and attached;
  loop
    v_status := pgpm.regrain_step(p_parent, v_child, p_target_step, null);
    if v_status like 'swapped:%' then return split_part(v_status, ':', 2)::int; end if;
    if v_status in ('active', 'nosubdiv', 'nokey', 'idle') then
      raise exception 'pg_partition_magician: cannot regrain % -- %', p_child,
        case v_status
          when 'active' then 'it is still active (not frozen); wait until the frontier passes its upper bound'
          when 'nosubdiv' then 'the target step does not subdivide its range'
          when 'nokey' then 'it has no primary key or unique constraint, so a resumable copy cannot identify rows; regrain is unavailable for keyless tables (the coarse monolith remains a valid, queryable state)'
          else 'nothing to regrain' end;
    end if;
    v_iter := v_iter + 1;
    if v_iter > 10000000 then raise exception 'pg_partition_magician: regrain safety limit'; end if;
    if v_lo is not null then
      select p.child_name into v_next from pgpm.part p
       where p.parent_table = p_parent and p.lo = v_lo and p.attached;
      v_child := coalesce(v_next, v_child);
    end if;
  end loop;
end;
$$;

-- regrain_history(): convenience -- regrain the oldest coarse child (the monolith: the smallest-lo attached
-- partition) to p_target_step (default: the configured partition_step). Hierarchical regraining is just
-- repeated regrain() calls with chosen steps.
create or replace function pgpm.regrain_history(p_parent regclass, p_target_step text default null)
returns int language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_mon name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select child_name from pgpm.part where parent_table = %L::regclass and attached order by lo::%s asc limit 1',
                 p_parent::text, v_ncast) into v_mon;
  if v_mon is null then raise exception 'pg_partition_magician: % has no partitions to regrain', p_parent; end if;
  return pgpm.regrain(p_parent, v_mon, p_target_step);
end;
$$;

-- ============================== transmute ==============================

-- #275 turned these from FUNCTIONs into PROCEDUREs. CREATE OR REPLACE cannot change that, so the old
-- forms have to go first; an existing install upgrades cleanly through this.
drop function if exists pgpm._transmute(regclass, name, text, text, text, int, text, boolean, int, boolean, text, boolean, boolean);
drop function  if exists pgpm.transmute(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text, boolean, boolean);
drop function  if exists pgpm.transmute(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text, boolean);
-- #288 dropped p_keep_default and p_drain_adaptive and renamed p_drain_batch, so the previous PROCEDURE
-- forms must go as well or an upgrade leaves two overloads and every call becomes ambiguous.
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text, boolean, boolean, int);
drop procedure if exists pgpm.transmute(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text, boolean, int);
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, boolean, int, boolean, text, boolean, boolean, int);

create or replace procedure pgpm._transmute(
  p_parent regclass, p_control name, p_control_kind text,
  p_step text, p_anchor text, p_obtain int, p_retain text,
  p_regrain_batch int, p_paused boolean, p_incoming_fks text,
  p_force_uuidv7 boolean default false, p_bound_headroom int default 0,
  p_lock_timeout text default '5s',
  -- text_time only (issue #325 follow-up): a general opaque-sortable-TEXT id, e.g. classic cuid
  -- (p_tt_prefix 'c', p_tt_width 8, p_tt_radix 36, p_tt_unit 'ms'). Null for every other kind.
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_force_text_time boolean default false,
  -- covers formats the plain cuid case does not need: a custom digit alphabet (ULID's Crockford
  -- base32, KSUID's base62 -- neither is the default contiguous 0-9a-z), and a timestamp that is the
  -- top bits of a WIDER encoded value against a non-Unix epoch (KSUID: discard the low 128 bits of its
  -- whole-payload base62 encoding, epoch 2014-05-13 16:53:20+00).
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00'
)
language plpgsql as $$
declare
  v_nsp name; v_rel name; v_default name; v_staging name; v_parent regclass;
  v_resumed boolean := false;
  v_typname text; v_oldpk text[]; v_pkcols text[]; v_idcols name[]; v_pkname name; v_col name;
  v_idkinds text[];   -- #308: 'a' (ALWAYS) or 'd' (BY DEFAULT) per v_idcols entry, same order
  v_idx_names text[]; v_idx_defs text[]; v_ctl_attnum int; v_uniq_bad text; v_old name; v_new name; v_pdef_q text; j int;
  v_pgpm_clash_q text;   -- #311: existing relations occupying the <index>_pgpm names step 9b needs
  v_add_pk boolean := false; v_add_uniq boolean := false; v_reuse_idx oid; v_reuse_conname name;
  v_uq_cols text[]; v_bare_uq text;
  v_fk record; v_dropped jsonb := '[]'::jsonb; v_e jsonb; v_fk_eligible boolean;
  v_out_names text[]; v_out_defs text[]; v_bad_out text; v_i2 int;   -- outgoing FKs (#263)
  v_uchk_n bigint; v_uchk_frac numeric;
  v_idmax bigint[]; v_m bigint; v_i int; v_idnext bigint[]; v_seq text; v_n bigint;
  v_monolith name; v_monreg regclass;
  v_frontier_native text; v_min_raw text; v_max_raw text; v_min_native text; v_lo_native text; v_hi_native text;
  -- #277: everything CREATE TABLE ... LIKE does NOT carry, captured before the rename and replayed onto
  -- the new parent inside the cutover transaction.
  v_owner name; v_acl aclitem[]; v_rls boolean; v_rls_force boolean;
  v_comment text; v_colcom record; v_pol record; v_trg record; v_bad_trg text;
  v_prev_lock_timeout text;   -- #309: so validating p_lock_timeout leaves the setting untouched
  v_trgdefs text[] := '{}'; v_grant text; v_g record;
begin
  if p_control_kind not in ('time', 'id', 'uuidv7', 'text_time') then
    raise exception 'pg_partition_magician: unknown control_kind %', p_control_kind;
  end if;
  if p_incoming_fks not in ('error', 'drop', 'preserve') then
    raise exception 'pg_partition_magician: p_incoming_fks must be ''error'', ''drop'', or ''preserve'' (got %)', p_incoming_fks;
  end if;
  -- #309: validate the lock timeout HERE, before anything is committed. set_config raises on a bad value
  -- anyway, but it would do so from inside phase 1 or, worse, phase 3 -- after the O(rows) validation
  -- scan the operator has already waited through. A typo should cost nothing.
  --
  -- The prior value is restored immediately, so this check has NO side effect. That is not tidiness: the
  -- phases below share this transaction with the check, so a validation that left the setting applied
  -- would silently do phase 1's job for it. The mutation that proves bench/transmute_lock_timeout.sh
  -- discriminates strips the per-phase set_config calls, and it would strip them onto a transaction that
  -- was already correctly configured -- a guard that passed against its own defect.
  begin
    v_prev_lock_timeout := current_setting('lock_timeout');
    perform set_config('lock_timeout', p_lock_timeout, true);
    perform set_config('lock_timeout', v_prev_lock_timeout, true);
  exception when others then
    raise exception 'pg_partition_magician: p_lock_timeout must be a valid lock_timeout value (got %): %', p_lock_timeout, sqlerrm;
  end;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_default := (v_rel || '_default')::name;
  v_staging := (v_rel || '_pgpm_new')::name;

  -- control column type vs kind (and the float guard)
  select t.typname into v_typname
    from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;
  if v_typname is null then
    raise exception 'pg_partition_magician: column % not found on %', p_control, p_parent;
  end if;
  if p_control_kind = 'time' and v_typname not in ('timestamptz', 'timestamp', 'date') then
    raise exception 'pg_partition_magician: control_kind time needs a timestamp/date column (got %)', v_typname;
  elsif p_control_kind = 'id' then
    if v_typname in ('float4', 'float8') then
      raise exception 'pg_partition_magician: float/double control columns are unsupported (imprecise boundaries; NaN/Inf poison the frontier) -- use bigint or numeric';
    elsif v_typname not in ('int2', 'int4', 'int8', 'numeric') then
      raise exception 'pg_partition_magician: control_kind id needs an integer or numeric column (got %)', v_typname;
    end if;
  elsif p_control_kind = 'uuidv7' and v_typname <> 'uuid' then
    raise exception 'pg_partition_magician: control_kind uuidv7 needs a uuid column (got %)', v_typname;
  elsif p_control_kind = 'text_time' then
    if v_typname not in ('text', 'varchar') then
      raise exception 'pg_partition_magician: control_kind text_time needs a text or varchar column (got %)', v_typname;
    end if;
    if p_tt_prefix is null or p_tt_width is null or p_tt_radix is null or p_tt_unit is null then
      raise exception 'pg_partition_magician: control_kind text_time needs p_tt_prefix, p_tt_width, p_tt_radix and p_tt_unit all set -- e.g. classic cuid: prefix ''c'', width 8, radix 36, unit ''ms''';
    end if;
    -- p_tt_alphabet's own length IS the radix ceiling when supplied (ULID needs 32, KSUID needs 62);
    -- without one, the default contiguous 0-9a-z convention caps out at 36.
    if p_tt_alphabet is not null then
      if length(p_tt_alphabet) <> p_tt_radix then
        raise exception 'pg_partition_magician: p_tt_alphabet % has length %, which does not match p_tt_radix %', p_tt_alphabet, length(p_tt_alphabet), p_tt_radix;
      end if;
      if length(p_tt_alphabet) <> (select count(distinct c) from unnest(regexp_split_to_array(p_tt_alphabet, '')) c) then
        raise exception 'pg_partition_magician: p_tt_alphabet % has a repeated character, which makes decoding ambiguous', p_tt_alphabet;
      end if;
    elsif p_tt_radix < 2 or p_tt_radix > 36 then
      raise exception 'pg_partition_magician: p_tt_radix must be 2-36 for the default 0-9a-z alphabet (got %); supply p_tt_alphabet for a wider or different one', p_tt_radix;
    end if;
    if p_tt_width < 1 then
      raise exception 'pg_partition_magician: p_tt_width must be positive (got %)', p_tt_width;
    end if;
    if p_tt_unit not in ('ms', 's') then
      raise exception 'pg_partition_magician: p_tt_unit must be ''ms'' or ''s'' (got %)', p_tt_unit;
    end if;
    if p_tt_discard_bits < 0 then
      raise exception 'pg_partition_magician: p_tt_discard_bits must not be negative (got %)', p_tt_discard_bits;
    end if;
  end if;

  -- Orphaned-child guard (REDESIGN.md): regrain creates each fine child as a standalone table
  -- (CREATE TABLE ... LIKE) and only ATTACHes it at the swap. An interrupted regrain therefore
  -- leaves an un-attached child -- which DROP TABLE <parent> CASCADE does NOT remove (an
  -- un-attached table has no dependency on the parent). If the table is later recreated/reloaded
  -- and re-transmuted, the next regrain reuses the orphan by name and INSERTs rows whose keys
  -- already live in it: a cryptic mid-regrain "duplicate key" deep inside regrain_step.
  -- Refuse up front -- any standalone (un-attached) table in this schema whose name matches this
  -- parent's child-partition naming (<rel>_p<digits...>) is an orphan. starts_with handles the
  -- (un-escaped) rel prefix; the regex only constrains the data-independent suffix.
  declare v_orphan name;
  begin
    select c.relname into v_orphan
      from pg_class c
     where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)
       and c.relkind = 'r'
       and starts_with(c.relname, v_rel || '_p')
       and case when p_control_kind = 'id'
                then substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{19}$'
                else substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{4}(_[0-9]+)*$'
           end
       and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
     limit 1;
    if v_orphan is not null then
      raise exception 'pg_partition_magician: %.% already exists as a standalone table matching this parent''s partition naming -- most likely an orphan left by an interrupted regrain. Drop it (drop table %.%) and retry transmute.',
        v_nsp, v_orphan, quote_ident(v_nsp), quote_ident(v_orphan);
    end if;
  end;

  -- Staging-name collision guard (#344): phase 3 builds the new parent under a temporary name BEFORE
  -- either rename (so that none of its setup work adds to the outage), which means that name must be
  -- free. Refuse up front, same shape as the orphan-child check just above and the <index>_pgpm check
  -- below -- most likely a leftover from an interrupted prior attempt.
  if to_regclass(format('%I.%I', v_nsp, v_staging)) is not null then
    raise exception 'pg_partition_magician: %.% already exists, and transmute needs it as a staging name for the new parent. Most likely a leftover from an interrupted run. Drop it (drop table %.%) and retry transmute.',
      v_nsp, v_staging, quote_ident(v_nsp), quote_ident(v_staging);
  end if;

  -- uuidv7 sanity check (issue #96): a uuid control column is TREATED as uuidv7 on assumption, so we
  -- sample it. Genuine UUIDv7/ULID decodes to plausible recent timestamps (~1.0); random UUIDv4 scores
  -- ~0. Below a hard floor (0.5) the column is overwhelmingly random, so range-partitioning it would
  -- scatter rows across meaningless partitions on a garbage frontier -- so REFUSE, mirroring the
  -- float-key and PK refusals, unless the operator overrides with p_force_uuidv7. Between the floor and
  -- 0.95 we warn but proceed (mostly time-ordered with some noise, within the bounded-lag contract).
  if p_control_kind = 'uuidv7' then
    select sampled, fraction into v_uchk_n, v_uchk_frac from pgpm.check_uuidv7(p_parent, p_control, 1000);
    if coalesce(v_uchk_n, 0) > 0 then
      if v_uchk_frac < 0.5 and not p_force_uuidv7 then
        raise exception 'pg_partition_magician: only % of % sampled % values decode to plausible recent timestamps -- the column looks random (UUIDv4), not time-ordered (UUIDv7/ULID), so range-partitioning it would scatter rows across meaningless partitions on a garbage frontier. If you are certain it is time-ordered, re-run with p_force_uuidv7 => true; otherwise partition on a genuinely time-ordered key. Inspect with pgpm.check_uuidv7().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
      elsif v_uchk_frac < 0.95 then
        raise notice 'pg_partition_magician: only % of % sampled % values decode to plausible recent timestamps; the column may be random (UUIDv4) rather than time-ordered (UUIDv7/ULID) -- partitioning may misbehave. Proceeding; verify with pgpm.check_uuidv7().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
      end if;
    end if;

  end if;

  -- text_time sanity check, same shape and same floor/warn thresholds as the uuidv7 one above: the
  -- shape (prefix/width/radix/unit) is supplied by the operator, not detected, so this is what verifies
  -- real data actually matches it before anything is partitioned on it.
  if p_control_kind = 'text_time' then
    select sampled, fraction into v_uchk_n, v_uchk_frac
      from pgpm.check_text_time(p_parent, p_control, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, 1000,
                                 p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);
    if coalesce(v_uchk_n, 0) > 0 then
      if v_uchk_frac < 0.5 and not p_force_text_time then
        raise exception 'pg_partition_magician: only % of % sampled % values match the declared text_time shape (prefix %, % base-% digit(s)) and decode to plausible recent timestamps -- range-partitioning it would scatter rows across meaningless partitions on a garbage frontier. If you are certain of the shape, re-run with p_force_text_time => true; otherwise check p_tt_prefix/p_tt_width/p_tt_radix/p_tt_unit. Inspect with pgpm.check_text_time().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control), p_tt_prefix, p_tt_width, p_tt_radix;
      elsif v_uchk_frac < 0.95 then
        raise notice 'pg_partition_magician: only % of % sampled % values match the declared text_time shape and decode to plausible recent timestamps -- partitioning may misbehave. Proceeding; verify with pgpm.check_text_time().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
      end if;
    end if;
  end if;

  -- existing PK columns and identity columns
  select array_agg(a.attname::text order by k.ord) into v_oldpk
    from pg_constraint con
    cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
   where con.conrelid = p_parent and con.contype = 'p';
  select conname into v_pkname from pg_constraint where conrelid = p_parent and contype = 'p';
  -- #308: capture the identity KIND alongside the column, in the same order. GENERATED ALWAYS rejects an
  -- insert that supplies the column unless it says OVERRIDING SYSTEM VALUE; re-adding it BY DEFAULT would
  -- accept those writes silently, revoking a constraint the operator declared without saying so.
  select array_agg(a.attname order by a.attnum), array_agg(a.attidentity::text order by a.attnum)
    into v_idcols, v_idkinds
    from pg_attribute a where a.attrelid = p_parent and a.attidentity in ('a','d') and not a.attisdropped;

  -- Capture max(identity) to seed the parent's freshly-recreated identity sequence below: identity is
  -- moved from the default to the parent (whose sequence restarts at 1), so without this the next
  -- insert would collide. The PK is kept (never dropped), so the id index is intact and this is an
  -- index lookup, not a seq-scan, even on a large default.
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('select coalesce(max(%I), 0)::bigint from %s', v_col, p_parent::text) into v_m;
      v_idmax := array_append(v_idmax, v_m);
      -- also capture the column's current sequence position, so the reseed below never moves the sequence
      -- BACKWARD past ids it has already handed out (a gap above max from rollbacks, caching, or deleted
      -- high rows). Captured now, while the original sequence still exists (step 3 drops it on the monolith).
      v_seq := pg_get_serial_sequence(p_parent::text, v_col);
      v_n := null;
      if v_seq is not null then
        execute format('select case when is_called then last_value + 1 else last_value end from %s', v_seq) into v_n;
      end if;
      v_idnext := array_append(v_idnext, v_n);
    end loop;
  end if;

  -- pgpm NEVER rewrites the key (REDESIGN.md): it REUSES an existing CONSTRAINT-backed unique key whose
  -- columns include the control column, so the parent (step 8) adopts the monolith's kept index in place,
  -- no drop, no O(rows) rebuild. Postgres only requires a partitioned table's PK/unique key to INCLUDE
  -- the partition key (column order is irrelevant). Preference: the PRIMARY KEY when it includes the
  -- control column (ADD PRIMARY KEY adopts the child PK index), else a UNIQUE CONSTRAINT that includes it
  -- (ADD UNIQUE adopts the child unique-constraint index). A *bare* unique index is deliberately NOT
  -- usable -- ADD UNIQUE would REBUILD it rather than adopt it -- so it is refused with the one metadata-
  -- only promotion the operator runs first. The reused key makes the control column NOT NULL (a PK
  -- guarantees it; for a unique constraint we require it, checked not scanned), so the per-column SET NOT
  -- NULL below stays a metadata no-op. Several shapes are refused up front (before the rename, table left
  -- untouched) rather than partitioned on a weak key.
  select a.attnum into v_ctl_attnum
    from pg_attribute a where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;

  if v_oldpk is not null and (p_control::text = any(v_oldpk)) then
    v_pkcols := v_oldpk;   -- reuse the existing PK verbatim (it already includes the partition key)
    v_add_pk := true;
  else
    -- no usable PK: look for a UNIQUE CONSTRAINT whose key includes the control column and is neither
    -- partial nor on an expression (the same shape pgpm can enforce on a partitioned table).
    select con.conname, con.conindid, array_agg(a.attname::text order by k.ord)
      into v_reuse_conname, v_reuse_idx, v_uq_cols
      from pg_constraint con
      join pg_index i on i.indexrelid = con.conindid
      cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
     where con.conrelid = p_parent and con.contype = 'u'
       and i.indpred is null and i.indexprs is null and v_ctl_attnum = any(con.conkey)
     group by con.conname, con.conindid
     order by con.conname limit 1;

    if v_reuse_conname is not null then
      if not (select a.attnotnull from pg_attribute a
                where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) then
        raise exception 'pg_partition_magician: cannot transmute % on % -- the unique constraint % includes the control column, but % is nullable and a partition key must be NOT NULL. Run ALTER TABLE % ALTER COLUMN % SET NOT NULL first, then re-run transmute.',
          p_parent, p_control, v_reuse_conname, p_control, p_parent::text, p_control;
      end if;
      v_pkcols := v_uq_cols;   -- reuse the unique constraint (drives FK eligibility and the parent ADD UNIQUE)
      v_add_uniq := true;
    else
      -- nothing reusable: give the operator a specific reason and the prep step that unblocks it.
      select c.relname into v_bare_uq
        from pg_index i join pg_class c on c.oid = i.indexrelid
       where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary
         and i.indpred is null and i.indexprs is null
         and v_ctl_attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts])
         and not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid)
       limit 1;
      if v_bare_uq is not null then
        raise exception 'pg_partition_magician: cannot transmute % on % -- the unique index % includes the control column but is a bare index, not a constraint, so pgpm cannot adopt it without an O(rows) rebuild. Promote it to a constraint first: ALTER TABLE % ADD CONSTRAINT %_key UNIQUE USING INDEX %; then re-run transmute. (pgpm reuses a primary key or a unique constraint, never a bare index, to keep the conversion metadata-only.)',
          p_parent, p_control, v_bare_uq, p_parent::text, v_bare_uq, v_bare_uq;
      elsif v_oldpk is not null then
        raise exception 'pg_partition_magician: cannot partition % on % -- pgpm does not rewrite keys, and the primary key (%) does not include %, nor does any unique constraint. Make % part of the primary key or add a unique constraint that includes it, then re-run transmute: the simplest modern data model is a single-column time-ordered key (bigint/Snowflake, UUIDv7, or ULID); to retrofit an existing key, widen it via CREATE UNIQUE INDEX CONCURRENTLY on the new columns, then ALTER TABLE ... DROP CONSTRAINT <pk>, ADD PRIMARY KEY USING INDEX <idx>.',
          p_parent, p_control, array_to_string(v_oldpk, ', '), p_control, p_control;
      else
        -- truly keyless: no key to reuse. pgpm still partitions it -- the parent gets no primary key or
        -- unique constraint, faithful to a keyless source (e.g. a plain hypertable un-hypertabled by
        -- from_hypertable). The one requirement is that the control column be NOT NULL: a partition key
        -- cannot be null, and pgpm never scans to enforce it, so a nullable control column is refused.
        -- (regrain is unavailable for a keyless monolith -- it has no key to dedup a resumed copy -- but
        -- the coarse monolith is a correct, queryable permanent state; see regrain_step.)
        if not (select a.attnotnull from pg_attribute a
                  where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) then
          raise exception 'pg_partition_magician: cannot transmute % on % -- the table has no primary key or unique constraint to reuse, and % is nullable. A partition key must be NOT NULL: run ALTER TABLE % ALTER COLUMN % SET NOT NULL first, then re-run transmute. (A primary key or unique constraint including % would also satisfy this.)',
            p_parent, p_control, p_control, p_parent::text, p_control, p_control;
        end if;
        -- proceed keyless: v_pkcols stays null, v_add_pk and v_add_uniq stay false.
      end if;
    end if;
  end if;

  -- Secondary indexes to carry onto the parent (step 9b recreates them as partitioned, attaching the
  -- default's). NON-unique secondaries always carry. A non-PK UNIQUE secondary can only become a
  -- partitioned unique index if its KEY columns include the partition key (Postgres's rule), so we carry
  -- those too -- global uniqueness genuinely preserved, exactly as the PK is reused when it covers the
  -- partition key -- and REFUSE the rest below, never silently dropping a uniqueness guarantee (issue
  -- #90). indkey casts via its text form (int2vector is 0-based; string_to_array gives a 1-based array),
  -- sliced to indnkeyatts so INCLUDE columns don't count; partial / expression unique indexes can't be
  -- carried either, so they fall to the refusal.
  -- (v_ctl_attnum was resolved with the key selection above). Exclude the reused unique-constraint index
  -- (v_reuse_idx): step 8 produces it via ADD UNIQUE, so it must not also be carried as a secondary.
  select array_agg(c.relname::text), array_agg(pg_get_indexdef(i.indexrelid)) into v_idx_names, v_idx_defs
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and not i.indisprimary
     and i.indexrelid <> coalesce(v_reuse_idx, 0::oid)
     and (not i.indisunique
          or (i.indpred is null and i.indexprs is null
              and v_ctl_attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts])));
  -- Refuse any non-PK UNIQUE secondary that CANNOT be carried (its key omits the partition key, or it is
  -- partial / on an expression): global uniqueness cannot be enforced on the partitioned table, so this
  -- is the same refuse-with-guidance contract as the PK and incoming-FK cases, not a silent drop.
  select string_agg(c.relname, ', ' order by c.relname) into v_uniq_bad
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary
     and not (i.indpred is null and i.indexprs is null
              and v_ctl_attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts]));
  if v_uniq_bad is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the UNIQUE secondary index(es) (%) do not include the partition key % in their key columns (or are partial/expression indexes), so global uniqueness cannot be enforced on a partitioned table. Add % to the key of each, or drop them, then re-run transmute. A unique index that already includes % is carried automatically.',
      p_parent, v_uniq_bad, quote_ident(p_control), quote_ident(p_control), quote_ident(p_control);
  end if;

  -- Refuse a colliding <index>_pgpm name (#311). Step 9b recreates each carried secondary as a
  -- PARTITIONED index on the parent named <original>_pgpm, then attaches the monolith's original under
  -- it. Nothing checked that name was free, so a pre-existing relation by it -- a leftover from an
  -- interrupted run, or an operator's own index that happens to be named that way -- made the CREATE
  -- INDEX fail with a raw 42P07 from inside the cutover: no pgpm prefix, no guidance, and no hint that
  -- the fix is `drop index ..._pgpm`.
  --
  -- The cutover is one transaction, so that failure rolled back rather than losing anything; the cost
  -- was a confusing error and a conversion the operator then had to abort by hand. Every sibling shape
  -- here (a key that excludes the control column, a bare unique index, an un-carryable UNIQUE secondary,
  -- a transition-table trigger, an orphaned child table) refuses UP FRONT with the remedy. This was the
  -- one hole in that contract.
  --
  -- Names every collision at once: one per retry would make an operator with several re-run the
  -- conversion once per index to discover them.
  select string_agg(quote_ident(n || '_pgpm'), ', ' order by n) into v_pgpm_clash_q
    from unnest(coalesce(v_idx_names, '{}'::text[])) as n
   where to_regclass(format('%I.%I', v_nsp, n || '_pgpm')) is not null;
  if v_pgpm_clash_q is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the name(s) (%) are already taken, and transmute needs them for the partitioned copies of this table''s secondary indexes. Most likely leftovers from an interrupted run. Drop them, then re-run transmute.',
      p_parent, v_pgpm_clash_q;
  end if;

  -- Refuse the one trigger shape a partitioned table cannot host (#277). Measured on PG 17.10: this is
  -- the ONLY refusal needed. Constraint triggers, statement triggers, WHEN clauses, UPDATE OF, and even
  -- statement triggers WITH transition tables all transfer to a partitioned parent; only a FOR EACH ROW
  -- trigger with a transition table is rejected. Refusing beats converting and dropping it, which is the
  -- silent-loss failure this whole issue is about.
  select string_agg(tgname, ', ' order by tgname) into v_bad_trg
    from pg_trigger
   where tgrelid = p_parent and not tgisinternal
     and (tgoldtable is not null or tgnewtable is not null)
     and (tgtype & 1) = 1;   -- TRIGGER_TYPE_ROW
  if v_bad_trg is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the row trigger(s) (%) use a transition table (REFERENCING OLD/NEW TABLE), which PostgreSQL does not allow on a partitioned table. Rewrite them as statement triggers (those DO carry a transition table) or drop them, then re-run transmute. pgpm refuses rather than converting and leaving the trigger behind on one child.',
      p_parent, v_bad_trg;
  end if;

  -- 0. incoming FKs (capture before the rename; record after the new parent exists). pgpm never
  -- rewrites the PK, so the referenced unique key (the reused PK) always survives and an incoming FK
  -- can be re-pointed at the new parent verbatim on a later tick -- the 'preserve' lifecycle. It cannot
  -- ride through in place: the rename below makes the ORIGINAL table the monolith child, so a surviving FK
  -- would go on referencing that partition instead of the new parent, silently narrowing to one partition.
  -- We refuse by default (the operator opts into the drop-and-restore dance).
  if exists (select 1 from pg_constraint where confrelid = p_parent and contype = 'f') then
    if p_incoming_fks = 'error' then
      raise exception
        'pg_partition_magician: % has incoming foreign key(s) (%). Re-run with p_incoming_fks => ''preserve'' to keep them: pgpm drops each for the conversion and re-adds it against the new parent on a later maintenance tick (or call pgpm.restore_incoming_fks to do it now).',
        p_parent,
        (select string_agg(conname || ' on ' || conrelid::regclass::text, ', ')
           from pg_constraint where confrelid = p_parent and contype = 'f');
    else   -- 'preserve'
      for v_fk in
        select c.conrelid::regclass as reltbl, c.conname, pg_get_constraintdef(c.oid) as def,
               (select array_agg(a.attname::text order by k.ord) from unnest(c.confkey) with ordinality as k(attnum, ord)
                  join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as rcols
          from pg_constraint c where c.confrelid = p_parent and c.contype = 'f'
      loop
        -- Preservable iff the parent keeps a unique key on EXACTLY this FK's referenced columns.
        -- pgpm reuses the existing key verbatim (the PK, or a unique constraint when there is no usable
        -- PK), so the FK must reference that reused key -- both a PK and a unique constraint are valid FK
        -- targets. The only way it can't is an FK referencing a different unique key that cannot survive
        -- partitioning (one not including the partition key) -- refuse with guidance.
        v_fk_eligible := v_pkcols is not null
          and (select array_agg(x order by x) from unnest(v_fk.rcols) x)
            = (select array_agg(x order by x) from unnest(v_pkcols) x);
        if not v_fk_eligible then
          raise exception 'pg_partition_magician: cannot preserve incoming FK % on % -- it references (%), but the parent''s reused key is (%). An incoming FK must reference the reused primary key or unique constraint to be preserved.',
            v_fk.conname, v_fk.reltbl, array_to_string(v_fk.rcols, ', '), array_to_string(coalesce(v_pkcols, '{}'), ', ');
        end if;
        v_dropped := v_dropped || jsonb_build_object(
          'reltbl', v_fk.reltbl::text, 'conname', v_fk.conname::text, 'def', v_fk.def);
        execute format('alter table %s drop constraint %I', v_fk.reltbl::text, v_fk.conname);
      end loop;
    end if;
  end if;

  -- OUTGOING foreign keys (issue #263). The conversion renames the original table aside to become the
  -- monolith child, and a foreign key follows the table it is defined ON, so the constraint lands on the
  -- monolith and NOT on the new parent. It keeps enforcing there, which is what made the loss so easy to
  -- miss: rows routed into the monolith are still checked, and only rows in a FORWARD partition escape.
  -- Measured before this fix: an insert referencing a row that does not exist was accepted into
  -- ev263_p0000000000000030000 with no error and nothing in pgpm.log. Partial enforcement is worse than
  -- none, because the obvious post-conversion check ("is my foreign key still there?") passes.
  --
  -- Captured here, re-added at the parent after the attach below. Self-referential keys are excluded on
  -- purpose: confrelid = p_parent makes them INCOMING as well, so the incoming gate above has already
  -- decided their fate (refuse, or drop-and-restore under 'preserve').
  select array_agg(c.conname::text order by c.conname),
         array_agg(pg_get_constraintdef(c.oid) order by c.conname)
    into v_out_names, v_out_defs
    from pg_constraint c
   where c.conrelid = p_parent and c.contype = 'f' and c.confrelid <> p_parent and c.conparentid = 0
     and c.convalidated;

  -- A NOT VALID outgoing key is refused, because re-adding it at the parent could not then be
  -- metadata-only. Measured on PG 17.10: adopting a VALIDATED child constraint costs 0.8 ms against a
  -- 200k-row monolith, while the same ADD over a NOT VALID one SCANS (seq_tup_read +400,000) and takes
  -- 89 ms at 2M rows -- an O(rows) scan holding SHARE ROW EXCLUSIVE on the table AND on the referenced
  -- table, which is the data-coupled blocking lock this project's acceptance rule forbids. Validating it
  -- first is the operator's call, not ours: it would either fail on rows they never checked or silently
  -- promote a constraint they deliberately left unvalidated.
  select string_agg(conname, ', ') into v_bad_out
    from pg_constraint
   where conrelid = p_parent and contype = 'f' and confrelid <> p_parent and conparentid = 0
     and not convalidated;
  if v_bad_out is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- its outgoing foreign key(s) (%) are NOT VALID. pgpm re-adds an outgoing key on the new parent, which is metadata-only only when the key is already validated; over a NOT VALID one PostgreSQL would rescan the whole table under a lock that blocks writes on it and on the referenced table. Run ALTER TABLE % VALIDATE CONSTRAINT <name> first (or drop the constraint), then re-run transmute.',
      p_parent, v_bad_out, p_parent::text;
  end if;

  -- ===== monolith cutover (REDESIGN.md sections 1, 2, 11) =====
  -- Bounds for the bounded coarse child the original table becomes: lo = grid_floor(min(control)),
  -- hi = B = the grid boundary just above the frontier. The monolith covers all history AND the
  -- current interval, so live writes keep landing in it until the frontier crosses B (then obtain's
  -- forward partitions take over and the monolith freezes). Every row satisfies [lo, B): lo <= min and
  -- B > frontier >= every row. An empty table anchors lo at the frontier's grid floor (empty monolith).
  -- frontier (now() for time, max(control) for id, greatest(max(control), now()) for uuidv7 (#325))
  -- and min(control), computed directly:
  -- pgpm.config does not exist yet, so _frontier_native (which reads config) cannot be used here.
  if p_control_kind = 'time' then
    v_frontier_native := now()::text;
  else
    execute format('select t.%I::text from %s t order by t.%I desc limit 1', p_control, p_parent::text, p_control)
      into v_max_raw;
    if v_max_raw is null then
      v_frontier_native := case when p_control_kind = 'id' then p_anchor else now()::text end;
    elsif p_control_kind in ('uuidv7', 'text_time') then
      -- #325: mirrors _frontier_native's greatest(decoded, now()) here too. pgpm.config does not exist
      -- yet (see the note above), so this cannot just call the shared function -- and fixing only that
      -- one would leave THIS bound stuck at the data-driven value, opening a gap between the
      -- monolith's frozen upper edge and obtain's now()-anchored forward grid on the very next tick.
      -- Confirmed the hard way while building text_time support: adding the kind to _frontier_native
      -- but not here reproduces exactly that gap (an unfixed [2025-07,2025-10) monolith with the next
      -- partition not starting until 2026-08 -- ten covered months missing entirely).
      v_frontier_native := greatest(pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch)::timestamptz, now())::text;
    else
      v_frontier_native := pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);
    end if;
  end if;
  execute format('select t.%I::text from %s t order by t.%I asc limit 1', p_control, p_parent::text, p_control)
    into v_min_raw;
  v_min_native := coalesce(pgpm._decode(p_control_kind, v_min_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch),
                           pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_frontier_native));
  v_lo_native  := pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_min_native);
  v_hi_native  := pgpm._grid_next(p_control_kind, p_step,
                    pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_frontier_native));
  v_monolith   := pgpm._part_name(v_rel, p_control_kind, p_step, v_lo_native, v_hi_native);

  -- Refuse, before touching anything, when the monolith's own upper bound cannot be expressed (#299).
  -- B is the grid boundary ABOVE the frontier, so a frontier sitting in the last partial step puts B past
  -- the 48-bit UUIDv7 ceiling and no uuid can carry it. This is arithmetic, not a heuristic, which is why
  -- p_force_uuidv7 does NOT override it: that override exists to let an operator vouch for a column the
  -- SAMPLING misjudged, not to ask for a bound that cannot exist.
  --
  -- In practice it catches the same garbage column the sampling check does, from the other side: random
  -- uuids have their maximum near the top of the 128-bit space, so the frontier decodes to within a
  -- whisker of the ceiling and every step forward overflows. Before this, the overflow was silently
  -- truncated into a SMALLER uuid and surfaced much later as PostgreSQL's `empty range bound specified for
  -- partition`, naming neither the cause nor the ceiling -- and only on the runs where the random maximum
  -- happened to land close enough, which made it a CI flake rather than a reproducible bug.
  if p_control_kind in ('uuidv7', 'text_time') then
    begin
      perform pgpm._encode(p_control_kind, v_hi_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);
    exception when datetime_field_overflow or numeric_value_out_of_range then
      if p_control_kind = 'uuidv7' then
        raise exception 'pg_partition_magician: % cannot be partitioned on a uuidv7 grid using %: its newest value decodes to %, so the next grid boundary lands past 10889-08-02 05:31:50.65504+00, the newest instant a UUIDv7 timestamp can express. A column whose frontier sits at that ceiling is almost certainly random (UUIDv4) rather than time-ordered -- inspect it with pgpm.check_uuidv7(). p_force_uuidv7 does not override this, because no uuid can express the bound.',
          p_parent, quote_ident(p_control), v_frontier_native;
      else
        raise exception 'pg_partition_magician: % cannot be partitioned on a text_time grid using %: its newest value decodes to %, so the next grid boundary would need more than p_tt_width (%) base-% digit(s) to express. Either the column''s newest value is implausibly far in the future for this encoding, or p_tt_width/p_tt_radix do not match its actual shape -- inspect it before overriding anything.',
          p_parent, quote_ident(p_control), v_frontier_native, p_tt_width, p_tt_radix;
      end if;
    end;
  end if;

  -- ============================ PHASE 1: add the bound (#275) ============================
  --
  -- Certify the monolith's bound BEFORE the rename so the ATTACH below is metadata-only. This is the one
  -- O(rows) read of the conversion, and it gets its own transaction so it is not held under the ACCESS
  -- EXCLUSIVE lock the ADD takes. Measured before the split: the table was fully locked (ACCESS EXCLUSIVE
  -- conflicts with everything, reads included) for 30 ms at 1M rows, 173 ms at 5M, 492 ms at 10M, cached.
  --
  -- THE CLAIM (#405). pgpm.transmute_inflight's primary key on parent_table IS the exclusion: one row per
  -- table, taken here and deleted by the cutover, so a second conversion cannot register while a first holds
  -- it. Liveness -- "still running" against "its session died mid-way", with no heartbeat and no timeout
  -- guess -- comes from the claiming session's identity recorded alongside it (see pgpm._session_alive).
  --
  -- This REPLACES a session advisory lock keyed on hashtextextended('pgpm_transmute:' || oid). That key was
  -- computable by anyone -- the formula is in this file and the oid is in pg_class -- and advisory locks
  -- carry no ACL of any kind, so any role that could merely CONNECT could take it: either pre-emptively, to
  -- block every transmute of that table outright, or the instant a crashed conversion released it, which
  -- starved the reaper below and pinned a write-rejecting bound on the operator's table with no way back,
  -- since transmute_abort consulted the same lock. The claim row lives in a pgpm-owned table carrying no
  -- GRANTs, so an unprivileged role cannot take or hold it at all.
  --
  -- Optional headroom is applied to the candidate hi FIRST, because the claim itself decides fresh-vs-resume
  -- and a resume must reuse the recorded bound. It pushes hi further out so a fast writer cannot cross it
  -- while the scan runs: the bound rejects writes at or past hi for as long as it is in place, which with
  -- the phase split is the whole conversion rather than a single locked statement.
  for v_i in 1 .. greatest(coalesce(p_bound_headroom, 0), 0) loop
    v_hi_native := pgpm._grid_next(p_control_kind, p_step, v_hi_native);
  end loop;

  -- One atomic take-or-take-over. `do update` fires only when the recorded owner is gone, so the statement
  -- returns a row exactly when the claim is ours and nothing at all when a live conversion already holds it.
  -- It deliberately leaves lo/hi untouched, which is what makes RETURNING hand back the ORIGINAL bound on a
  -- take-over rather than the candidates passed in above.
  insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi,
                                       owner_pid, owner_backend_start)
  values (p_parent, v_nsp, v_rel, p_control_kind, v_lo_native, v_hi_native,
          pg_backend_pid(), (select backend_start from pg_stat_activity where pid = pg_backend_pid()))
      on conflict (parent_table) do update
         set owner_pid           = excluded.owner_pid,
             owner_backend_start = excluded.owner_backend_start
       where not pgpm._session_alive(transmute_inflight.owner_pid, transmute_inflight.owner_backend_start)
  returning lo, hi, (xmax <> 0) into v_lo_native, v_hi_native, v_resumed;

  if not found then
    raise exception 'pg_partition_magician: a transmute of % is already in progress in another session', p_parent;
  end if;

  -- Resume: the row was already there and its session is gone, so we took it over. Reuse its bound rather
  -- than recomputing one -- the frontier has moved on since, but no row can have landed outside the recorded
  -- range, because the CHECK was rejecting exactly those the whole time. xmax is 0 on an insert and the
  -- updating xid on an update, which is what distinguishes the two here.
  v_monolith := pgpm._part_name(v_rel, p_control_kind, p_step, v_lo_native, v_hi_native);

  -- #309: bound the wait for the ADD's ACCESS EXCLUSIVE. Re-applied per phase rather than set once,
  -- because `set local` does not survive a COMMIT -- the same caution maintain() records at its own
  -- boundaries. Without it this statement waits indefinitely, and a PENDING AccessExclusive request
  -- blocks every lock request queued behind it, so one long-running query turns the wait into an outage
  -- of the whole table. Failing here costs nothing: nothing is committed yet.
  perform set_config('lock_timeout', p_lock_timeout, true);
  if not exists (select 1 from pg_constraint
                  where conrelid = p_parent and conname = 'pgpm_monolith_bound') then
    execute format('alter table %s add constraint pgpm_monolith_bound check (%I >= %L and %I < %L) not valid',
                   p_parent::text, p_control, pgpm._encode(p_control_kind, v_lo_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch),
                   p_control, pgpm._encode(p_control_kind, v_hi_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch));
  end if;
  commit;   -- releases the ADD's ACCESS EXCLUSIVE before the scan; the claim row survives (it is committed)

  -- ============================ PHASE 2: validate it (#275) ============================
  -- VALIDATE takes only SHARE UPDATE EXCLUSIVE, which blocks nobody. Skipped when a previous attempt
  -- already validated it. It still needs the timeout: SHARE UPDATE EXCLUSIVE conflicts with itself, so
  -- an autovacuum or a concurrent ALTER on the same table can queue this behind them.
  perform set_config('lock_timeout', p_lock_timeout, true);   -- `set local` did not survive the COMMIT
  if not (select convalidated from pg_constraint
           where conrelid = p_parent and conname = 'pgpm_monolith_bound') then
    execute format('alter table %s validate constraint pgpm_monolith_bound', p_parent::text);
  end if;
  commit;

  -- ============================ PHASE 3: the cutover ============================
  -- Metadata only, and atomic: a raise from here rolls the whole cutover back.
  --
  -- One set_config covers every wait in this phase, since it is one transaction: the RENAME's ACCESS
  -- EXCLUSIVE on the live table, and the outgoing-FK re-add's SHARE ROW EXCLUSIVE on each REFERENCED
  -- table (#263), which queues behind writers there rather than on the table being converted. A timeout
  -- here aborts the cutover whole and leaves the phase-1 bound in place -- the recorded, resumable state
  -- transmute_abort and maintain_all's sweep already handle.
  perform set_config('lock_timeout', p_lock_timeout, true);   -- `set local` did not survive the COMMIT

  -- 0b. capture what CREATE TABLE ... LIKE will NOT carry (#277): owner, grants, RLS, policies, comments
  -- and triggers. Captured HERE, before either rename, and replayed below in this same transaction. Both
  -- halves have to be inside the cutover: a parent that is briefly reachable with RLS off is the same
  -- security defect as one that never gets its policies, with a shorter fuse.
  --
  -- Trigger definitions get a free ride, but only once BOTH renames have happened (#344): pg_get_triggerdef
  -- emits "... ON public.<original name>", and that name only resolves to the new parent once the staging
  -- parent has taken it, so the captured text replays verbatim with no rewriting. Policies get no such
  -- help (there is no pg_get_policydef) and are rebuilt from pg_policy.
  select pg_get_userbyid(relowner), relacl, relrowsecurity, relforcerowsecurity
    into v_owner, v_acl, v_rls, v_rls_force
    from pg_class where oid = p_parent;
  v_comment := obj_description(p_parent, 'pg_class');
  select coalesce(array_agg(pg_get_triggerdef(oid) order by tgname), '{}')
    into v_trgdefs from pg_trigger where tgrelid = p_parent and not tgisinternal;

  -- #344: everything below that only touches the NEW parent -- not the original/monolith relation -- runs
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

  -- 1. THE TWO RENAMES, BACK-TO-BACK (#344). The first is the ACCESS EXCLUSIVE-acquiring statement that
  -- starts the outage; doing the second immediately after -- before anything else runs -- means the live
  -- name already resolves to the correctly-positioned parent by the time the trigger replay below (the one
  -- step that needs the literal name, not just the OID) executes.
  execute format('alter table %s rename to %I', p_parent::text, v_monolith);
  v_monreg := format('%I.%I', v_nsp, v_monolith)::regclass;
  execute format('alter table %s rename to %I', v_parent::text, v_rel);

  -- 2. the existing PK is KEPT in place; step 8 reconciles the monolith's promoted index (metadata-only).

  -- 3. drop identity on the monolith; key columns NOT NULL (metadata no-ops: PK => NOT NULL)
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('alter table %s alter column %I drop identity if exists', v_monreg::text, v_col);
    end loop;
  end if;
  execute format('alter table %s alter column %I set not null', v_monreg::text, p_control);
  -- only a reused PRIMARY KEY makes its other columns NOT NULL; a reused UNIQUE constraint legitimately
  -- permits nullable non-control columns, so leave those as they are (and never scan them).
  if v_add_pk and v_pkcols is not null then
    foreach v_col in array v_pkcols loop
      execute format('alter table %s alter column %I set not null', v_monreg::text, v_col);
    end loop;
  end if;

  -- 7. attach the original as the bounded MONOLITH child (metadata-only via the validated CHECK), then
  -- drop the now-redundant CHECK (the partition bound enforces it).
  execute format('alter table %s attach partition %s for values from (%L) to (%L)',
                 v_parent::text, v_monreg::text,
                 pgpm._encode(p_control_kind, v_lo_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch), pgpm._encode(p_control_kind, v_hi_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch));
  execute format('alter table %s drop constraint pgpm_monolith_bound', v_monreg::text);

  -- 7a. re-add the outgoing foreign keys at the PARENT (#263), so they cover every partition instead of
  -- only the monolith. This is metadata-only: PostgreSQL ADOPTS a partition's equivalent already-validated
  -- key rather than rescanning, and the monolith's copy is the original, validated constraint. Measured on
  -- PG 17.10: 0.8 ms against a 200k-row monolith, and the resulting parent constraint is convalidated with
  -- the monolith's demoted to a child (conparentid <> 0). Empty forward partitions cost nothing either.
  -- Same transaction as the attach, so no session ever observes the parent without its keys.
  if v_out_names is not null then
    for v_i2 in 1 .. array_length(v_out_names, 1) loop
      execute format('alter table %s add constraint %I %s',
                     v_parent::text, v_out_names[v_i2], v_out_defs[v_i2]);
    end loop;
  end if;

  -- 7b (triggers). Last of the replay from 0b, and only now that both renames are done: the captured text
  -- names the ORIGINAL table, which only resolves to the parent once the live name is in place. The
  -- monolith's own originals are dropped FIRST -- creating on the parent clones the trigger onto every
  -- partition including the monolith, so leaving the original in place would give the monolith two and
  -- fire it twice for every row routed there. Order is the whole correctness argument.
  if array_length(v_trgdefs, 1) > 0 then
    for v_trg in select tgname from pg_trigger where tgrelid = v_monreg and not tgisinternal loop
      execute format('drop trigger %I on %s', v_trg.tgname, v_monreg::text);
    end loop;
    foreach v_grant in array v_trgdefs loop
      execute v_grant;   -- names the ORIGINAL table, which is now the parent: replays verbatim
    end loop;
  end if;

  -- 8. parent key -- adopts the monolith's kept constraint index (metadata-only, no rebuild): a PRIMARY
  -- KEY when the reused key was the PK, a UNIQUE constraint when it was a unique constraint.
  if v_add_pk then
    execute format('alter table %s add primary key (%s)', v_parent::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
  elsif v_add_uniq then
    execute format('alter table %s add unique (%s)', v_parent::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
  end if;

  -- 8b. advance each identity sequence to the greater of max(id)+1 (no collision with existing rows) and the
  -- original sequence's own next value (no re-issue of ids it already handed out past max). Both captured up
  -- front; the max is an index lookup.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('select setval(pg_get_serial_sequence(%L, %L), %s, false)',
                     v_parent::text, v_idcols[v_i], greatest(v_idmax[v_i] + 1, coalesce(v_idnext[v_i], 0)));
    end loop;
  end if;

  -- 9b. recreate secondary indexes as partitioned indexes, attaching the monolith's
  if v_idx_names is not null then
    for j in 1 .. array_length(v_idx_names, 1) loop
      v_old  := v_idx_names[j]::name;
      v_new  := (v_old || '_pgpm')::name;
      v_pdef_q := regexp_replace(v_idx_defs[j], '^CREATE (UNIQUE )?INDEX \S+ ON ',
                                 'CREATE \1INDEX ' || quote_ident(v_new) || ' ON ONLY ');
      execute v_pdef_q;
      execute format('alter index %I.%I attach partition %I.%I', v_nsp, v_new, v_nsp, v_old);
    end loop;
  end if;

  -- 9c. NO default partition (#288). It used to sit here as the leading-edge safety net, and the drain
  -- existed to evacuate it. Instead the forward grid is built below, after registration, so a write past
  -- the monolith lands in a real bounded partition. A write past the GRID now fails outright, which is
  -- the accepted cost: obtain x partition_step is both the slack and a hard write-ahead ceiling.

  -- 10. register
  insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor,
                           obtain, retain, regrain_batch, paused,
                           text_time_prefix, text_time_width, text_time_radix, text_time_unit,
                           text_time_alphabet, text_time_discard_bits, text_time_epoch)
  values (v_parent, p_control, p_control_kind, p_step, p_anchor, p_obtain, p_retain,
          p_regrain_batch, p_paused,
          p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch)
  on conflict (parent_table) do update set
    control_column = excluded.control_column, control_kind = excluded.control_kind,
    partition_step = excluded.partition_step, partition_anchor = excluded.partition_anchor,
    obtain = excluded.obtain, retain = excluded.retain,
    regrain_batch = excluded.regrain_batch, paused = excluded.paused,
    text_time_prefix = excluded.text_time_prefix, text_time_width = excluded.text_time_width,
    text_time_radix = excluded.text_time_radix, text_time_unit = excluded.text_time_unit,
    text_time_alphabet = excluded.text_time_alphabet, text_time_discard_bits = excluded.text_time_discard_bits,
    text_time_epoch = excluded.text_time_epoch;

  insert into pgpm.log (parent_table, action) values (v_parent, 'transmute');
  -- keyed on v_parent, not p_parent: after the rename p_parent's oid is the monolith's, so an operator
  -- looking the table up by name would never see it (#275).
  if v_resumed then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (v_parent, 'transmute_resume', v_lo_native, v_hi_native, 'reused the recorded bound');
  end if;

  -- record the original table, now the bounded MONOLITH coarse child, as an attached partition
  -- (REDESIGN.md section 7) so obtain's overlap check and status() see it.
  -- child_oid (#421). p_parent, not a fresh lookup of v_monolith: a regclass argument resolved to an
  -- OID at call time, and the rename above moved that OID to the monolith name (the same fact the
  -- note on v_parent records) -- so this is the original relation's identity carried through the
  -- conversion, not a re-resolution of the name it now answers to.
  insert into pgpm.part (parent_table, child_name, lo, hi, attached, child_oid)
    values (v_parent, v_monolith, v_lo_native, v_hi_native, true, p_parent::oid);

  -- record any dropped incoming FKs (the recorded definition already names the new parent); these are
  -- always preserve-managed now, re-added against the new parent by restore_incoming_fks on a later tick.
  for v_e in select value from jsonb_array_elements(v_dropped) loop
    insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
    values (v_parent, (v_e->>'reltbl')::regclass, v_e->>'conname', v_e->>'def');
    insert into pgpm.log (parent_table, action, method) values (v_parent, 'drop_incoming_fk', v_e->>'conname');
  end loop;

  -- Build the forward grid (#288). With no DEFAULT, a write past the monolith has nowhere to go until
  -- these exist, so they are created here rather than waiting for the first maintenance tick. obtain needs
  -- no special casing: the frontier sits inside the monolith, so its k=0 candidate overlaps and is skipped,
  -- and k=1 onward lays down [B, B + obtain x step) flush against the monolith's upper bound.
  perform pgpm.obtain(v_parent);

  -- the conversion is complete: deleting the claim row IS releasing the claim, and nothing is left for the
  -- reaper to undo.
  delete from pgpm.transmute_inflight where parent_table = p_parent;
end;
$$;

-- One transmute, two type-safe overloads on the width parameter (REDESIGN.md). The integer-grid and
-- time-grid families used to be three functions (transmute / transmute_by_id / transmute_by_uuidv7); they collapse
-- into a single `transmute` whose overload is chosen by the width type, with the kind read from the
-- control column. The old by_ names are removed (hard replace).
drop function if exists pgpm.transmute_by_id(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text);
drop function if exists pgpm.transmute_by_uuidv7(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text);
-- removed in the redesign (no PK rewrite -> no online PK build, no composite-FK recovery)
drop procedure if exists pgpm.build_pk_concurrently(regclass, name, interval, interval);
drop function if exists pgpm.generate_fk_recovery(regclass);

-- #309 added p_lock_timeout, which CHANGES THE ARGUMENT COUNT. CREATE OR REPLACE does not replace across
-- a different arg count, even when the new parameter has a default: re-running install.sql over a prior
-- install would leave BOTH arities defined, and every existing call site would then be ambiguous
-- (`function pgpm.transmute(...) is not unique`). That is #209/#210 exactly. Drop the old arities first.
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, int, boolean, text, boolean, int);
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, int, timestamptz, boolean, text, boolean, int);
drop procedure if exists pgpm.transmute(regclass, name, bigint, int, bigint, int, bigint, boolean, text, int);

-- text_time (issue #325 follow-up) added 4 trailing params to _transmute and to the interval-width
-- transmute overload, same #209/#210 arg-count hazard as #309's p_lock_timeout above. The bigint (id)
-- overload is untouched -- text_time has nothing to do with it -- so no drop needed for it.
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, int, boolean, text, boolean, int, text);
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, int, timestamptz, boolean, text, boolean, int, text);

-- The ULID/KSUID follow-up added 3 more trailing params (alphabet/discard_bits/epoch) to both. Same
-- #209/#210 arg-count hazard again.
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, int, boolean, text, boolean, int, text, text, int, int, text, boolean);
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, int, timestamptz, boolean, text, boolean, int, text, text, int, int, text, boolean);

-- Time grid: interval width. The control column's type selects the kind -- a uuid column is TREATED as
-- uuidv7 (ULIDs stored as uuid included; PostgreSQL has no UUIDv7 type to detect, so this is an
-- assumption check_uuidv7 samples to gate, not a verification: a column that samples as overwhelmingly
-- random (UUIDv4) is refused unless p_force_uuidv7 => true), a text/varchar column is TREATED as
-- text_time (a general opaque-sortable-TEXT id, e.g. classic cuid -- _transmute is what actually
-- requires p_tt_prefix/p_tt_width/p_tt_radix/p_tt_unit to all be set for it), anything else is time
-- (timestamptz/timestamp/date; _transmute rejects anything that fits none of these). A bare interval
-- literal is ambiguous against the bigint overload, so callers cast: transmute(t, c, interval '1 month').
create or replace procedure pgpm.transmute(
  p_parent regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_regrain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_force_uuidv7 boolean default false,
  p_bound_headroom int default 0,
  p_lock_timeout text default '5s',
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_force_text_time boolean default false,
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00'
) language plpgsql as $$
declare v_kind text;
begin
  -- resolved into a variable first: a CALL argument may not contain a subquery
  select case when t.typname = 'uuid' then 'uuidv7'
              when t.typname in ('text', 'varchar') then 'text_time'
              else 'time' end into v_kind
    from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;
  call pgpm._transmute(p_parent, p_control, coalesce(v_kind, 'time'),
    p_interval::text, p_anchor::text, p_obtain,
    p_retain::text, p_regrain_batch, p_paused, p_incoming_fks, p_force_uuidv7,
    p_bound_headroom, p_lock_timeout,
    p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_force_text_time,
    p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);
end;
$$;

-- Integer grid: bigint width. Covers int/bigint/numeric keys, including Snowflake-style ids.
create or replace procedure pgpm.transmute(
  p_parent regclass, p_control name, p_step bigint,
  p_obtain int default 30, p_retain bigint default null,
  p_regrain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_bound_headroom int default 0,
  p_lock_timeout text default '5s'
) language plpgsql as $$
begin
  -- plpgsql, not sql: a SQL-bodied routine cannot host a callee's transaction control
  call pgpm._transmute(p_parent, p_control, 'id', p_step::text, p_anchor::text, p_obtain,
                     p_retain::text, p_regrain_batch, p_paused, p_incoming_fks,
                     false, p_bound_headroom, p_lock_timeout);
end;
$$;

-- Abandon a half-finished conversion (issue #275). transmute runs in three transactions, so a failure
-- between them leaves a validated-or-not `pgpm_monolith_bound` CHECK on the operator's table, and that
-- CHECK REJECTS every write outside [lo, hi) for as long as it is there. This puts the table back exactly
-- as it was.
--
-- It ABANDONS, it does not resume: finishing someone's half-done conversion of a production table
-- unattended is too large an action to take on their behalf. Re-run transmute to try again; it will resume
-- from the recorded bound.
create or replace function pgpm.transmute_abort(p_parent regclass)
returns boolean language plpgsql as $$
declare r pgpm.transmute_inflight%rowtype;
begin
  select * into r from pgpm.transmute_inflight where parent_table = p_parent;
  if not found then return false; end if;
  -- #405: the claim's recorded session decides this, not an advisory lock anyone could have taken. When that
  -- lock gated the abort, a squatter holding it left the operator with no way to clear a bound at all --
  -- this path and the reaper both refused, for the same wrong reason.
  if pgpm._session_alive(r.owner_pid, r.owner_backend_start) then
    raise exception 'pg_partition_magician: cannot abort the transmute of % -- it is still running in another session', p_parent;
  end if;
  execute format('alter table %I.%I drop constraint if exists pgpm_monolith_bound', r.nsp, r.rel);
  delete from pgpm.transmute_inflight where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (p_parent, 'transmute_abort', r.lo, r.hi, 'bound dropped, table restored');
  return true;
end;
$$;

-- The reaper (issue #275). A conversion whose session died leaves the bound behind, and the table goes on
-- rejecting out-of-range writes until someone notices. Rather than leave that to the operator, every
-- maintain_all tick sweeps for abandoned conversions and undoes them.
--
-- "Abandoned" is decided by the claiming session's recorded identity, not by a timeout: if that session is
-- gone, the conversion is gone, whatever the reason. A long validation scan is therefore never mistaken for
-- a dead one, and an operator whose session is still open keeps the right to retry -- the sweep waits until
-- they disconnect. Before #405 this asked whether a session advisory lock could be taken, which any role
-- that could connect was free to hold: squatting the key the moment a crashed conversion released it made
-- this sweep read "still running" forever, so the bound it exists to undo never got undone.
--
-- Deliberately independent of pgpm.config: a half-converted table is not registered yet, because
-- registration happens in the cutover. That is exactly why this lives in maintain_all rather than maintain.
create or replace function pgpm._transmute_reap()
returns int language plpgsql as $$
declare r pgpm.transmute_inflight%rowtype; v_n int := 0;
begin
  for r in select * from pgpm.transmute_inflight loop
    -- the relation itself is gone: nothing to undo, just forget it
    if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = r.nsp and c.relname = r.rel) then
      delete from pgpm.transmute_inflight where parent_table = r.parent_table;
      v_n := v_n + 1;
      continue;
    end if;
    if pgpm._session_alive(r.owner_pid, r.owner_backend_start) then
      continue;   -- still running; leave it alone
    end if;
    execute format('alter table %I.%I drop constraint if exists pgpm_monolith_bound', r.nsp, r.rel);
    delete from pgpm.transmute_inflight where parent_table = r.parent_table;
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (r.parent_table, 'transmute_reap', r.lo, r.hi,
              'abandoned conversion undone: the bound was rejecting out-of-range writes');
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- _detach_reap(): finish any concurrent detach whose session died part-way (issue #268).
--
-- Retiring a referenced partition dispatches `DETACH PARTITION ... CONCURRENTLY` to pg_cron, so the
-- detach genuinely runs in another session, and that session can die. Measured: a backend killed
-- during the detach's SCAN phase rolls back cleanly and leaves nothing behind, but one killed during
-- its WAIT phase -- reachable whenever any concurrent transaction still holds a snapshot on the parent
-- -- leaves the partition flagged `pg_inherits.inhdetachpending` AND its rows already invisible
-- through the parent (a 2,000,000-row parent read 1,000,000). The partition is then neither detached
-- nor dropped, and rows have silently vanished from the user's table: strictly worse than the wedge
-- this all exists to fix. `DETACH ... FINALIZE` completes it and clears the flag.
--
-- So this runs BEFORE the per-parent loop in maintain_all, like _transmute_reap: it is the most urgent
-- thing in a tick. It FINALIZES unconditionally, because a pending detach is never a state to leave
-- sitting, but it DROPS nothing -- retire() completes its own retirements on the normal path (it can
-- tell, from pgpm.part.retiring_at, which detach was its own), and an operator's hand-run detach that
-- was interrupted is finished and then left alone.
create or replace function pgpm._detach_reap()
returns int language plpgsql as $$
declare r record; v_n int := 0;
begin
  for r in
    select pn.nspname as pnsp, pc.relname as prel,
           cn.nspname as cnsp, cc.relname as crel,
           i.inhparent::regclass as parent
      from pg_inherits i
      join pg_class cc on cc.oid = i.inhrelid
      join pg_namespace cn on cn.oid = cc.relnamespace
      join pg_class pc on pc.oid = i.inhparent
      join pg_namespace pn on pn.oid = pc.relnamespace
     where i.inhdetachpending
       and i.inhparent in (select parent_table from pgpm.config)
  loop
    begin
      execute format('alter table %I.%I detach partition %I.%I finalize',
                     r.pnsp, r.prel, r.cnsp, r.crel);
      insert into pgpm.log (parent_table, action, lo, hi, method)
        select r.parent, 'detach_reap', p.lo, p.hi,
               'an abandoned concurrent detach was finalized; its rows were already invisible through the parent'
          from pgpm.part p
         where p.parent_table = r.parent and p.child_name = r.crel;
      v_n := v_n + 1;
    exception when others then
      insert into pgpm.log (parent_table, action, method)
        values (r.parent, 'fail_detach_reap', left(sqlerrm, 200));
    end;
  end loop;
  return v_n;
end;
$$;

-- Reverse a transmute, exactly while it is still reversible. transmute's cutover moves no data: the
-- original table is attached intact as the monolith, merely renamed. As long as every row still lives
-- inside the monolith's [lo, hi), untransmute exploits that: detach the monolith (it is a complete
-- standalone table again the instant it detaches, because transmute never drops its PK), drop the
-- parent and its empty forward partitions, rename the monolith back, and undo the few things transmute
-- changed on it (identity moved to the parent, triggers, preserved incoming FKs). It is a one-way door
-- the moment any row lives outside the monolith: once the frontier crosses its upper bound, live writes
-- route into forward partitions, and a regrain splits the monolith itself -- untransmute then refuses.
-- Returns the restored table.
--
-- Fidelity notes: an identity column comes back in the form it had, ALWAYS or BY DEFAULT (#308), and the
-- control column is left NOT NULL (transmute set it; a nullable partition key is a foot-gun, and we do
-- not record prior nullability). Everything else -- rows, PK, secondary indexes, their names -- is
-- byte-for-byte.
create or replace function pgpm.untransmute(p_parent regclass)
returns regclass language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_monreg regclass; v_restored regclass;
  v_mon name; v_mon_lo text; v_mon_hi text; v_ncast text; v_outside boolean;
  v_idcols name[]; v_idmax bigint[]; v_col name; v_m bigint; v_i int; v_idnext bigint[]; v_seq text; v_n bigint;
  v_idkinds text[];   -- #308: 'a' (ALWAYS) or 'd' (BY DEFAULT) per v_idcols entry, same order
  r pgpm.dropped_fk%rowtype; v_cdelta name; v_cfn name;
  v_trgdefs text[] := '{}'; v_tdef text;   -- #277
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then
    raise exception 'pg_partition_magician: % is not managed by pgpm (nothing to untransmute)', p_parent;
  end if;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);
  -- resolve the regrain change-capture names (#267) NOW, while the parent still exists: they are derived
  -- from it, and the drop below would leave the lookup with nothing to read.
  select delta, fn into v_cdelta, v_cfn from pgpm._regrain_capture_names(p_parent);

  -- THE GATE (REDESIGN.md section 13): a clean (metadata-only) reverse needs the original table still
  -- intact as the MONOLITH, holding the whole table, with nothing landed outside it. The monolith is the
  -- attached partition with the smallest lo (it starts at grid_floor(min(control)), strictly below B,
  -- while every forward partition starts at B or higher). The reverse is a one-way door once any row
  -- lives outside the monolith's [lo, hi): a forward partition after the frontier crosses B, a backdated
  -- stray in the DEFAULT, or finer children from a regraining (Tier 2 foldback / Tier 3 merge not built).
  execute format('select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and attached order by lo::%s asc limit 1',
                 p_parent::text, v_ncast) into v_mon, v_mon_lo, v_mon_hi;
  if v_mon is null then
    raise exception 'pg_partition_magician: cannot untransmute % -- no managed partition found', p_parent;
  end if;
  v_monreg := format('%I.%I', v_nsp, v_mon)::regclass;
  execute format('select exists (select 1 from %s where %I >= %L or %I < %L)',
                 p_parent::text, cfg.control_column, pgpm._encode(cfg.control_kind, v_mon_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch),
                 cfg.control_column, pgpm._encode(cfg.control_kind, v_mon_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch)) into v_outside;
  if v_outside then
    raise exception 'pg_partition_magician: cannot untransmute % -- rows now live outside the original monolith (a forward partition past B, a backdated stray, or a regraining has split it), so a metadata-only reverse would lose data. This is a one-way door once the frontier crosses B or regraining begins.',
      p_parent;
  end if;

  -- capture the identity columns and their current max BEFORE dropping anything (transmute moved
  -- identity from the table to the parent; dropping the parent loses it, so we re-establish it on the
  -- restored monolith). The max is an index lookup (the PK is intact), not a seq-scan.
  select array_agg(a.attname order by a.attnum), array_agg(a.attidentity::text order by a.attnum)
    into v_idcols, v_idkinds
    from pg_attribute a where a.attrelid = p_parent and a.attidentity in ('a', 'd') and not a.attisdropped;
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('select coalesce(max(%I), 0)::bigint from %s', v_col, p_parent::text) into v_m;
      v_idmax := array_append(v_idmax, v_m);
      -- capture the parent sequence's position too (it holds whatever transmute preserved), so the reversal
      -- does not reopen a gap above max that transmute had carried forward.
      v_seq := pg_get_serial_sequence(p_parent::text, v_col);
      v_n := null;
      if v_seq is not null then
        execute format('select case when is_called then last_value + 1 else last_value end from %s', v_seq) into v_n;
      end if;
      v_idnext := array_append(v_idnext, v_n);
    end loop;
  end if;

  -- preserved incoming FKs: drop any currently LIVE on the parent so the parent can be dropped (an
  -- incoming FK is a constraint on the referencing table pointing AT the parent). All recorded FKs are
  -- re-added against the restored table at the end.
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
  end loop;

  -- Capture the parent's triggers before it is dropped (#277). transmute dropped the monolith's own
  -- originals in favour of the parent's, which clone down to every partition, and DETACH strips those
  -- clones -- so without this the reversal silently returns a table with no triggers at all. As in
  -- transmute, pg_get_triggerdef names the PARENT, and the restored table takes that name back below, so
  -- the definitions replay verbatim.
  select coalesce(array_agg(pg_get_triggerdef(oid) order by tgname), '{}')
    into v_trgdefs from pg_trigger where tgrelid = p_parent and not tgisinternal;

  -- detach the MONOLITH (the original table, holding everything; PK + secondary indexes intact), then
  -- drop the childless parent -- which cascades the empty DEFAULT and any empty forward partitions, and
  -- takes the parent PK, the partitioned _pgpm indexes, and the parent's identity sequence with it.
  -- DETACH FIRST: dropping a partitioned parent cascades to its partitions, which would destroy the data.
  execute format('alter table %s detach partition %s', p_parent::text, v_monreg::text);
  execute format('drop table %s', p_parent::text);

  -- re-establish identity on the restored monolith and reseed to the greater of max+1 and the parent
  -- sequence's preserved position (mirrors transmute's step 6/8b, applied back to the table); without the
  -- reseed the next insert would collide at 1.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('alter table %s alter column %I add generated %s as identity',
                     v_monreg::text, v_idcols[v_i],
                     case when v_idkinds[v_i] = 'a' then 'always' else 'by default' end);
      execute format('select setval(pg_get_serial_sequence(%L, %L), %s, false)',
                     v_monreg::text, v_idcols[v_i], greatest(v_idmax[v_i] + 1, coalesce(v_idnext[v_i], 0)));
    end loop;
  end if;

  -- rename the monolith back to the original table name. (transmute never renamed the kept PK or
  -- secondary indexes, so those names are already the originals.)
  execute format('alter table %s rename to %I', v_monreg::text, v_rel);
  v_restored := format('%I.%I', v_nsp, v_rel)::regclass;

  -- Replay the captured triggers onto the restored table, now that it carries the original name again.
  foreach v_tdef in array v_trgdefs loop
    execute v_tdef;
  end loop;

  -- re-add every preserved incoming FK against the restored table. The recorded definition names the
  -- parent, whose name the restored table now carries again. Mirror restore_incoming_fks: a
  -- partitioned referencer validates in one step (no NOT VALID), anything else NOT VALID + VALIDATE.
  for r in select * from pgpm.dropped_fk where parent_table = p_parent order by id loop
    if (select relkind from pg_class where oid = r.referencing_table) = 'p' then
      execute format('alter table %s add constraint %I %s',
                     r.referencing_table::text, r.constraint_name, r.definition);
    else
      execute format('alter table %s add constraint %I %s not valid',
                     r.referencing_table::text, r.constraint_name, r.definition);
      execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
    end if;
  end loop;

  -- the per-parent regrain change-capture apparatus (#267) is a side relation, not a partition, so the
  -- parent's DROP above does not take it. Drop it here or untransmute leaves it orphaned. Names were
  -- resolved up front, before the parent went away.
  execute format('drop table if exists %I.%I', v_nsp, v_cdelta);
  execute format('drop function if exists %I.%I()', v_nsp, v_cfn);

  -- forget all pgpm state for this table (matched by the dropped parent's oid, which p_parent still
  -- carries), and log the reversal against the restored table.
  delete from pgpm.dropped_fk where parent_table = p_parent;
  delete from pgpm.part where parent_table = p_parent;
  delete from pgpm.config where parent_table = p_parent;
  insert into pgpm.log (parent_table, action) values (v_restored, 'untransmute');

  return v_restored;
end;
$$;

-- ============================== maintenance / observability ==============================

-- Adaptive feathering was removed with the drain it paced (#288); its measurement and reporting surface
-- followed (#304). The AIMD controller, the WAL/checkpoint/ambient sensors and feathering_validation all
-- analysed a `drain_budget` log signal that nothing emits any more, so they could only ever report
-- nothing. Nothing left in pgpm is paced by row volume: regrain has a fixed batch and obtain is pure
-- metadata.
drop function if exists pgpm._wal_sustainable_bps();
drop function if exists pgpm._feather_congested(numeric, numeric, numeric, boolean);
drop function if exists pgpm._ambient_lock_waiters();
drop function if exists pgpm._ambient_io_latency(numeric, bigint, numeric, bigint);
drop function if exists pgpm._ambient_io_surge(numeric, numeric, numeric, numeric);
drop function if exists pgpm._ambient_congested(int, int);
drop function if exists pgpm._ambient_surge(int, numeric, numeric, int);
drop function if exists pgpm._forced_checkpoints();
drop function if exists pgpm._aimd_next(int, boolean, int, int, int);
drop function if exists pgpm.feathering_validation(regclass, interval, interval);

-- set_drain_adaptive / set_drain_ambient removed with adaptive feathering (#288). They tuned the closed
-- loop that paced the drain's microbatches against WAL supply and ambient I/O. Nothing left in pgpm is
-- paced by row volume: regrain has its own fixed batch, and obtain is pure metadata.


-- Operator switch for auto-regrain (REDESIGN.md sec 12). p_target_step (an interval for time/uuidv7, a
-- bigint step as text for id) turns it on: each maintenance tick feathers the oldest frozen coarse child
-- one budget-sized microbatch toward that granularity. null turns it off (regrain stays operator-driven via
-- regrain()/regrain_history()). This only PACES regraining across ticks; regrain_step enforces its own
-- preconditions (frozen, default-clear), so enabling it is always safe -- PROVIDED p_target_step is no
-- coarser than partition_step (issue #341, see the guard below).
create or replace function pgpm.set_regrain(p_parent regclass, p_target_step text default null)
returns void language plpgsql as $$
declare
  cfg pgpm.config;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;

  -- #341: a p_target_step COARSER than partition_step makes progress once, then wedges forever.
  -- maintain()'s auto-regrain candidate query calls a child "coarse" whenever it is wider than one
  -- partition_step, but regrain_step's own 'nosubdiv' guard refuses to split a child already at (or
  -- narrower than) p_target_step. Once a coarse child is split down to a regrain_to wider than
  -- partition_step, it is still "coarse" by the candidate query's definition, so every later tick
  -- reselects that same unsplittable child and makes no further progress -- silently, forever.
  -- Reject it here instead, at call time. Equal-or-finer stays allowed, matching every existing call
  -- site. partition_anchor is on-grid for ANY step (grid_floor(anchor, step, anchor) = anchor), so
  -- it is a safe shared point to compare the two steps' widths without a specific child row.
  if p_target_step is not null and pgpm._native_gt(
       cfg.control_kind,
       pgpm._grid_next(cfg.control_kind, p_target_step, cfg.partition_anchor),
       pgpm._grid_next(cfg.control_kind, cfg.partition_step, cfg.partition_anchor))
  then
    raise exception
      'pg_partition_magician: regrain target step % is coarser than partition_step % for % -- '
      'this would wedge auto-regrain permanently; use regrain()/regrain_history() for a one-off '
      'hierarchical split instead', p_target_step, cfg.partition_step, p_parent;
  end if;

  update pgpm.config set regrain_to = p_target_step where parent_table = p_parent;
end;
$$;

-- Operator switch for obtain's forward lookahead (issue #326). obtain/retain used to be settable
-- only at transmute time, and changing either afterward meant a raw `update pgpm.config`, with no
-- validation. p_obtain < 0 is not merely wrong, it is a SILENT no-op: obtain()'s
-- `for k in 0 .. cfg.obtain loop` never executes when cfg.obtain is negative (plpgsql's `lo .. hi`
-- is empty once lo > hi), so a negative value quietly disables all future lookahead with nothing
-- raised, ever. Refuse it here instead, before it reaches config.
create or replace function pgpm.set_obtain(p_parent regclass, p_obtain int)
returns void language plpgsql as $$
begin
  if p_obtain is null or p_obtain < 0 then
    raise exception 'pg_partition_magician: p_obtain must be a non-negative integer (got %)', p_obtain;
  end if;
  update pgpm.config set obtain = p_obtain where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- Operator switch for retention (issue #326). retain is the DESTRUCTIVE knob: it decides what
-- retain() DROPs, and a hand-written `update pgpm.config set retain = ...` has no validation at all
-- -- not the units check transmute applies (numeric for id, an interval everywhere else -- see
-- _retain_boundary), and no protection against a value that arms the very next maintain/retain tick
-- to drop a partition the current value still keeps.
--
-- Locked-in decision: REFUSE that case, not merely warn. This matches the house rule already applied
-- to set_regrain's coarser-target refusal and extend_to's p_max cap -- loud failure over a silently
-- armed destructive change. Loosening (a bigger interval/count, or null = keep forever) can never
-- trip it: a wider horizon only ever keeps a superset of what the narrower one kept, so the check
-- below is comparing _retain_boundary of the OLD config against the same function on a HYPOTHETICAL
-- one with p_retain substituted in, before anything is written.
create or replace function pgpm.set_retain(p_parent regclass, p_retain text default null)
returns void language plpgsql as $$
declare
  cfg pgpm.config;
  v_old_boundary text;
  v_new_boundary text;
  v_hit name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;

  if p_retain is not null then
    if cfg.control_kind = 'id' then
      begin
        perform p_retain::numeric;
      exception when others then
        raise exception 'pg_partition_magician: p_retain must be numeric for control_kind id (got %): %', p_retain, sqlerrm;
      end;
    else
      begin
        perform p_retain::interval;
      exception when others then
        raise exception 'pg_partition_magician: p_retain must be a valid interval for control_kind % (got %): %', cfg.control_kind, p_retain, sqlerrm;
      end;
    end if;
  end if;

  v_old_boundary := pgpm._retain_boundary(cfg);
  cfg.retain := p_retain;
  v_new_boundary := pgpm._retain_boundary(cfg);

  if v_new_boundary is not null then
    select p.child_name into v_hit
      from pgpm.part p
     where p.parent_table = p_parent and p.attached
       and (v_old_boundary is null or pgpm._native_gt(cfg.control_kind, p.hi, v_old_boundary))
       and not pgpm._native_gt(cfg.control_kind, p.hi, v_new_boundary)
     order by p.lo
     limit 1;
    if found then
      raise exception
        'pg_partition_magician: set_retain(%, %) refused for % -- the next retain() tick would drop '
        '% (and possibly others), which the current retain value still keeps. retain is the '
        'destructive knob, so this is refused rather than silently armed for the next tick.',
        p_parent, p_retain, p_parent, v_hit;
    end if;
  end if;

  update pgpm.config set retain = p_retain where parent_table = p_parent;
end;
$$;

-- Operator switch for the archive-before-drop strategy (issue #236's config.archive_fn contract).
-- p_archive_fn names any (p_parent regclass, p_child name, p_lo text, p_hi text) returns
-- pgpm.archive_result function -- pgpm_archive ships two (pgpm.archive_to_s3_ndjson/
-- archive_to_s3_parquet), or bring your own. Casting the argument to regprocedure validates that
-- the function exists with exactly this signature right away, not later when a maintenance tick
-- tries to call it. null (the default) turns archiving off: retire()'s drop precondition then only
-- waits on the write-block, never on coverage.
create or replace function pgpm.set_archive_fn(p_parent regclass, p_archive_fn regprocedure default null)
returns void language plpgsql as $$
begin
  update pgpm.config set archive_fn = p_archive_fn where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- pause/resume the scheduled lifecycle for one table. transmute registers a table paused by default
-- (the deliberate two-step: convert, inspect, then go live), and maintenance is a no-op while paused.
-- These are the first-class way to flip config.paused, so operators never hand-edit the catalog.
create or replace function pgpm.resume(p_parent regclass)
returns void language plpgsql as $$
begin
  update pgpm.config set paused = false where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

create or replace function pgpm.pause(p_parent regclass)
returns void language plpgsql as $$
begin
  update pgpm.config set paused = true where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- renamed maintenance -> maintain / maintenance_all -> maintain_all (completes the obtain/drain/retain
-- rhyme). Drop the old names so re-running the installer over a prior version does not strand them.
drop function if exists pgpm.maintenance(regclass);
drop procedure if exists pgpm.maintenance_all();

-- #279: maintain became a PROCEDURE. CREATE OR REPLACE cannot turn a function into a procedure, so the
-- old function has to go first or the installer fails on an upgrade with "cannot change routine kind".
drop function if exists pgpm.maintain(regclass);

-- maintain(): one tick of the lifecycle for one table.
--
-- A PROCEDURE, not a function, because a tick MUST NOT be one transaction (issue #279). obtain takes
-- ACCESS EXCLUSIVE on the parent (CREATE TABLE ... PARTITION OF) and on the DEFAULT. Locks release only
-- at transaction end, so in a single-transaction tick those were held across everything that followed,
-- including the drain -- whose duration is proportional to drain_batch. On the PARENT that blocks readers
-- too, so the whole table stalled for the length of a drain batch on every tick where obtain happened to
-- create a partition. Measured at 926 ms for a 400k batch against 96 ms for a 5k one: 10x the batch, 10x
-- the stall. That is the shape issue #263's acceptance rule exists to forbid.
--
-- So each step commits before the next begins, and no step's locks outlive it. The COMMITs sit at the top
-- level between the steps, never inside one: transaction control is illegal inside a block with an
-- EXCEPTION handler, and each step keeps its handler so a lock race still DEFERS that step alone rather
-- than aborting the tick.
--
-- The status is reported through an INOUT parameter, which is how a procedure returns anything. Callers
-- that do not care can `call pgpm.maintain(t)` and ignore it.
--
-- CAUTION for anyone adding a step: `set local` dies at COMMIT. lock_timeout is therefore re-applied
-- after every boundary below, and a new step placed after a COMMIT without re-applying it silently runs
-- with the session default -- which for obtain means waiting indefinitely for a lock it is designed to
-- fail fast on.
create or replace procedure pgpm.maintain(p_parent regclass, inout p_status text default null)
language plpgsql as $$
declare
  cfg pgpm.config;
  v_archived int := 0; v_dropped int := 0; v_restored int := 0;
  v_regrain text := 'skipped'; v_regrain_child name; v_validated int := 0;
  v_note text := '';
  v_batch int := null;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.paused then p_status := 'paused'; return; end if;

  -- Maintenance is a background janitor; it must NEVER block -- let alone deadlock -- the live
  -- workload. Each step is isolated in its own subtransaction, and a step that loses a lock race
  -- is DEFERRED (retried next tick) WITHOUT aborting the tick. obtain has its own procedure and
  -- its own cron job now (maintain_obtain(), issue #347), so a slow step here never delays it in
  -- turn; what remains -- write-block, archive, retain, auto-regrain, FK restore/validate -- still
  -- gets the same short lock_timeout treatment.
  perform set_config('lock_timeout', '200ms', true);

  -- Write-block on retain-eligibility (issue #235), ahead of retain()'s own drop logic: a partition
  -- is blocked from writes the instant it crosses the boundary, whether or not (or how far along)
  -- it is being archived. One of retire()'s two drop preconditions (#238; the other is archive
  -- coverage, below).
  begin
    perform pgpm._enforce_write_blocks(p_parent);
    perform pgpm._enforce_regrain_capture(p_parent);   -- #267: reap capture left by an abandoned regrain
  exception when others then
    v_note := v_note || ' write_block_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_write_block', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279). Installing a write-block trigger takes ACCESS EXCLUSIVE on the child. The archive
  -- step below then reads that same child for a whole byte budget, which is O(bytes), so without this
  -- the trigger's lock would cover the read.
  commit;
  perform set_config('lock_timeout', '200ms', true);

  -- Byte-budget chunked archiving (issue #237), one tick's worth per write-blocked, not-yet-covered
  -- child: only ever runs after the write-block step above, on children that step has already
  -- protected. retire()'s other drop precondition (#238) -- a child only drops once this has fully
  -- covered it.
  begin
    v_archived := pgpm._archive_step(p_parent);
  exception when others then
    v_note := v_note || ' archive_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_archive', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279): make a whole tick's archived bytes durable before anything else runs. Chunked
  -- archiving exists so a large child is covered over many ticks; folding a tick's chunk into the same
  -- transaction as the steps after it would mean a later failure discards archive progress already paid for.
  commit;
  perform set_config('lock_timeout', '200ms', true);

  begin
    v_dropped := pgpm.retain(p_parent);
  exception when others then
    v_note := v_note || ' retain_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_retain', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279). retain DROPs partitions, which takes ACCESS EXCLUSIVE on the parent. Also releases
  -- the FOR UPDATE SKIP LOCKED claim retain holds on each pgpm.part row it worked, which would otherwise
  -- be held against other retirement actors for the rest of the tick.
  commit;

  -- Adaptive feathering, the drain step, and the FK suspension that guarded it are all gone (#288).
  -- They existed to pace and protect the evacuation of the DEFAULT partition; with a complete forward
  -- grid there is nothing to evacuate. What remains of a tick is obtain, archive, retain, regrain and the
  -- FK restore -- none of which is paced by row volume.

  -- Auto-regrain target: the oldest FROZEN coarse child (if auto-regrain is on). A coarse child (hi > one
  -- step past lo) is frozen once its whole range is at/below the current grid floor (no live write still
  -- lands in it). Found here so the auto-regrain block below can use it.
  if cfg.regrain_to is not null then
    execute format(
      'select child_name from pgpm.part p where p.parent_table = %L::regclass and p.attached'
      || ' and pgpm._native_gt(%L, p.hi, pgpm._grid_next(%L, %L, p.lo))'
      || ' and not pgpm._native_gt(%L, p.hi, %L) order by p.lo::%s asc limit 1',
      p_parent::text, cfg.control_kind, cfg.control_kind, cfg.partition_step,
      cfg.control_kind,
      pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, pgpm._frontier_native(p_parent)),
      pgpm._native_type(cfg.control_kind))
      into v_regrain_child;
    v_batch := cfg.regrain_batch;   -- regrain's own microbatch size
  end if;

  -- Auto-regrain (REDESIGN.md sec 12): feather the oldest frozen coarse child (found up front as
  -- v_regrain_child) one COPY microbatch (sized by regrain_batch) toward regrain_to per tick. Isolated in
  -- its own subtransaction; a lock race or a soft status just retries next tick. regrain COPIES and never
  -- deletes: the source stays whole and attached until the atomic swap, so it never moves a referenced row out of the parent, never opens the snapshot() gap, and
  -- needs NO FK leash -- it is NOT gated on a live preserve FK and runs whether or not one is suspended.
  if v_regrain_child is not null then
    begin
      v_regrain := pgpm.regrain_step(p_parent, v_regrain_child, cfg.regrain_to, v_batch);
    exception when others then
      v_regrain := 'deferred';
      v_note := v_note || ' regrain_deferred';
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_regrain', left(sqlerrm, 200));
    end;
  elsif cfg.regrain_to is not null then
    v_regrain := 'none';   -- auto-regrain on, but no frozen coarse child to work
  end if;

  -- BOUNDARY (#279). regrain_step's swap is atomic within itself; this only stops its locks reaching
  -- the FK restore below, which re-adds a foreign key and so takes locks of its own on both sides.
  commit;
  perform set_config('lock_timeout', '3s', true);

  -- Re-add any incoming FKs that transmute(..., 'preserve') dropped, now against the new parent, AFTER
  -- the regrain has moved this tick. restore_incoming_fks self-gates on quiescence (no in-flight,
  -- not-yet-attached child), so while a multi-tick regrain is mid-flight it stays a no-op and
  -- the FK remains suspended (RI off, surfaced by status().fks_suspended), re-adding only once the regrain
  -- has swapped in its fine children. Isolated: a hiccup here never aborts progress.
  begin
    v_restored := pgpm.restore_incoming_fks(p_parent);
  exception when others then
    v_note := v_note || ' restore_fk_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_restore_fk', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#265). The restore above re-adds the FK NOT VALID and stops, which takes SHARE ROW
  -- EXCLUSIVE on the managed parent -- briefly, since NOT VALID scans nothing. This drops that lock
  -- BEFORE the validation scan below, which is the entire point: the two used to share a transaction and
  -- the scan ran under the ADD's lock, blocking writes on the parent for O(referencing table).
  commit;
  perform set_config('lock_timeout', '3s', true);

  -- Finish the validation, in its own transaction, where the VALIDATE holds only SHARE UPDATE EXCLUSIVE
  -- on the referencing table and ROW SHARE on the parent -- neither of which blocks writes. Usually the
  -- tick after the restore. p_respect_backoff so an FK blocked by a pre-existing orphan parks for five
  -- minutes rather than re-scanning the referencing table every tick to learn the same thing.
  begin
    v_validated := pgpm.validate_incoming_fks(p_parent, p_respect_backoff => true);
    if v_validated > 0 then v_note := v_note || format(' validated_fk[%s]', v_validated); end if;
  exception when others then
    v_note := v_note || ' validate_fk_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_validate_fk', left(sqlerrm, 200));
  end;

  p_status := format('archived=%s dropped=%s restored_fk=%s regrain=%s%s',
                     v_archived, v_dropped, v_restored, v_regrain, v_note);
end;
$$;

create or replace procedure pgpm.maintain_all()
language plpgsql as $$
-- v_status exists only to receive maintain()'s INOUT: PL/pgSQL requires a writable argument for an
-- output parameter, so the parameter's default cannot be relied on here. The sweep discards it; the
-- per-parent detail is already in pgpm.log.
declare r record; v_status text; v_warn boolean;
begin
  -- #275: undo any conversion whose session died mid-way, before anything else. Independent of
  -- pgpm.config on purpose: a half-converted table is not registered yet.
  perform pgpm._transmute_reap();
  -- #268: and any concurrent detach whose session died mid-way, for the same reason and with more
  -- urgency -- a partition left pending has its rows already invisible through the parent.
  perform pgpm._detach_reap();
  commit;

  -- #347: maintain() no longer obtains at all -- obtain() only still runs if the 'pgpm_obtain' job
  -- also got scheduled. schedule() is operator-invoked, never automatic, so an installation that
  -- already called it before upgrading past this change will NOT pick up the new job on its own.
  -- Warn once per sweep rather than silently obtaining here as a fallback: a fallback would just
  -- reintroduce, hidden, the exact "one slow table hostages another's obtain" problem this issue
  -- removes. Dynamic EXECUTE: cron.job is only resolved at call time, so this file still installs
  -- cleanly where pg_cron is not enabled (see pgpm._dispatch_detach).
  begin
    execute 'select exists (select 1 from cron.job where jobname = ''pgpm'' and database = current_database())'
         || ' and not exists (select 1 from cron.job where jobname = ''pgpm_obtain'' and database = current_database())'
      into v_warn;
  exception when others then
    v_warn := false;   -- no pg_cron, or no privilege on cron.job: nothing to warn about
  end;
  if v_warn then
    insert into pgpm.log (action, method)
      values ('warn_obtain_unscheduled',
              'pgpm_obtain cron job missing; re-run pgpm.schedule() to restore obtain (issue #347)');
  end if;

  -- One transaction per parent, not one for the whole sweep (#279). Two reasons. Locks: without it,
  -- every parent's locks accumulate until the last one is done, so a ten-table sweep ends holding ten
  -- tables' worth. Progress: a parent that raises no longer costs the parents before it their work.
  --
  -- Ordered so a sweep is reproducible: same tables, same order, every tick, which makes pgpm.log
  -- readable and a partial sweep's stopping point meaningful.
  --
  -- Deliberately NO exception handler around the call. One would abort the whole sweep on the first
  -- failing parent -- and worse, transaction control is illegal anywhere below an EXCEPTION handler, so
  -- wrapping this would silently disable every COMMIT inside maintain() and put the locks straight back.
  -- maintain() already isolates each of its own steps, so the raises that reach here are the ones that
  -- should stop a sweep: a table that is not managed, or a config row pointing at something gone.
  for r in select parent_table from pgpm.config order by parent_table loop
    call pgpm.maintain(r.parent_table, v_status);
    commit;
  end loop;
end;
$$;

-- maintain_obtain()/maintain_obtain_all() (issue #347): obtain, pulled out of maintain()/maintain_all()
-- into its own procedure and its own cron job. maintain_all() loops over every managed table
-- sequentially in one session; a slow archive/retain/regrain for one table used to delay obtain for
-- every table after it in the same tick, and unlike those other steps, a late obtain has a hard
-- consequence -- with no DEFAULT partition (#288), a write past the forward grid is rejected outright,
-- not queued. obtain's own backoff (cfg.obtain_retry_after) is per-parent, persisted state, not
-- in-memory, so it already coordinates correctly regardless of which session calls pgpm.obtain(); this
-- split introduces no new coordination problem. pgpm.obtain() itself is untouched -- it stays the pure
-- engine underneath, same as retain()/_archive_step()/regrain_step() are underneath maintain().
create or replace procedure pgpm.maintain_obtain(p_parent regclass, inout p_status text default null)
language plpgsql as $$
declare
  cfg pgpm.config;
  v_made int := 0;
  v_note text := '';
  v_try boolean;
  v_ahead int;
  v_cell text;
  v_top text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  -- Independently honor paused: this now runs on its own cadence and cannot assume maintain() ran
  -- first, or at all, in the same tick.
  if cfg.paused then p_status := 'paused'; return; end if;

  -- obtain gets a VERY SHORT lock_timeout. Its _create_partition is a single
  -- `CREATE TABLE ... PARTITION OF`, taking ACCESS EXCLUSIVE on the PARENT (issue #288 -- there is
  -- no DEFAULT partition to hold anything anymore) and scanning nothing. That ACCESS EXCLUSIVE still
  -- blocks every ordinary read or write through the parent for as long as the wait lasts, and a
  -- pending one queues every new locker behind it, so failing fast keeps a deferral nearly free: no
  -- long block, and obtain simply retries once this next has a gap. obtain is pgpm's only defence
  -- against a write with nowhere to go (there is no DEFAULT to catch one), but the future cells it
  -- creates aren't written yet, so deferring one tick costs nothing but time.
  perform set_config('lock_timeout', '200ms', true);

  -- obtain back-off: once a deferral happens, don't retry every tick -- under sustained write contention
  -- obtain can lose the lock race tick after tick, and each attempt queues an ACCESS EXCLUSIVE behind the
  -- workload for up to lock_timeout. A successful obtain clears the back-off.
  --
  -- The back-off must never outlast the grid. It dates from when a DEFAULT partition caught writes past
  -- the grid, which made deferring obtain harmless; since #288 such a write is refused. A load test at
  -- ~42k ids/s against a 3-partition lookahead (~14 s) lost one race, backed off 30 s, and every client
  -- aborted. So the back-off is honored only while at least ceil(obtain / 2) complete grid steps of attached
  -- coverage remain beyond the frontier's own grid cell; below that, obtain runs regardless.
  --
  -- COVERAGE, not a count of partitions that start past the frontier: transmute's p_bound_headroom gives
  -- the monolith a permanent hi several steps beyond the frontier, and that room is real even though the
  -- monolith's lo is far behind. Counting only partitions whose lo is ahead saw none of it, so such a table
  -- bypassed the back-off every tick and retried obtain's ACCESS EXCLUSIVE while it still had room (review
  -- on #386). Steps are walked from the frontier's cell up to max(hi), which assumes attached coverage is
  -- contiguous there: obtain and extend_to build it end to end, and retain only drops the oldest cells.
  -- The walk stops at the threshold, so it costs at most ceil(obtain / 2) grid steps. Counted only while a
  -- back-off is active, so a healthy tick pays nothing extra, and guarded so a failure to count (a dropped
  -- parent, say) falls back to the back-off rather than aborting the sweep.
  v_try := coalesce(cfg.obtain_retry_after, '-infinity'::timestamptz) <= clock_timestamp();
  if not v_try then
    begin
      -- the first grid boundary past the frontier's own cell, and the top of attached coverage
      v_cell := pgpm._grid_next(cfg.control_kind, cfg.partition_step,
                  pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                   pgpm._frontier_native(p_parent)));
      execute format('select max(hi::%s)::text from pgpm.part where parent_table = %L::regclass and attached',
                     pgpm._native_type(cfg.control_kind), p_parent::text) into v_top;
      v_ahead := 0;
      while v_top is not null and v_ahead < ceil(cfg.obtain / 2.0)
            and not pgpm._native_gt(cfg.control_kind,
                  pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_cell), v_top) loop
        v_ahead := v_ahead + 1;
        v_cell := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_cell);
      end loop;
      v_try := v_ahead < ceil(cfg.obtain / 2.0);
      if v_try then v_note := v_note || ' obtain_backoff_bypassed'; end if;
    exception when others then
      v_try := false;
    end;
  end if;
  if v_try then
    -- Back inside a handler (#288). obtain no longer commits -- with no DEFAULT there is no
    -- exclusion-constraint dance and no phases -- so the wrapper is legal again, and a lock race here
    -- is deferred like any other step. This is the ONLY thing standing between the workload and a
    -- write with nowhere to go, so a deferral also starts the back-off rather than retrying every tick.
    begin
      v_made := pgpm.obtain(p_parent);
      if cfg.obtain_retry_after is not null then
        update pgpm.config set obtain_retry_after = null where parent_table = p_parent;
      end if;
    exception when others then
      v_note := v_note || ' obtain_deferred';
      update pgpm.config set obtain_retry_after = clock_timestamp() + interval '30 seconds'
        where parent_table = p_parent;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_obtain', left(sqlerrm, 200));
    end;
  else
    v_note := v_note || ' obtain_backoff';
  end if;

  -- Drops obtain's ACCESS EXCLUSIVE on the parent (and, before #288, the DEFAULT) promptly rather
  -- than holding it until whatever calls this next commits.
  commit;

  p_status := format('obtained=%s%s', v_made, v_note);
end;
$$;

create or replace procedure pgpm.maintain_obtain_all()
language plpgsql as $$
-- Mirrors maintain_all()'s loop shape exactly (ordered for reproducibility, no exception handler
-- around the call -- maintain_obtain() already isolates its own failure). Deliberately does NOT
-- duplicate maintain_all()'s crash-recovery reaping (_transmute_reap()/_detach_reap()): obtain does
-- not depend on either having run, and the main maintain_all() job still performs them on its own
-- cadence regardless of whether this job also runs.
declare r record; v_status text;
begin
  for r in select parent_table from pgpm.config order by parent_table loop
    call pgpm.maintain_obtain(r.parent_table, v_status);
    commit;
  end loop;
end;
$$;

-- schedule()/unschedule(): a thin convenience wrapper around pg_cron for the three jobs pgpm needs, so the
-- operator does not hand-write the cron incantation. pgpm never schedules on its own (transmute stays
-- pg_cron-free, and a tick can be driven by hand with maintain/maintain_all/maintain_obtain_all); this
-- is the deliberate, discoverable way to turn the scheduled lifecycle on. One canonical job named 'pgpm'
-- calls maintain_all() for ALL managed tables, so it is scheduled once, not per table, and re-scheduling
-- updates the interval rather than duplicating. 'pgpm_obtain' (issue #347) calls maintain_obtain_all()
-- on its own, independent cadence (p_obtain_every), so a slow archive/retain/regrain for one table can
-- never delay obtain for another. The third, 'pgpm_detach', is idle machinery for issue #268 and is
-- described at its creation below; it is required only for retiring a partition that an incoming
-- foreign key references, and its cadence stays tied to p_every, not p_obtain_every. All three target
-- current_database() via schedule_in_database, so they run against the database pgpm lives in whether
-- or not that is the cron database. The cron calls are dynamic (EXECUTE) on purpose: the cron schema is
-- only resolved at call time, so this file still installs cleanly where pg_cron is not enabled yet. Run
-- it FROM the database where pg_cron is installed (its `cron` schema must be present); uninstall.sql
-- already unschedules every 'pgpm%' job. p_every/p_obtain_every are pg_cron schedules: standard 5-field
-- cron ('* * * * *' = every minute, the default; '*/5 * * * *' = every 5 min) or pg_cron's seconds
-- interval ('30 seconds'). Note pg_cron does NOT accept '1 minute'-style interval strings; minute
-- cadence goes through cron syntax.
--
-- UPGRADE HAZARD (issue #347): schedule() is operator-invoked, never automatic. An installation that
-- already called pgpm.schedule() before upgrading to a version with this split will NOT pick up the new
-- 'pgpm_obtain' job just by installing a newer install.sql -- maintain() no longer obtains at all, so
-- obtain silently stops running for that installation until the forward grid runs out and writes start
-- failing. There is no automatic migration for this, by design (a fallback that ran obtain from
-- maintain_all() when 'pgpm_obtain' is missing would just reintroduce the same hostage problem, hidden).
-- ANYONE UPGRADING PAST THIS CHANGE WHO HAS ALREADY RUN pgpm.schedule() MUST RE-RUN IT. maintain_all()
-- also logs a 'warn_obtain_unscheduled' row to pgpm.log once per sweep as a backstop for anyone who
-- misses this note.
create or replace function pgpm.schedule(p_every text default '* * * * *',
                                          p_obtain_every text default '* * * * *')
returns bigint language plpgsql as $$
declare v_jobid bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'pg_partition_magician: pg_cron is not installed in this database; enable it (create extension pg_cron) to schedule maintenance, or call pgpm.maintain_all() and pgpm.maintain_obtain_all() by hand';
  end if;
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm', p_every, 'call pgpm.maintain_all()', current_database())
    into v_jobid;
  -- Independent cadence from 'pgpm' on purpose (issue #347): obtain is the one step where falling
  -- behind has a hard consequence (no DEFAULT partition since #288, so a late write is rejected
  -- outright, not queued), so it gets its own job rather than sharing the main sweep's schedule.
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm_obtain', p_obtain_every, 'call pgpm.maintain_obtain_all()', current_database());
  -- This job exists solely as a place for retire() to put a `DETACH PARTITION ... CONCURRENTLY`
  -- (issue #268), which PostgreSQL refuses to execute from a function but a cron job runs as a
  -- top-level statement. It is created IDLE and stays idle until a REFERENCED partition needs
  -- retiring, at which point retire() rewrites its command in place and returns it to `select 1` once
  -- the drop lands. One standing job, rewritten, rather than one per retirement: pg_cron has no
  -- one-shot schedule, so a per-retirement job would keep firing after it succeeded.
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm_detach', p_every, 'select 1', current_database());
  return v_jobid;
end;
$$;

create or replace function pgpm.unschedule()
returns int language plpgsql as $$
declare v_n int := 0;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    return 0;   -- nothing scheduled if pg_cron is not here
  end if;
  execute 'select count(*)::int from (select cron.unschedule(jobid) from cron.job '
       || 'where jobname in (''pgpm'', ''pgpm_obtain'', ''pgpm_detach'') and database = current_database()) s' into v_n;
  return v_n;
end;
$$;

-- forget_missing(): clear pgpm's state for managed tables whose relation no longer exists (issue #296).
--
-- `pgpm.untransmute` is the sanctioned way to stop managing a table, and it deletes the pgpm rows. A plain
-- `DROP TABLE` does not: pgpm.config.parent_table is a regclass, which carries no dependency, so the row
-- survives pointing at a dead oid. Nothing then cleans it up, ever, and the consequences are permanent --
-- every maintenance tick logs skip_obtain / skip_write_block / skip_retain for it, and (before #296)
-- status() raised rather than reporting anything at all. There is a second, quieter reason not to leave it
-- sitting: pg_class oids are recycled, so a stale row is a standing chance of pgpm one day believing it
-- manages an unrelated table that happens to land on that oid.
--
-- Takes NO ARGUMENT deliberately. The relation is gone, so there is no name to pass, and an oid parameter
-- would be a foot-gun; with no argument the function can only ever match rows whose relation is ALREADY
-- absent, so by construction it cannot touch a live managed table. That is why this is safe to expose and
-- safe to re-run.
--
-- It DELETES pgpm's own bookkeeping and DROPS NOTHING. A detached partition survives its parent's DROP
-- still holding its rows (measured on PG 17.10) -- and "detached, not yet dropped" is exactly the state a
-- referenced partition's retirement sits in between the cron detach and the completing drop (#268). Those
-- tables are REPORTED in orphan_tables, by name, and left alone: destroying data as a side effect of a
-- cleanup command would be the worst possible reading of "forget". pgpm.log is left intact too -- it is an
-- append-only audit trail, and the history of a table that once existed is still history.
create or replace function pgpm.forget_missing()
returns table (parent_oid oid, partitions_forgotten int, orphan_tables text[])
language plpgsql as $$
declare r record; v_orphans text[]; v_parts int;
begin
  for r in
    select c.parent_table, c.parent_table::oid as oid
      from pgpm.config c
     where not exists (select 1 from pg_class k where k.oid = c.parent_table)
     order by c.parent_table::oid
  loop
    -- Children pgpm still has a row for that are STILL PRESENT on disk: everything attached went with the
    -- parent's DROP, so anything left here was detached first and is holding data nobody agreed to lose.
    --
    -- Matched on the child NAME alone, because pgpm.part records no namespace and the dropped parent's oid
    -- can no longer supply one. So this can in principle name a same-named table in an unrelated schema.
    -- Reported SCHEMA-QUALIFIED for exactly that reason: an operator acting on this list has to be able to
    -- see which table is meant, and if two schemas collide both are listed rather than one being guessed
    -- at. relkind filtered to tables/partitioned tables so an index or sequence sharing the name cannot
    -- appear as data at risk.
    select coalesce(array_agg(format('%I.%I', n.nspname, k.relname) order by n.nspname, k.relname),
                    '{}'::text[])
      into v_orphans
      from pgpm.part p
      join pg_class k on k.relname = p.child_name and k.relkind in ('r', 'p')
      join pg_namespace n on n.oid = k.relnamespace
     where p.parent_table = r.parent_table;

    select count(*)::int into v_parts from pgpm.part where parent_table = r.parent_table;

    delete from pgpm.transmute_inflight where parent_table = r.parent_table;
    delete from pgpm.archive_ledger     where parent_table = r.parent_table;
    delete from pgpm.dropped_fk         where parent_table = r.parent_table;
    delete from pgpm.part               where parent_table = r.parent_table;
    delete from pgpm.config             where parent_table = r.parent_table;

    insert into pgpm.log (parent_table, action, rows, method)
      values (r.parent_table, 'forget_missing', v_parts,
              case when coalesce(array_length(v_orphans, 1), 0) = 0
                   then 'relation was gone; pgpm state cleared'
                   else format('relation was gone; pgpm state cleared. LEFT IN PLACE (still hold data): %s',
                               array_to_string(v_orphans, ', ')) end);

    parent_oid := r.oid; partitions_forgotten := v_parts; orphan_tables := v_orphans;
    return next;
  end loop;
end;
$$;

-- check_default removed with the DEFAULT partition (#288).

-- check_uuidv7(): sanity-sample a uuid column. Genuine UUIDv7/ULID values decode
-- (via their leading 48-bit ms prefix) to plausible recent timestamps and score
-- ~1.0; random UUIDv4 columns score near 0. A heuristic, not a proof.
create or replace function pgpm.check_uuidv7(p_table regclass, p_control name, p_sample int default 1000)
returns table (sampled bigint, plausible bigint, fraction numeric, oldest timestamptz, newest timestamptz)
language plpgsql as $$
begin
  return query execute format($q$
    with s as (select pgpm._uuid_to_ts(%I) as ts from %s limit %s)
    select count(*)::bigint,
           count(*) filter (where ts between timestamptz '2015-01-01' and now() + interval '1 day')::bigint,
           round(coalesce(count(*) filter (where ts between timestamptz '2015-01-01' and now() + interval '1 day')::numeric
                          / nullif(count(*), 0), 0), 4),
           min(ts), max(ts)
    from s
  $q$, p_control, p_table::text, p_sample);
end;
$$;

-- check_text_time(): sanity-sample a text/varchar column against a DECLARED shape (prefix, width,
-- radix, unit) -- the text_time analogue of check_uuidv7, needed for the same reason: transmute treats
-- a text/varchar control column as text_time on assumption (the shape is supplied by the operator, not
-- detected), so this is what verifies real data actually matches it before anything is partitioned on
-- it. A row that does not even have the right prefix/width/alphabet is counted implausible directly
-- (never passed to _text_time_to_ts, which would raise on it -- one bad row must not abort the sample);
-- a row that IS shaped correctly is further checked for decoding to a plausible recent timestamp,
-- exactly as check_uuidv7 does. Heuristic, not a proof.
create or replace function pgpm.check_text_time(
  p_table regclass, p_control name, p_prefix text, p_width int, p_radix int, p_unit text,
  p_sample int default 1000,
  p_alphabet text default null, p_discard_bits int default 0,
  p_epoch timestamptz default '1970-01-01 00:00:00+00'
) returns table (sampled bigint, plausible bigint, fraction numeric)
language plpgsql as $$
declare v_class text;
begin
  if p_alphabet is not null then
    if length(p_alphabet) <> p_radix then
      raise exception 'pg_partition_magician: alphabet % has length %, which does not match radix %', p_alphabet, length(p_alphabet), p_radix;
    end if;
    v_class := p_alphabet;
  else
    if p_radix < 2 or p_radix > 36 then
      raise exception 'pg_partition_magician: radix % is out of range for the default 0-9a-z alphabet (supported: 2-36; supply p_alphabet for a wider or different one)', p_radix;
    end if;
    v_class := substr('0123456789abcdefghijklmnopqrstuvwxyz', 1, p_radix);
  end if;
  return query execute format($q$
    with s as (select %1$I::text as v from %2$s limit %3$s),
         shaped as (
           select v from s
            where v is not null
              and left(v, length(%4$L)) = %4$L
              and length(v) >= length(%4$L) + %5$s
              and substr(v, length(%4$L) + 1, %5$s) !~ %6$L
         ),
         decoded as (
           select pgpm._text_time_to_ts(v, %4$L, %5$s, %7$s, %8$L, %9$L, %10$s, %11$L) as ts from shaped
         )
    select (select count(*) from s where v is not null)::bigint,
           (select count(*) from decoded
             where ts between timestamptz '2015-01-01' and now() + interval '1 day')::bigint,
           round(coalesce(
             (select count(*) from decoded
               where ts between timestamptz '2015-01-01' and now() + interval '1 day')::numeric
               / nullif((select count(*) from s where v is not null), 0), 0), 4)
  $q$, p_control, p_table::text, p_sample, p_prefix, p_width, '[^' || v_class || ']', p_radix, p_unit,
      p_alphabet, p_discard_bits, p_epoch);
end;
$$;

-- check_time_monotonic: how co-monotonic is an id column with a timestamp column? Samples p_sample
-- rows at random, orders them by the id, and reports the fraction of adjacent pairs whose time is
-- non-decreasing. ~1.0 means id and time co-increase; backfills and out-of-order arrival drive it
-- down. This is the tier-2 safety check for retaining by time against an id partition
-- key (REDESIGN.md): mapping "older than T" to an id boundary is only sound when id and
-- time co-increase. Heuristic, not a proof -- mirrors check_uuidv7's plausibility sampling.
create or replace function pgpm.check_time_monotonic(
  p_table regclass, p_id name, p_time name, p_sample int default 1000
) returns table (sampled bigint, monotonic bigint, fraction numeric)
language plpgsql as $$
begin
  return query execute format($q$
    with s as (select %2$I::timestamptz as t, %1$I as idv from %3$s order by random() limit %4$s),
         o as (select t, lag(t) over (order by idv) as prev from s)
    select count(*) filter (where prev is not null)::bigint,
           count(*) filter (where prev is not null and t >= prev)::bigint,
           round(coalesce(count(*) filter (where prev is not null and t >= prev)::numeric
                          / nullif(count(*) filter (where prev is not null), 0), 0), 4)
    from o
  $q$, p_id, p_time, p_table::text, p_sample);
end;
$$;

-- status(): the operator's at-a-glance view.
--
-- The drain-wedge columns are gone with the drain (#288): default_rows, closed_rows, default_oldest,
-- last_drained and drain_skips all described a backlog in a DEFAULT partition that no longer exists.
-- inflight_partitions stays, but now counts only REGRAIN copy-children not yet attached.
--
-- fks_suspended / fks_unvalidated surface preserve-managed incoming FK state (issue #95):
-- fks_suspended = incoming FKs currently DROPPED (RI off on the referencing table). That is now a
-- transient, sub-transaction state inside regrain's swap rather than something spanning a drain
-- campaign, so a standing non-zero value means a swap died mid-flight. fks_unvalidated = FKs re-added
-- NOT VALID (enforcing new writes) but blocked from full validation by pre-existing orphans (see
-- incoming_fk_orphans() / validate_incoming_fks()).
-- parent_missing (#296) says the managed relation itself is gone -- dropped without untransmute, so the
-- config row is pointing at an oid with no pg_class entry. status() used to RAISE on such a row and
-- therefore return nothing for any table; now it reports it, since naming the dead table is the most
-- useful thing it can do. pgpm.forget_missing() clears the state.
--
-- dropped/recreated (not CREATE OR REPLACE) because the redesign widens the return shape with
-- coarse_partitions + history_unregrained (REDESIGN.md section 14), and again for parent_missing (#296).
drop function if exists pgpm.status();
create or replace function pgpm.status()
returns table (
  parent regclass, control_kind text, partition_step text, obtain int, retain text,
  paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
  newest_bound text,
  fks_suspended bigint, fks_unvalidated bigint, history_unregrained boolean, retain_drop_failures bigint,
  retain_backlog bigint, retain_detaching bigint, parent_missing boolean
)
language plpgsql as $$
declare
  r pgpm.config; v_nsp name; v_np bigint; v_coarse bigint; v_inflight bigint; v_new text;
  v_missing boolean;

  v_fks_susp bigint; v_fks_unval bigint;
  v_last_retain_id bigint; v_drop_fails bigint; v_detaching bigint;
  v_retain_boundary text; v_retain_backlog bigint;
begin
  for r in select * from pgpm.config loop
    select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r.parent_table;

    -- Has the managed relation been dropped out from under us (#296)? status() is the DIAGNOSTIC, so it
    -- must never be the thing that dies: one config row pointing at a vanished oid used to raise out of
    -- this whole set-returning function, so a single dropped table returned NOTHING for every managed
    -- table, healthy ones included. Everything below except retain_backlog comes from pgpm.part /
    -- pgpm.config / pgpm.log, so a dead parent still gets a full, useful row -- and the flag says which
    -- one it is, which is the single most actionable thing to report here.
    v_missing := not exists (select 1 from pg_class c where c.oid = r.parent_table);

    -- n_partitions = attached (real) partitions; coarse_partitions = the un-regrained coarse children (a
    -- wider-than-one-step range, REDESIGN.md section 14) -- the regraining backlog; inflight = the
    -- not-yet-attached regrain children.
    select count(*) filter (where attached),
           count(*) filter (where attached
                            and pgpm._native_gt(r.control_kind, hi, pgpm._grid_next(r.control_kind, r.partition_step, lo))),
           count(*) filter (where not attached)
      into v_np, v_coarse, v_inflight from pgpm.part where parent_table = r.parent_table;
    execute format('select max(hi::%s)::text from pgpm.part where parent_table = %L::regclass and attached',
                   pgpm._native_type(r.control_kind), r.parent_table::text) into v_new;
    -- preserve-managed incoming FK state: dropped (RI off) vs re-added-but-not-validated (orphan-blocked)
    select count(*) filter (where restored_at is null),
           count(*) filter (where restored_at is not null and validated_at is null)
      into v_fks_susp, v_fks_unval
      from pgpm.dropped_fk where parent_table = r.parent_table;
    -- retain_drop_failures: unexpected DROP failures (issue #238; previously pre_drop hook
    -- failures, before pgpm.hook stopped being consulted here) logged AFTER the last successful
    -- drop (a since-last-progress count). Archive coverage not yet complete
    -- is NOT a failure and is never logged here -- it is the normal, expected reason retain_backlog
    -- stays non-zero while chunked archiving catches up (see retain_backlog below).
    select max(id) into v_last_retain_id from pgpm.log
      where parent_table = r.parent_table and action = 'retain_drop';
    -- Exact action values, never a prefix match: `fail_retain_crossing` (issue #268, a live row
    -- references a doomed one and the FK's own ON DELETE refused the delete), `fail_retain_detach`
    -- (no pgpm_detach cron job to dispatch to) and `fail_retain_identity` (issue #407, the child's
    -- name no longer resolves to the object whose detach was dispatched) wedge retention exactly as a
    -- failed drop does, so they belong in the same since-last-progress count.
    -- `fail_archive_identity` (issue #421) is here for the same reason one step earlier in the
    -- lifecycle: the archive step refused a candidate whose name no longer resolves to the relation
    -- pgpm.part recorded, so no chunk is ever written for it, _archive_fully_covered never goes true,
    -- and retire()'s drop precondition never opens. Retention is stalled just as hard as by a failed
    -- drop, and like fail_retain_identity it never clears itself.
    -- `fail_write_block_identity` (issue #429) is the same mismatch one step earlier again, and it
    -- stalls the same chain from the top: a partition that never gets its write block is never an
    -- archive candidate, so it is never covered, so it is never dropped.
    select count(*) into v_drop_fails from pgpm.log
      where parent_table = r.parent_table
        and action in ('fail_retain_drop', 'fail_retain_crossing', 'fail_retain_detach',
                       'fail_retain_identity', 'fail_archive_identity', 'fail_write_block_identity')
        and id > coalesce(v_last_retain_id, 0);
    -- Partitions whose concurrent detach has been dispatched and not yet completed (issue #268).
    -- Non-zero is normal for a tick or two while cron performs the detach; persistently non-zero with
    -- retain_drop_failures climbing means the dispatch has nowhere to go.
    select count(*) into v_detaching from pgpm.part
      where parent_table = r.parent_table and retiring_at is not null;
    -- retain_backlog: eligible-but-undropped partitions (whole range at/below the retention horizon,
    -- issue #189). Non-zero is normal while retain_batch paces a backlog across ticks, or while
    -- chunked archiving is still catching up on a write-blocked child -- it should fall tick over
    -- tick; flat with retain_drop_failures climbing = wedged on an unexpected drop failure.
    -- null, not 0, for a dead parent: the horizon is derived from the frontier, and the frontier is
    -- max(control) READ FROM THE RELATION. With the relation gone there is no honest answer, and 0 would
    -- read as "nothing is eligible" -- a claim status() cannot make. This is also the one branch that
    -- would raise, via _retain_boundary -> _frontier_native, so skipping it is what keeps status() alive.
    v_retain_backlog := case when v_missing then null else 0 end;
    v_retain_boundary := case when v_missing then null else pgpm._retain_boundary(r) end;
    if v_retain_boundary is not null then
      execute format(
        'select count(*) from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s',
        r.parent_table::text, pgpm._native_type(r.control_kind), v_retain_boundary, pgpm._native_type(r.control_kind))
        into v_retain_backlog;
    end if;
    parent := r.parent_table; control_kind := r.control_kind; partition_step := r.partition_step;
    obtain := r.obtain; retain := r.retain; paused := r.paused; n_partitions := v_np;
    coarse_partitions := v_coarse; inflight_partitions := v_inflight; history_unregrained := v_coarse > 0;
    newest_bound := v_new;
    fks_suspended := v_fks_susp; fks_unvalidated := v_fks_unval; retain_drop_failures := v_drop_fails;
    retain_backlog := v_retain_backlog; retain_detaching := v_detaching;
    parent_missing := v_missing;
    return next;
  end loop;
end;
$$;
-- snapshot() removed with the drain (#288). It existed to paper over the drain's VISIBILITY GAP: during a
-- multi-batch drain the already-moved rows lived in an unattached child, so a plain read of the parent
-- undercounted the interval being drained, and snapshot() UNIONed those children back in. regrain never
-- opened that gap (it copies and swaps atomically) and there is no drain, so a read of the parent is
-- never short and there is nothing to union.


-- ===================== observability: pg_flight_recorder correlation =====================
--
-- pgpm.log records exactly when pgpm ran each operation, but pgpm keeps no history of what the
-- rest of the database was doing during it. The optional pg_flight_recorder (PGFR) extension
-- samples that history continuously (wait events, locks, checkpoints, WAL, I/O, query latency) but
-- does not know which spikes were pgpm's. The two functions below bridge the two over a
-- pgpm.log time window. The integration is strictly READ-ONLY and ONE-DIRECTIONAL (pgpm writes
-- nothing into PGFR, and PGFR needs no changes), and PGFR is NEVER a dependency: observe_window
-- works standalone from pure pgpm.log, and the PGFR-delegating function (impact_report) raises a
-- clear, catchable error when PGFR is absent rather than failing on a raw
-- "function pgfr_analyze.* does not exist".

-- _observe_has_pgfr: is pg_flight_recorder's analysis layer present? Gates on the pgfr_analyze
-- SCHEMA, not pg_extension: PGFR's script install (the common path) creates the schema and its
-- objects without CREATE EXTENSION; only the dbdev/TLE channel registers an extension. The schema
-- is present either way.
create or replace function pgpm._observe_has_pgfr()
returns boolean language sql stable as $$
  select exists (select 1 from pg_namespace where nspname = 'pgfr_analyze');
$$;

-- observe_window: the span pgpm was active on p_parent within the last p_since, plus a summary of what it
-- did. PURE pgpm.log -- no PGFR dependency, so it is useful and testable on its own. Always returns exactly
-- one row; when there is no activity, the window bounds are null and the counts are 0.
--
-- Narrowed in #304: it used to report `drains`, `adaptive_ticks` and a per-signal `backoffs` breakdown,
-- all counted from `drain_move` / `drain_budget` log actions. Neither action has been written since the
-- drain and its adaptive feathering were removed (#288), so those columns could only ever read 0 -- a
-- reported zero that means "this never happens" is worse than no column at all, because it looks like
-- a measurement.
drop function if exists pgpm.observe_window(regclass, interval);
create or replace function pgpm.observe_window(
  p_parent regclass, p_since interval default '7 days'
) returns table (
  parent_table   regclass,
  window_start   timestamptz,
  window_end     timestamptz,
  duration       interval,
  log_rows       bigint,
  rows_copied    bigint,
  regrains       bigint,
  retains        bigint
) language sql stable as $$
  select
    p_parent,
    min(l.at),
    max(l.at),
    max(l.at) - min(l.at),
    count(*),
    coalesce(sum(l.rows) filter (where l.action = 'regrain_copy'), 0),
    count(*) filter (where l.action = 'regrain'),
    count(*) filter (where l.action = 'retain_drop')
  from pgpm.log l
  where l.parent_table = p_parent
    and l.at >= now() - p_since;
$$;

-- impact_report: "what did my conversion do to the workload?" Derives the active window from
-- pgpm.log (observe_window) and asks pgfr_analyze what the database was doing during it. Sections
-- degrade independently: a section whose PGFR call has too little data (e.g. fewer than two
-- snapshots, or pg_stat_statements reset) reports that rather than failing the whole report.
create or replace function pgpm.impact_report(
  p_parent regclass, p_since interval default '7 days'
) returns text language plpgsql stable as $$
declare
  w        record;
  cmp      record;
  ln       text[] := '{}';
  sect     text;
begin
  if not pgpm._observe_has_pgfr() then
    raise exception 'pg_partition_magician: impact_report requires pg_flight_recorder (the pgfr_analyze extension). Install it to correlate pgpm operations against database telemetry, or use pgpm.observe_window() for the pgpm-only summary.';
  end if;

  select * into w from pgpm.observe_window(p_parent, p_since);
  if w.window_start is null then
    return format('pg_partition_magician impact report: no pgpm activity for %s in the last %s.', p_parent, p_since);
  end if;

  ln := ln || format('pg_partition_magician :: impact report for %s', p_parent);
  ln := ln || format('  window:   %s  ->  %s  (%s)', w.window_start, w.window_end, w.duration);
  ln := ln || format('  pgpm did: %s log rows, %s rows copied; %s regrains, %s retains',
                     w.log_rows, w.rows_copied, w.regrains, w.retains);
  ln := ln || ''::text;

  -- Checkpoints / WAL / temp / I/O over the window (pgfr_analyze.compare brackets
  -- the window with the nearest snapshots and returns the deltas).
  begin
    select * into cmp from pgfr_analyze.compare(w.window_start, w.window_end);
    if not found then   -- FOUND, not "cmp is null": a record with any null field is neither IS NULL nor IS NOT NULL
      ln := ln || '  database impact: insufficient snapshots in the window (need at least two).'::text;
    else
      ln := ln || format('  forced checkpoints: %s (timed: %s)', cmp.ckpt_requested_delta, cmp.ckpt_timed_delta);
      ln := ln || format('  WAL generated:      %s', cmp.wal_bytes_pretty);
      ln := ln || format('  temp spilled:       %s', cmp.temp_bytes_pretty);
      ln := ln || format('  client read time:   %s ms', round(coalesce(cmp.io_client_read_time_ms, 0), 1));
    end if;
  exception when others then
    ln := ln || format('  database impact: unavailable (%s)', left(sqlerrm, 120));
  end;
  ln := ln || ''::text;

  -- Top wait events in the window.
  begin
    sect := '';
    for cmp in
      select wait_event_type, wait_event, total_waiters, pct_of_samples
        from pgfr_analyze.wait_summary(w.window_start, w.window_end)
       where wait_event is not null
       order by total_waiters desc nulls last
       limit 5
    loop
      sect := sect || format('    %-28s waiters=%s  (%s%% of samples)' || chr(10),
                             cmp.wait_event_type || '/' || cmp.wait_event, cmp.total_waiters, round(cmp.pct_of_samples, 1));
    end loop;
    ln := ln || 'top wait events:'::text;
    ln := ln || coalesce(nullif(rtrim(sect, chr(10)), ''), '    (none sampled)');
  exception when others then
    ln := ln || format('top wait events: unavailable (%s)', left(sqlerrm, 120));
  end;
  ln := ln || ''::text;

  -- Top queries by execution-time delta in the window.
  begin
    sect := '';
    for cmp in
      select queryid, calls_delta, round(total_exec_time_delta_ms::numeric, 1) as exec_ms
        from pgfr_analyze.statement_activity_v2(w.window_start, w.window_end, 5)
       order by total_exec_time_delta_ms desc nulls last
    loop
      sect := sect || format('    queryid=%-22s calls=%s  exec=%s ms' || chr(10), cmp.queryid, cmp.calls_delta, cmp.exec_ms);
    end loop;
    ln := ln || 'top queries by exec-time:'::text;
    ln := ln || coalesce(nullif(rtrim(sect, chr(10)), ''), '    (none; pg_stat_statements may be absent)');
  exception when others then
    ln := ln || format('top queries by exec-time: unavailable (%s)', left(sqlerrm, 120));
  end;

  return array_to_string(ln, chr(10));
end $$;


-- restore_incoming_fks(): re-add the incoming FKs that transmute(..., p_incoming_fks => 'preserve')
-- recorded, pointing them back at the new partitioned parent, but only once it is SAFE. Safe = no
-- in-flight, not-yet-attached child partition exists. (The drained-closed-tail gate this used to carry
-- went with the DEFAULT in #288: there is no tail to drain.) A referenced row inside such a child is
-- outside the visible parent, which a live NO ACTION FK would reject and a CASCADE/SET NULL one would
-- silently honour, so the FK must stay dropped until the child is attached.
-- The re-add is split (issue #95): `ADD CONSTRAINT ... NOT VALID` (enforces every new write, always
-- succeeds) committed separately from `VALIDATE` (scans existing rows, may fail on an orphan written
-- during the suspend window). A failed VALIDATE leaves the FK NOT VALID -- enforcing new writes,
-- surfaced via status().fks_unvalidated -- rather than rolling the re-add back into a permanent silent
-- brick. Returns the number re-added; 0 (a no-op) while a regrain copy-child is still unattached, so
-- `maintain` can call it every tick and it acts only when the table is ready.
-- p_ids (#378): restricts the re-add to specific pgpm.dropped_fk rows, instead of every
-- not-yet-restored row for the parent. Used by regrain_step's swap, which snapshots exactly which
-- rows it is about to suspend and passes that exact set here, so a pre-existing "stale" unrestored
-- FK (one this swap never touched via suspend_incoming_fks) is left for the next tick's own,
-- unscoped call instead of being swept up under the swap's own lock. null (the default) preserves
-- today's "restore everything unrestored for this parent" behavior for every other caller.
create or replace function pgpm.restore_incoming_fks(p_parent regclass, p_ids bigint[] default null)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_closed bigint; v_inflight name;
  r pgpm.dropped_fk%rowtype; v_n int := 0; v_is_part boolean; v_readded boolean;
begin
  if not exists (select 1 from pgpm.dropped_fk
                  where parent_table = p_parent and restored_at is null
                    and (p_ids is null or id = any(p_ids))) then
    return 0;
  end if;
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- gate 1 (the drained-closed-tail gate) is gone with the DEFAULT (#288): there is no tail to drain.
  -- gate 2: no in-flight (un-attached) child mid-regrain (same shape as transmute's orphan guard). A
  -- regrain copy-child is EXCLUDED (its range is contained in an attached partition): regrain copies without
  -- deleting, so the referenced rows never leave the visible parent, and a copy-regrain never needs the FK
  -- suspended -- so it must not hold the FK off either (that would reopen the RI window the copy design
  -- closes). Only an un-attached child in no attached partition's range (an orphan) blocks the re-add.
  select c.relname into v_inflight
    from pg_class c
   where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)
     and c.relkind = 'r'
     and starts_with(c.relname, v_rel || '_p')
     and case when cfg.control_kind = 'id'
              then substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{19}$'
              else substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{4}(_[0-9]+)*$'
         end
     and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
     and not exists (                                            -- a regrain copy is not an absent-row child
           select 1 from pgpm.part cp
            join pgpm.part ap on ap.parent_table = cp.parent_table and ap.attached
           where cp.parent_table = p_parent and cp.child_name = c.relname
             and not pgpm._native_gt(cfg.control_kind, ap.lo, cp.lo)   -- ap.lo <= cp.lo
             and not pgpm._native_gt(cfg.control_kind, cp.hi, ap.hi))  -- cp.hi <= ap.hi
   limit 1;
  if v_inflight is not null then return 0; end if;

  -- Re-add each dropped FK, then attempt to VALIDATE it once -- in SEPARATE subtransactions, so a
  -- VALIDATE that fails on a pre-existing orphan does NOT roll back the re-add (issue #95). A re-added
  -- NOT VALID FK already enforces RI for every NEW write; only pre-existing rows go unverified. So the
  -- FK comes back at the first opportunity and can never be permanently bricked by an orphan
  -- written during the suspend window; the orphans (if any) are surfaced by status().fks_unvalidated /
  -- pgpm.incoming_fk_orphans() and cleared with pgpm.validate_incoming_fks() once the operator removes
  -- them. The recorded definition already names the parent (captured before the rename).
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is null
              and (p_ids is null or id = any(p_ids))
            order by id loop
    v_is_part := (select relkind from pg_class where oid = r.referencing_table) = 'p';
    v_readded := false;
    begin
      if v_is_part then
        -- self-referential / partitioned referencer: Postgres forbids NOT VALID FKs here, so add it
        -- validating in one step (all-or-nothing). A pre-existing orphan leaves it DROPPED and logged,
        -- without bricking the other FKs; self-ref / partitioned-referencer FKs are typically small.
        execute format('alter table %s add constraint %I %s',
                       r.referencing_table::text, r.constraint_name, r.definition);
        update pgpm.dropped_fk set restored_at = now(), validated_at = now() where id = r.id;
      else
        execute format('alter table %s add constraint %I %s not valid',
                       r.referencing_table::text, r.constraint_name, r.definition);
        update pgpm.dropped_fk set restored_at = now(), validated_at = null where id = r.id;
      end if;
      v_readded := true;
      v_n := v_n + 1;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'restore_incoming_fk', r.constraint_name);
    exception when others then
      insert into pgpm.log (parent_table, action, method)
        values (p_parent, 'fail_restore_incoming_fk', left(r.constraint_name || ': ' || sqlerrm, 200));
    end;
    -- The VALIDATE deliberately does NOT happen here (#265). It used to, in its own subtransaction, which
    -- isolated its errors but not its locks: the ADD above takes SHARE ROW EXCLUSIVE on BOTH the
    -- referencing table and the MANAGED PARENT, and a subtransaction releases nothing, so that lock was
    -- held across an O(referencing table) scan. SHARE ROW EXCLUSIVE conflicts with ROW EXCLUSIVE, so
    -- writes to the parent -- the table pgpm exists to keep online -- blocked for the whole scan.
    -- Measured at 224 ms against 4M referencing rows, and linear.
    --
    -- Splitting them by COMMITting here is not available: this function is also called by regrain_step
    -- mid-swap, and regrain_step is a FUNCTION whose driver regrain() loops it in ONE transaction,
    -- atomic and gap-free. Converting this to a committing procedure would cascade into breaking that.
    --
    -- So the FK is left NOT VALID, which already enforces every NEW write, and maintain() validates it on
    -- a later tick in its own transaction -- where the VALIDATE holds only SHARE UPDATE EXCLUSIVE on the
    -- referencing table and ROW SHARE on the parent, neither of which blocks writes.
  end loop;
  return v_n;
end;
$$;

-- validate_incoming_fks(): finish validating any preserve-managed FK that was re-added NOT VALID but
-- not yet validated (its pre-existing orphans blocked it). Run after clearing the orphans
-- (pgpm.incoming_fk_orphans() lists the counts). Each VALIDATE is isolated, so one still-blocked FK
-- does not stop the others; returns the number newly validated.
--
-- maintain() calls this on a later tick with p_respect_backoff => true, which is what completes the
-- validation without operator action now that restore_incoming_fks deliberately stops at NOT VALID
-- (#265). The back-off is what makes that safe: a FAILING validate re-scans the referencing table to
-- discover it still cannot succeed, so a failure parks it for five minutes instead of burning that scan
-- every tick. A successful one sets validated_at and is never revisited.
--
-- Called directly by an operator it ignores the back-off, since the point of running it by hand is that
-- the orphans have just been cleared and the answer should be immediate.
create or replace function pgpm.validate_incoming_fks(
  p_parent regclass, p_respect_backoff boolean default false
)
returns int language plpgsql as $$
declare r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null and validated_at is null
              and (not p_respect_backoff
                   or coalesce(validate_retry_after, '-infinity'::timestamptz) <= clock_timestamp())
            order by id loop
    begin
      execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
      update pgpm.dropped_fk set validated_at = now(), validate_retry_after = null where id = r.id;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'validate_incoming_fk', r.constraint_name);
      v_n := v_n + 1;
    exception when others then
      -- A failed VALIDATE re-scanned the referencing table to get here. Wait before doing that again
      -- (#265); the orphans blocking it are cleared by hand, so a tight retry only burns I/O.
      update pgpm.dropped_fk set validate_retry_after = clock_timestamp() + interval '5 minutes'
        where id = r.id;
      insert into pgpm.log (parent_table, action, method)
        values (p_parent, 'fail_validate_incoming_fk', left(r.constraint_name || ': ' || sqlerrm, 200));
    end;
  end loop;
  return v_n;
end;
$$;

-- incoming_fk_orphans(): for each preserve-managed FK that is re-added but not yet validated, count the
-- orphan rows blocking validation -- referencing rows whose (non-null) FK columns match no parent key.
-- The operator uses this to find and clear what blocks validate_incoming_fks(). Reads the column
-- mapping from the live (NOT VALID) constraint in pg_constraint; handles composite FKs.
create or replace function pgpm.incoming_fk_orphans(p_parent regclass)
returns table (referencing_table regclass, constraint_name name, orphan_rows bigint)
language plpgsql as $$
declare r pgpm.dropped_fk%rowtype; c pg_constraint%rowtype; v_join_q text; v_notnull_q text; v_cnt bigint;
begin
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null and validated_at is null order by id loop
    select * into c from pg_constraint
      where conrelid = r.referencing_table and conname = r.constraint_name and contype = 'f';
    if not found then continue; end if;
    select string_agg(format('r.%I = p.%I', fa.attname, pa.attname), ' and '),
           string_agg(format('r.%I is not null', fa.attname), ' and ')
      into v_join_q, v_notnull_q
      from unnest(c.conkey, c.confkey) with ordinality as u(fk_att, pk_att, ord)
      join pg_attribute fa on fa.attrelid = c.conrelid and fa.attnum = u.fk_att
      join pg_attribute pa on pa.attrelid = c.confrelid and pa.attnum = u.pk_att;
    execute format('select count(*)::bigint from %s r where %s and not exists (select 1 from %s p where %s)',
                   c.conrelid::regclass::text, v_notnull_q, c.confrelid::regclass::text, v_join_q) into v_cnt;
    referencing_table := r.referencing_table; constraint_name := r.constraint_name; orphan_rows := v_cnt;
    return next;
  end loop;
end;
$$;

-- KEPT, with a much narrower remit after #288. It used to be called by maintain before every drain,
-- dropping the FK for the whole span of a multi-tick drain campaign -- an RI window other sessions could
-- observe, and pgpm's only one. That caller is gone with the drain. The remaining caller is regrain's
-- SWAP, which suspends and restores INSIDE its own transaction, so no session ever observes RI off.
-- suspend_incoming_fks(): the inverse of restore. Re-drop any preserve-managed FK that is currently live,
-- so a referenced row is never taken out of the visible parent past a live FK. That matters beyond a mere
-- stall: a live ON DELETE CASCADE / SET NULL FK would silently delete or null the referencing rows as
-- their referent leaves the parent (verified on PG 17), which is why regrain's swap drops and re-adds
-- inside one transaction rather than relying on the DETACH being brief.
-- p_force is what regrain's swap passes, since a copy-regrain has no pending work of its own to detect.
create or replace function pgpm.suspend_incoming_fks(p_parent regclass, p_force boolean default false)
returns int language plpgsql as $$
declare v_closed bigint; r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  if not exists (select 1 from pgpm.dropped_fk
                  where parent_table = p_parent and restored_at is not null) then
    return 0;
  end if;
  -- The drain-work gate is gone with the DEFAULT (#288). regrain's swap is the only caller left and it
  -- always passes p_force, so a call with p_force false has no work to justify it and does nothing.
  if not p_force then return 0; end if;
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
    update pgpm.dropped_fk set restored_at = null, validated_at = null where id = r.id;
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'suspend_incoming_fk', r.constraint_name);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace view pgpm.partitions as
  select parent_table, child_name, lo, hi, created_at, attached from pgpm.part order by parent_table, lo;

-- =============================================================================
-- Identity: what is installed here, and when it got here.
--
-- version() is the version of the CODE in this database, baked in at release time. It is the same
-- string as extension.control's default_version and the git tag; test.sh checks that pairing at the
-- file level, which nothing inside the database can do. Every support conversation starts with this
-- question, and the install.sql channel never reads extension.control, so without this a database
-- installed from install.sql carries no version at all.
--
-- pgpm.installed is the history of install.sql runs, not a single current-version row. Re-running
-- install.sql IS the upgrade path for this channel (hence the `add column if not exists` lines
-- throughout), so each run appends and the table doubles as an upgrade log. One honest limitation: an
-- install predating this table records its first row as the version it was upgraded TO, because the
-- history can only start where the table does.
-- =============================================================================
create or replace function pgpm.version()
returns text language sql immutable as $$ select '0.6.0'::text $$;

create table if not exists pgpm.installed (
  id         bigint      generated always as identity primary key,
  version    text        not null,
  -- The full server_version string, packaging suffix included ('17.10 (Debian 17.10-1.pgdg13+1)'),
  -- because for support the exact build matters as much as the major.
  pg_version text        not null,
  at         timestamptz not null default now()
);

-- THE LAST STATEMENT IN THIS FILE, deliberately. psql -f gives each statement its own transaction
-- unless it is called with --single-transaction, so a file that dies partway leaves a partial install.
-- Appending the row here makes "a row for version V" mean "the V run reached the end of the file",
-- which is the only cheap evidence an operator has that an upgrade completed rather than aborted.
insert into pgpm.installed (version, pg_version)
  values (pgpm.version(), current_setting('server_version'));

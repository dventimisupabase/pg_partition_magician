-- Adaptive closed-loop feathering (DESIGN.md section 8, mode 2). The drain row budget is no longer a
-- fixed constant: when drain_adaptive is on, maintenance rides the budget just under the WAL supply via
-- AIMD. The LEADING signal is the WAL generation rate vs the sustainable rate (max_wal_size /
-- checkpoint_timeout): outrun a fraction (drain_wal_high_water) of it and a forced checkpoint is coming,
-- so back off before its I/O storm. A forced checkpoint that slips through is a reactive backstop.
-- A SECOND, complementary signal backs off when ambient workload is contended -- more than
-- drain_ambient_max_waiters non-pgpm client backends stuck on IO/lock waits -- so the drain yields to
-- workload that is being starved (which the WAL signal misses: a crowded-out writer makes little WAL).
-- Off by default (mode 1, fixed rate; ambient signal off until drain_ambient_max_waiters > 0).
create extension if not exists pgtap;

begin;
select plan(40);

-- ---- the pure controller: AIMD arithmetic, independent of any server state -------------------------
select is(pgpm._aimd_next(10000, false, 1000, 64000, 1000), 11000,
          'calm tick: additive-increase by the increment');
select is(pgpm._aimd_next(10000, true, 1000, 64000, 1000), 5000,
          'congested tick: multiplicative-decrease (halve)');
select is(pgpm._aimd_next(1500, true, 1000, 64000, 1000), 1000,
          'decrease clamps at the floor (never starves forward progress)');
select is(pgpm._aimd_next(64000, false, 1000, 64000, 1000), 64000,
          'increase clamps at the ceiling (never over-probes)');

-- ---- the leading signal: WAL rate vs sustainable rate ----------------------------------------------
select cmp_ok(pgpm._wal_sustainable_bps(), '>', 0::numeric,
              'sustainable WAL rate (max_wal_size/checkpoint_timeout) is positive on this server');
-- pure congestion decision: over high-water fraction of sustainable WAL rate, or a forced checkpoint
select is(pgpm._feather_congested(20000000, 13600000, 0.7, false), true,
          'WAL rate above high-water => congested (the LEADING trigger, before the storm)');
select is(pgpm._feather_congested(5000000, 13600000, 0.7, false), false,
          'WAL rate below high-water => calm');
select is(pgpm._feather_congested(5000000, 13600000, 0.7, true), true,
          'forced checkpoint => congested (the reactive backstop)');
select is(pgpm._feather_congested(NULL, 13600000, 0.7, false), false,
          'no WAL sample yet (first tick) => not congested');
select is(pgpm._feather_congested(20000000, 0, 0.7, false), false,
          'unknown sustainable rate => not congested (no divide-by-zero)');

-- ---- the ambient-contention signal: back off when workload backends are starved on IO/locks --------
select cmp_ok(pgpm._ambient_io_waiters(), '>=', 0::int,
              'ambient IO/lock-waiter sensor returns a non-negative count');
select is(pgpm._ambient_congested(5, 3), true,
          'more waiters than the threshold => congested (yield to the contended workload)');
select is(pgpm._ambient_congested(2, 3), false,
          'fewer waiters than the threshold => calm');
select is(pgpm._ambient_congested(5, 0), false,
          'threshold 0 disables the ambient signal (back-compatible default)');

-- ---- the SELF-CALIBRATING ambient baseline: an EWMA of the waiter count is the learned "normal" ----
-- A FIXED threshold is the wrong shape: "normal" waiter count is box/workload-dependent (~0 on an idle
-- box, double digits on a busy one), so a constant fires everywhere or nowhere. Instead we learn the
-- recent baseline (EWMA) and back off on a RELATIVE surge above it. EWMA arithmetic, pure:
select is(pgpm._ambient_baseline_next(NULL, 5, 0.2), 5::numeric,
          'no baseline yet => initialise to the first observation');
select is(pgpm._ambient_baseline_next(10, 0, 0.5), 5::numeric,
          'EWMA step: 0.5*0 + 0.5*10 = 5 (baseline decays toward a calmer sample)');
select is(pgpm._ambient_baseline_next(10, 20, 0.25), 12.5::numeric,
          'EWMA step: 0.25*20 + 0.75*10 = 12.5 (baseline rises toward a busier sample)');

-- the relative trigger (pure): congested when current waiters exceed p_factor * the learned baseline,
-- with a floor so an idle box (baseline ~0) does not fire on a couple of transient waiters.
select is(pgpm._ambient_surge(10, 2, 2.0, 2), true,
          'waiters well above factor*baseline => surge (yield to the contended workload)');
select is(pgpm._ambient_surge(3, 2, 2.0, 2), false,
          'a small rise still within the baseline band => calm');
select is(pgpm._ambient_surge(10, 2, 0, 2), false,
          'factor 0 disables the self-calibrating signal (back-compatible default)');
select is(pgpm._ambient_surge(3, NULL, 2.0, 2), false,
          'no baseline yet (boot) => the floor governs and small counts stay calm');
select is(pgpm._ambient_surge(9, NULL, 2.0, 2), true,
          'a clear surge on a fresh/idle box (no baseline) still fires via the floor');
select is(pgpm._ambient_surge(4, 0, 2.0, 5), false,
          'the floor stops an idle box (baseline ~0) firing on a few transient waiters');

-- ---- the backstop sensor: version-aware forced-checkpoint counter ----------------------------------
select cmp_ok(pgpm._forced_checkpoints(), '>=', 0::bigint,
              'forced-checkpoint sensor returns a non-negative counter on this PG version');

-- ---- fixture: an id-kind table with many closed intervals to drain --------------------------------
-- step 100, ids 1..1000 => intervals [0,100)..[900,1000) -- the lower ones are CLOSED (need draining),
-- the highest is the open frontier. One maintenance tick drains one interval, so the loop below has
-- plenty of intervals to exercise the controller across many ticks.
create table public.evt (id bigint generated by default as identity primary key, body text);
insert into public.evt (body) select 'x' from generate_series(1, 1000);
select pgpm.adopt('public.evt', 'id', 100, p_premake => 2, p_drain_batch => 8000, p_paused => false);

-- ---- default is mode 1 (fixed): adaptive off, controller state untouched ---------------------------
select is((select drain_adaptive from pgpm.config where parent_table = 'public.evt'::regclass),
          false, 'adaptive is off by default (mode 1, fixed rate)');
select is((select drain_ambient_max_waiters from pgpm.config where parent_table = 'public.evt'::regclass),
          0, 'ambient absolute cap disabled by default (drain_ambient_max_waiters = 0)');
select is((select drain_ambient_factor from pgpm.config where parent_table = 'public.evt'::regclass),
          0::numeric, 'self-calibrating ambient signal off by default (drain_ambient_factor = 0)');
select is((select drain_ambient_alpha from pgpm.config where parent_table = 'public.evt'::regclass),
          0.2::numeric, 'ambient baseline smoothing defaults to 0.2 (drain_ambient_alpha)');
select is((select drain_ambient_floor from pgpm.config where parent_table = 'public.evt'::regclass),
          2, 'ambient surge floor defaults to 2 (no false fire on a couple of transient waiters)');
select is((select drain_ambient_baseline from pgpm.config where parent_table = 'public.evt'::regclass),
          NULL::numeric, 'ambient baseline starts unlearned (NULL until the first adaptive tick)');
select lives_ok($$ select pgpm.maintenance('public.evt') $$, 'a fixed-mode maintenance tick runs');
select is((select drain_budget from pgpm.config where parent_table = 'public.evt'::regclass),
          NULL, 'fixed mode never populates the adaptive budget');

-- ---- the setter flips the mode on --------------------------------------------------------------------
select pgpm.set_drain_adaptive('public.evt', true);
select is((select drain_adaptive from pgpm.config where parent_table = 'public.evt'::regclass),
          true, 'set_drain_adaptive(true) turns mode 2 on');

-- ---- the self-calibrating setter turns the signal on and re-learns from scratch --------------------
update pgpm.config set drain_ambient_baseline = 7 where parent_table = 'public.evt'::regclass;
select pgpm.set_drain_ambient('public.evt', 2.0);
select is((select drain_ambient_factor from pgpm.config where parent_table = 'public.evt'::regclass),
          2.0::numeric, 'set_drain_ambient sets the surge factor (turns the self-calibrating signal on)');
select is((select drain_ambient_baseline from pgpm.config where parent_table = 'public.evt'::regclass),
          NULL::numeric, 'set_drain_ambient resets the learned baseline so it re-learns from scratch');
-- a draining adaptive tick with the signal on must LEARN a baseline (EWMA seeds from the first sample)
select pgpm.maintenance('public.evt');
select isnt((select drain_ambient_baseline from pgpm.config where parent_table = 'public.evt'::regclass),
            NULL::numeric, 'a draining adaptive tick with the ambient signal on learns a baseline');
-- back to the WAL-only regime so the calm/congested ticks below stay deterministic
update pgpm.config set drain_ambient_factor = 0 where parent_table = 'public.evt'::regclass;

-- ---- a calm tick (baseline == current counter => no congestion) recovers the budget UP toward the
--      ceiling (start below it; drain_batch=8000 is the ceiling, recovery step is 8000/8=1000) --------
update pgpm.config set drain_budget = 4000, drain_ckpt_seen = pgpm._forced_checkpoints()
  where parent_table = 'public.evt'::regclass;
select pgpm.maintenance('public.evt');
select cmp_ok((select drain_budget from pgpm.config where parent_table = 'public.evt'::regclass),
              '>', 4000, 'calm tick: the controller recovers the budget upward toward the ceiling');

-- ---- a congested tick (baseline below current counter => +delta) backs the budget OFF (halves) -----
update pgpm.config set drain_budget = 8000, drain_ckpt_seen = pgpm._forced_checkpoints() - 1
  where parent_table = 'public.evt'::regclass;
select pgpm.maintenance('public.evt');
select cmp_ok((select drain_budget from pgpm.config where parent_table = 'public.evt'::regclass),
              '<', 8000, 'congested tick: the controller backs the budget off (forced checkpoint sensed)');

-- ---- correctness is preserved: adaptive still drains the closed tail to zero -----------------------
do $$ begin for i in 1..40 loop perform pgpm.maintenance('public.evt'); end loop; end $$;
select is((select closed_rows from pgpm.check_default('public.evt')),
          0::bigint, 'adaptive mode still drains the closed tail to zero');

-- ---- the safety invariant: the budget NEVER exceeds drain_batch (the ceiling). A bigger batch would
--      mean a bigger WAL spike, so adaptive only ever feathers DOWN from the operator's tuned rate. ---
select cmp_ok((select drain_budget from pgpm.config where parent_table = 'public.evt'::regclass),
              '<=', 8000, 'budget never exceeds drain_batch: adaptive only throttles down (cannot worsen the tail)');

select * from finish();
rollback;

-- The append-only catch-up dropped rows that arrived with control at or below the watermark (issue #460).
--
-- Without p_track_changes the cutover catches up rows whose control value is past the copy watermark
-- (max control in the destination). Two shapes of row arriving during the online window were therefore
-- lost with no error and no log row: a row whose control value is BELOW the watermark (out-of-order
-- appends: multi-writer clock skew, batched device uploads, backfills -- the normal IoT shape), and a
-- row EXACTLY AT it, which a strict `>` excludes. Nothing under the lock compared the two sides, so the
-- source was dropped short.
--
-- Three layers, cheapest first, each pinned here:
--   * on a KEYED table the under-lock catch-up now takes `>=` the watermark with a key anti-join
--     against the destination, so the equality edge is never a loss and the copied row already at the
--     watermark is not duplicated (part A: the cutover SUCCEEDS with both late rows present by identity);
--   * under the lock, before anything is dropped, the source's count(*) is compared with the destination's
--     and the swap is REFUSED on a mismatch, naming both counts (part B: a keyed table with one row
--     behind the watermark; part C: a keyless table, where equality is detected rather than repaired);
--   * the reference states the late-arrival caveat and recommends p_track_changes for a keyed table.
--
-- WHAT THE HARNESS ALLOWS, same constraint as tests/timescale/db/17: run_timescale fails the track on any
-- `ERROR:` line, so a refusing cutover must be wrapped by throws_like, and a procedure that reaches its own
-- COMMIT inside a function raises `invalid transaction termination`. A cutover that WRONGLY proceeds to
-- the swap therefore cannot be observed committing: it dies at its commit and rolls back into the same
-- end state as a correct refusal. The discriminator is the refusal's message with BOTH COUNTS in it; the
-- state assertions after it are invariants and are marked so. p_predrain => false in those parts so no
-- per-batch COMMIT is reached inside throws_like (the residual here is one row, so the pre-drain would do
-- nothing anyway).
--
-- LIVENESS: every part records the watermark BEFORE inserting the late rows and asserts each row's
-- relation to it (behind, exactly at, 1 us past) and that none of them is in the destination, so a
-- pass cannot come from rows that were simply copied in the first place. Fixtures are asymmetric on
-- purpose: 3 rows in, 1 or 2 of them invisible to the catch-up, never a shape where errors cancel.
select plan(32);

-- Keyed and keyless hypertables whose data ends BEFORE now() (headroom), so the late rows can sit in the
-- recent past above, at and below the copy watermark and still at/under now(). Same reasoning as test 15.
-- UNIQUE (device_id, ts) with device_id = g keeps the pair unique; late rows use device_id >= 9001.
create or replace function mk_past_keyed(p_name text, p_rows int, p_start_ago interval, p_end_ago interval)
returns void language plpgsql as $$
begin
  execute format('drop table if exists %I cascade', p_name);
  execute format('create table %I (ts timestamptz not null, device_id bigint not null, temp double precision,
                  constraint %I unique (device_id, ts))', p_name, p_name || '_key');
  perform create_hypertable(p_name, 'ts', chunk_time_interval => interval '1 day');
  execute format('insert into %I (ts, device_id, temp)
    select now() - %L::interval + (g * ((%L::interval - %L::interval) / %s)), g, random()*100
    from generate_series(1, %s) g', p_name, p_start_ago, p_start_ago, p_end_ago, p_rows, p_rows);
end $$;

create or replace function mk_past_keyless(p_name text, p_rows int, p_start_ago interval, p_end_ago interval)
returns void language plpgsql as $$
begin
  execute format('drop table if exists %I cascade', p_name);
  execute format('create table %I (ts timestamptz not null, device_id bigint, temp double precision)', p_name);
  perform create_hypertable(p_name, 'ts', chunk_time_interval => interval '1 day');
  execute format('insert into %I (ts, device_id, temp)
    select now() - %L::interval + (g * ((%L::interval - %L::interval) / %s)), g, random()*100
    from generate_series(1, %s) g', p_name, p_start_ago, p_start_ago, p_end_ago, p_rows, p_rows);
end $$;

-- the copy watermark per table, recorded BEFORE the late rows go in (the liveness anchor for every part)
create table t20_w (tbl text primary key, w timestamptz not null);

-- ================= PART A: keyed, late rows AT and just PAST the watermark; the cutover succeeds =================

select mk_past_keyed('la_a', 240, interval '10 days', interval '2 days');
call pgpm.from_hypertable_copy('la_a', 'ts');
insert into t20_w select 'la_a', max(ts) from la_a_pgpm_dest;

-- the late rows, AFTER the watermark was recorded: one exactly at it (a different device, so the key stays
-- unique), one 1 us past it
insert into la_a (ts, device_id, temp) select w, 9002, 2 from t20_w where tbl = 'la_a';
insert into la_a (ts, device_id, temp) select w + interval '1 microsecond', 9003, 3 from t20_w where tbl = 'la_a';

select is((select ts from la_a where device_id = 9002), (select w from t20_w where tbl = 'la_a'),
  'A witness: the equal row sits EXACTLY at the copy watermark (max control in the destination)');
select is((select ts from la_a where device_id = 9003), (select w + interval '1 microsecond' from t20_w where tbl = 'la_a'),
  'A witness: the past row sits 1 us past the watermark');
select is((select count(*)::int from la_a_pgpm_dest where device_id in (9002, 9003)), 0,
  'A witness: neither late row is in the destination -- both arrived after the copy');
select is((select array_agg(device_id) from la_a_pgpm_dest where ts = (select w from t20_w where tbl = 'la_a')),
  array[240]::bigint[],
  'A witness: the destination already holds the copied row at the watermark (device 240), so a bare >= would duplicate it');
select is((select count(*)::int from la_a), 242, 'A witness: the source holds 240 copied + 2 late rows');

call pgpm.from_hypertable_cutover('la_a', 'ts', interval '1 month', p_paused => false);

select is((select relkind::text from pg_class where oid = 'la_a'::regclass), 'p',
  'A: the table migrated to a native partitioned table');
select is((select count(*)::int from la_a), 242,
  'A: all 242 rows present -- nothing lost, nothing duplicated');
select is((select array_agg(device_id order by device_id) from la_a where ts = (select w from t20_w where tbl = 'la_a')),
  array[240, 9002]::bigint[],
  'A: the rows at the watermark by identity: the copied one (240) and the late equal one (9002), each exactly once');
select is((select array_agg(device_id) from la_a where ts = (select w + interval '1 microsecond' from t20_w where tbl = 'la_a')),
  array[9003]::bigint[],
  'A: the 1 us past row survived by identity');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'la_a'), 0,
  'A: the hypertable was torn down');

-- ================= PART B: keyed, one late row BEHIND the watermark; the cutover refuses =================
--
-- The anti-join is bounded to the tail at/past the watermark (an unbounded key anti-join would be O(rows)
-- under the lock), so a row landing an hour behind it is invisible to the catch-up. The conservation check
-- must catch it: source 243, destination 242 (the equal and past rows WERE taken, which is the keyed
-- layer doing its job; the behind row was not).
select mk_past_keyed('la_b', 240, interval '10 days', interval '2 days');
call pgpm.from_hypertable_copy('la_b', 'ts');
insert into t20_w select 'la_b', max(ts) from la_b_pgpm_dest;

insert into la_b (ts, device_id, temp) select w - interval '1 hour', 9001, 1 from t20_w where tbl = 'la_b';
insert into la_b (ts, device_id, temp) select w, 9002, 2 from t20_w where tbl = 'la_b';
insert into la_b (ts, device_id, temp) select w + interval '1 microsecond', 9003, 3 from t20_w where tbl = 'la_b';

select cmp_ok((select ts from la_b where device_id = 9001), '<', (select w from t20_w where tbl = 'la_b'),
  'B witness: the behind row sits below the copy watermark');
select is((select ts from la_b where device_id = 9002), (select w from t20_w where tbl = 'la_b'),
  'B witness: the equal row sits exactly at it');
select is((select count(*)::int from la_b_pgpm_dest where device_id >= 9001), 0,
  'B witness: none of the three late rows is in the destination');
select is((select count(*)::int from la_b), 243, 'B witness: the source holds 243 = 240 copied + 3 late');
select is((select count(*)::int from la_b_pgpm_dest), 240, 'B witness: the destination holds the 240 copied');

select throws_like(
  $$ call pgpm.from_hypertable_cutover('la_b', 'ts', interval '1 month', p_predrain => false) $$,
  '%refusing to swap: the source holds 243 rows but the destination would hold 242 after the append-only catch-up, a difference of 1.%p_track_changes => true%',
  'B: the cutover refuses, naming both counts -- 242 shows the keyed catch-up took the equal and past rows and could not see the one behind the watermark');

-- invariants, not discriminators (a mutant that wrongly proceeds dies at its own COMMIT and rolls back too)
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'la_b'), 1,
  'B: the source is still a hypertable -- the refusal happened before the drop');
select is((select array_agg(device_id order by device_id) from la_b where device_id >= 9001), array[9001, 9002, 9003]::bigint[],
  'B: the source is whole, all three late rows present by identity');
select is((select count(*)::int from la_b), 243, 'B: with all 243 rows');
select is((select count(*)::int from la_b_pgpm_dest), 240,
  'B: the destination is intact and back to its 240 copied rows (the catch-up rolled back with the refusal)');

-- ================= PART C: keyless, the same three late rows; equality is DETECTED, not repaired =================
--
-- A keyless table has no key to anti-join by, and an all-columns anti-join would be wrong (duplicate
-- rows are legitimate in a keyless table), so the catch-up keeps its strict `>` there. The equal row is
-- therefore lost by the catch-up as well as the behind row: source 243, destination 241 (only the 1 us
-- past row taken). Different shortfall from part B on purpose -- a check that only ever saw "off by one"
-- could be reading the wrong thing.
select mk_past_keyless('la_c', 240, interval '10 days', interval '2 days');
call pgpm.from_hypertable_copy('la_c', 'ts');
insert into t20_w select 'la_c', max(ts) from la_c_pgpm_dest;

insert into la_c (ts, device_id, temp) select w - interval '1 hour', 9001, 1 from t20_w where tbl = 'la_c';
insert into la_c (ts, device_id, temp) select w, 9002, 2 from t20_w where tbl = 'la_c';
insert into la_c (ts, device_id, temp) select w + interval '1 microsecond', 9003, 3 from t20_w where tbl = 'la_c';

select is((select count(*)::int from pg_constraint where conrelid = 'la_c'::regclass and contype in ('p', 'u')), 0,
  'C witness: the table is keyless');
select cmp_ok((select ts from la_c where device_id = 9001), '<', (select w from t20_w where tbl = 'la_c'),
  'C witness: the behind row sits below the copy watermark');
select is((select ts from la_c where device_id = 9002), (select w from t20_w where tbl = 'la_c'),
  'C witness: the equal row sits exactly at it');
select is((select array_agg(device_id) from la_c_pgpm_dest where ts = (select w from t20_w where tbl = 'la_c')),
  array[240]::bigint[],
  'C witness: the destination already holds the copied row at the watermark');
select is((select count(*)::int from la_c_pgpm_dest where device_id >= 9001), 0,
  'C witness: none of the three late rows is in the destination');
select is((select count(*)::int from la_c), 243, 'C witness: the source holds 243 = 240 copied + 3 late');

select throws_like(
  $$ call pgpm.from_hypertable_cutover('la_c', 'ts', interval '1 month', p_predrain => false) $$,
  '%refusing to swap: the source holds 243 rows but the destination would hold 241 after the append-only catch-up, a difference of 2.%p_track_changes => true%',
  'C: the cutover refuses, naming both counts -- 241 shows the keyless catch-up took only the 1 us past row');

select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'la_c'), 1,
  'C: the source is still a hypertable -- the refusal happened before the drop');
select is((select array_agg(device_id order by device_id) from la_c where device_id >= 9001), array[9001, 9002, 9003]::bigint[],
  'C: the source is whole, all three late rows present by identity');
select is((select count(*)::int from la_c), 243, 'C: with all 243 rows');
select is((select count(*)::int from la_c_pgpm_dest), 240,
  'C: the destination is intact and back to its 240 copied rows');
select ok(not exists (select 1 from pgpm.config where parent_table::text in ('la_b', 'la_c', 'public.la_b', 'public.la_c')),
  'C: neither refused table was handed to transmute');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

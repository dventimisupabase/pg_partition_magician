-- pgpm.archive_ledger is keyed (parent_table, lo) and matched to its partition by child_name (issue #511).
--
-- Coverage is therefore attached to a NAME, and two things that already happen change what a name means
-- without touching the ledger. regrain's swap drops the source and deletes its pgpm.part row, leaving its
-- chunks in the ledger under a name nothing tracks; the first fine child starts at the same lo, so its
-- first chunk's INSERT collides on archive_ledger_pkey, _archive_step raises out of the whole tick,
-- maintain logs skip_archive, and no partition of that parent is archived or retired again. The rename
-- procedure the guide documented ("update pgpm.part.child_name in the same transaction and nothing else")
-- orphans a partly archived partition's chunks the same way: archiving restarts from lo under the new name
-- and collides with the old name's row at lo, every tick, for good. Both are wedges that never clear.
--
-- The rule now: coverage recorded under a name that is no longer a tracked partition of the parent, over a
-- range a tracked partition holds, cannot describe that partition's contents (nothing guarded it across
-- the change), so _archive_step discards it before archiving, logged as archive_coverage_reset, and the
-- partition holding the range archives from its own lo. Where pgpm itself changes a name or replaces a
-- partition it keeps the ledger consistent in the same transaction: the swap retires the source's chunks
-- with its pgpm.part row, and the #266 transitional rename carries them to the new name. The documented
-- procedure now updates pgpm.archive_ledger.child_name too, which keeps the coverage attached and lets
-- archiving resume from the watermark instead of starting over.
--
-- Identity, not cardinality: the strategy RECORDS what it is handed, so every assertion below is about
-- WHICH ids were handed under WHICH name, which ledger rows exist, and which partitions remain. Every
-- table holds 2000 (or 900) contiguous ids and a single frontier row, so a chunk's ids are exactly
-- [1, hi) and a missing or doubled export cannot cancel against anything.
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(35);

create schema pgpm_test125;
create table pgpm_test125.handed (seq bigint generated always as identity, parent regclass, child name, id bigint);
create function pgpm_test125.recorder(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_rows bigint; v_result pgpm.archive_result;
begin
  execute format('insert into pgpm_test125.handed (parent, child, id) select %L::regclass, %L, id from public.%I where id >= %L::bigint and id < %L::bigint',
                 p_parent::text, p_child, p_child, p_lo, p_hi);
  get diagnostics v_rows = row_count;
  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  return v_result;
end;
$$;

-- ======================= case A: regrain's swap retires the source's coverage =======================
-- Monolith [0, 3000) of ids 1..2000, aged by a frontier row at 20000 (horizon 19000), archived for ONE
-- tick under a 2000-byte budget so the ledger holds a strict prefix under the monolith's name before the
-- regrain runs. That prefix is what tests/74 never has (it regrains before any tick), and it is the row
-- the first fine child's chunk collides with.
create table public.rg125 (id bigint primary key, payload text);
insert into public.rg125 select g, repeat('x', 100) from generate_series(1, 2000) g;
call pgpm.transmute('public.rg125', 'id', 1000, p_retain => 1000::bigint, p_paused => false);
insert into public.rg125 values (20000, 'frontier');
update pgpm.config set archive_byte_budget = 2000 where parent_table = 'public.rg125'::regclass;
select pgpm.set_archive_fn('public.rg125', 'pgpm_test125.recorder(regclass,name,text,text)');
select child_name as rg_mono from pgpm.part where parent_table = 'public.rg125'::regclass and lo = '0' \gset

call pgpm.maintain('public.rg125');   -- write-blocks the monolith and records its first chunk
select hi as rg_w from pgpm.archive_ledger where parent_table = 'public.rg125'::regclass and child_name = :'rg_mono' \gset

select is((select array_agg(lo) from pgpm.archive_ledger where parent_table = 'public.rg125'::regclass and child_name = :'rg_mono'),
  array['0'], 'LIVENESS: the monolith has one chunk in the ledger, at its own lo');
select ok(:'rg_w'::bigint > 1 and :'rg_w'::bigint < 2000,
  'LIVENESS: that chunk ends inside the data, so the monolith is partly archived and cannot be dropped yet');
select is((select array_agg(id order by id) from pgpm_test125.handed where child = :'rg_mono'),
  (select array_agg(g) from generate_series(1, :'rg_w'::bigint - 1) g),
  'LIVENESS: the strategy was handed exactly the prefix [1, watermark) under the monolith''s name');

do $$ declare v_status text; i int := 0; begin
  loop
    v_status := pgpm.regrain_step('public.rg125',
                  (select child_name from pgpm.part where parent_table = 'public.rg125'::regclass and (hi::numeric - lo::numeric) > 1000),
                  '100', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or i > 300;
  end loop;
end $$;
select is((select array_agg(id order by id) from public.rg125 where id in (1, 2000, 20000)), array[1::bigint, 2000, 20000],
  'LIVENESS: the regrain swapped with the rows intact');

-- Asserted BEFORE any maintenance tick, so it is the swap itself under test and not the tick's own sweep.
select is((select array_agg(lo order by lo::bigint) from pgpm.archive_ledger where parent_table = 'public.rg125'::regclass and child_name = :'rg_mono'),
  null, 'the swap retired the source''s ledger rows along with its pgpm.part row');
select is((select array_agg(format('%s %s %s', lo, hi, rows)) from pgpm.log
            where parent_table = 'public.rg125'::regclass and action = 'archive_coverage_reset'),
  array['0 3000 1'], 'and logged one archive_coverage_reset: the source''s one chunk, over the source''s range');

update pgpm.config set archive_byte_budget = 8 * 1024 * 1024 where parent_table = 'public.rg125'::regclass;
do $$ declare i int := 0; v_status text; begin
  while i < 40 and exists (select 1 from pgpm.part where parent_table = 'public.rg125'::regclass and hi::bigint <= 3000) loop
    call pgpm.maintain('public.rg125', v_status);
    i := i + 1;
  end loop;
end $$;

select is((select array_agg(distinct method) from pgpm.log where parent_table = 'public.rg125'::regclass and action = 'skip_archive'),
  null, 'no archive tick failed after the swap');
select is((select array_agg(lo order by lo::bigint) from pgpm.part where parent_table = 'public.rg125'::regclass and hi::bigint <= 3000),
  null, 'every fine child of [0, 3000) was archived and retired within 40 ticks');
select is((select array_agg(id order by id) from pgpm_test125.handed where parent = 'public.rg125'::regclass and child <> :'rg_mono'),
  (select array_agg(g) from generate_series(1::bigint, 2000) g),
  'the fine children handed the strategy every row 1..2000 exactly once, the source''s prefix included');
select is((select array_agg(id order by id) from public.rg125 where id in (1, 100, 1000, 2000, 20000)), array[20000::bigint],
  'the aged rows are gone, archived first; the frontier row stays');

-- ======================= case B: the rename procedure as v0.6.0 documented it =======================
-- Same shape, partly archived, then renamed with pgpm.part.child_name updated "and nothing else". The
-- old name's chunk is now coverage nothing tracks, over a range the renamed partition holds.
create table public.rn125 (id bigint primary key, payload text);
insert into public.rn125 select g, repeat('x', 100) from generate_series(1, 2000) g;
call pgpm.transmute('public.rn125', 'id', 1000, p_retain => 1000::bigint, p_paused => false);
insert into public.rn125 values (20000, 'frontier');
update pgpm.config set archive_byte_budget = 2000 where parent_table = 'public.rn125'::regclass;
select pgpm.set_archive_fn('public.rn125', 'pgpm_test125.recorder(regclass,name,text,text)');
select child_name as rn_mono from pgpm.part where parent_table = 'public.rn125'::regclass and lo = '0' \gset

call pgpm.maintain('public.rn125');
select hi as rn_w from pgpm.archive_ledger where parent_table = 'public.rn125'::regclass and child_name = :'rn_mono' \gset
select is((select array_agg(lo) from pgpm.archive_ledger where parent_table = 'public.rn125'::regclass and child_name = :'rn_mono'),
  array['0'], 'LIVENESS: the partition is partly archived, one chunk at lo 0 under its old name');

begin;
select format('alter table public.%I rename to rn125_history', :'rn_mono') \gexec
update pgpm.part set child_name = 'rn125_history' where parent_table = 'public.rn125'::regclass and child_name = :'rn_mono';
commit;

update pgpm.config set archive_byte_budget = 8 * 1024 * 1024 where parent_table = 'public.rn125'::regclass;
call pgpm.maintain('public.rn125');
call pgpm.maintain('public.rn125');
call pgpm.maintain('public.rn125');

select is((select array_agg(distinct action) from pgpm.log where parent_table = 'public.rn125'::regclass
            and action in ('fail_write_block_identity', 'fail_archive_identity', 'fail_retain_identity')),
  null, 'LIVENESS: no identity check objected: a rename keeps the oid pgpm.part recorded');
select is((select array_agg(distinct method) from pgpm.log where parent_table = 'public.rn125'::regclass and action = 'skip_archive'),
  null, 'no archive tick failed after the old rename procedure');
select is((select array_agg(format('%s %s %s', lo, hi, rows)) from pgpm.log
            where parent_table = 'public.rn125'::regclass and action = 'archive_coverage_reset'),
  array[format('0 %s 1', :'rn_w')],
  'the tick found the old name''s one chunk over a range the renamed partition holds, and discarded it');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rn125'::regclass and action = 'retain_drop' and lo = '0'),
  'the renamed partition finished archiving and was retired');
select is((select array_agg(id order by id) from pgpm_test125.handed where child = 'rn125_history'),
  (select array_agg(g) from generate_series(1::bigint, 2000) g),
  'archiving started over from lo under the new name: every row 1..2000 handed exactly once under it');
select is((select array_agg(id order by id) from public.rn125 where id in (1, 1000, 2000, 20000)), array[20000::bigint],
  'its rows are gone, archived first; the frontier row stays');

-- ======================= case C: the rename procedure as documented now =======================
-- pgpm.part.child_name AND pgpm.archive_ledger.child_name in the same transaction. Coverage stays
-- attached, so archiving resumes from the watermark rather than exporting the prefix a second time.
create table public.rk125 (id bigint primary key, payload text);
insert into public.rk125 select g, repeat('x', 100) from generate_series(1, 2000) g;
call pgpm.transmute('public.rk125', 'id', 1000, p_retain => 1000::bigint, p_paused => false);
insert into public.rk125 values (20000, 'frontier');
update pgpm.config set archive_byte_budget = 2000 where parent_table = 'public.rk125'::regclass;
select pgpm.set_archive_fn('public.rk125', 'pgpm_test125.recorder(regclass,name,text,text)');
select child_name as rk_mono from pgpm.part where parent_table = 'public.rk125'::regclass and lo = '0' \gset

call pgpm.maintain('public.rk125');
select hi as rk_w from pgpm.archive_ledger where parent_table = 'public.rk125'::regclass and child_name = :'rk_mono' \gset
select is((select array_agg(lo) from pgpm.archive_ledger where parent_table = 'public.rk125'::regclass and child_name = :'rk_mono'),
  array['0'], 'LIVENESS: the partition is partly archived, one chunk at lo 0 under its old name');
select ok(:'rk_w'::bigint > 1 and :'rk_w'::bigint < 2000,
  'LIVENESS: the chunk ends inside the data, so there is a prefix that a restart would export again');

begin;
select format('alter table public.%I rename to rk125_history', :'rk_mono') \gexec
update pgpm.part set child_name = 'rk125_history' where parent_table = 'public.rk125'::regclass and child_name = :'rk_mono';
update pgpm.archive_ledger set child_name = 'rk125_history' where parent_table = 'public.rk125'::regclass and child_name = :'rk_mono';
commit;

update pgpm.config set archive_byte_budget = 8 * 1024 * 1024 where parent_table = 'public.rk125'::regclass;
call pgpm.maintain('public.rk125');
call pgpm.maintain('public.rk125');
call pgpm.maintain('public.rk125');

select is((select array_agg(distinct method) from pgpm.log where parent_table = 'public.rk125'::regclass and action = 'skip_archive'),
  null, 'no archive tick failed after the documented rename procedure');
select is((select array_agg(format('%s %s %s', lo, hi, rows)) from pgpm.log
            where parent_table = 'public.rk125'::regclass and action = 'archive_coverage_reset'),
  null, 'and nothing was discarded: the coverage stayed attached to the partition');
select is((select array_agg(id order by id) from pgpm_test125.handed where child = 'rk125_history'),
  (select array_agg(g) from generate_series(:'rk_w'::bigint, 2000) g),
  'archiving resumed from the watermark: exactly the rows [watermark, 2000] were handed under the new name, none of the prefix again');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rk125'::regclass and action = 'retain_drop' and lo = '0'),
  'and the partition was retired');
select is((select array_agg(id order by id) from public.rk125 where id in (1, 1000, 2000, 20000)), array[20000::bigint],
  'its rows are gone, archived first; the frontier row stays');

-- ======================= case D: regrain's own transitional rename carries the coverage =======================
-- A monolith exactly one step wide ([0, 1000) of ids 1..900) is renamed onto the target grid by the first
-- regrain_step (#266), the one rename pgpm performs itself. Partly archived first, so there is coverage
-- for that rename to carry; without the carry the source's chunk sits under a name nothing tracks.
create table public.tr125 (id bigint primary key, payload text);
insert into public.tr125 select g, repeat('x', 100) from generate_series(1, 900) g;
call pgpm.transmute('public.tr125', 'id', 1000, p_retain => 1000::bigint, p_paused => false);
insert into public.tr125 values (20000, 'frontier');
update pgpm.config set archive_byte_budget = 2000 where parent_table = 'public.tr125'::regclass;
select pgpm.set_archive_fn('public.tr125', 'pgpm_test125.recorder(regclass,name,text,text)');
select child_name as tr_mono from pgpm.part where parent_table = 'public.tr125'::regclass and lo = '0' \gset

call pgpm.maintain('public.tr125');
select hi as tr_w from pgpm.archive_ledger where parent_table = 'public.tr125'::regclass and child_name = :'tr_mono' \gset
select is((select array_agg(lo) from pgpm.archive_ledger where parent_table = 'public.tr125'::regclass and child_name = :'tr_mono'),
  array['0'], 'LIVENESS: the one-step-wide source is partly archived, one chunk at lo 0 under its bare name');

select is(pgpm.regrain_step('public.tr125', :'tr_mono', '100', 500), 'prepared',
  'LIVENESS: the first regrain step prepared the run');
select child_name as tr_src from pgpm.part where parent_table = 'public.tr125'::regclass and lo = '0' \gset
select ok(:'tr_src' <> :'tr_mono' and exists (select 1 from pgpm.log where parent_table = 'public.tr125'::regclass and action = 'regrain_rename'),
  'LIVENESS: and renamed the source onto the target grid (#266), so pgpm.part now carries a different name for it');

select is((select array_agg(format('%s %s', lo, hi)) from pgpm.archive_ledger where parent_table = 'public.tr125'::regclass and child_name = :'tr_src'),
  array[format('0 %s', :'tr_w')], 'the transitional rename carried the source''s chunk to its new name');
select is((select array_agg(lo) from pgpm.archive_ledger where parent_table = 'public.tr125'::regclass and child_name = :'tr_mono'),
  null, 'and left nothing under the old one');

do $$ declare v_status text; i int := 0; begin
  loop
    v_status := pgpm.regrain_step('public.tr125',
                  (select child_name from pgpm.part where parent_table = 'public.tr125'::regclass and lo = '0' and attached),
                  '100', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or i > 300;
  end loop;
end $$;
select is((select array_agg(id order by id) from public.tr125 where id in (1, 900, 20000)), array[1::bigint, 900, 20000],
  'LIVENESS: the regrain swapped with the rows intact');
select is((select array_agg(format('%s %s %s', lo, hi, rows)) from pgpm.log
            where parent_table = 'public.tr125'::regclass and action = 'archive_coverage_reset'),
  array['0 1000 1'], 'the swap retired the carried chunk with the source, logged once over the source''s range');
-- The first fine child, [0, 100), takes the bare name the rename freed: the source's OLD name. Coverage
-- left under that name is not an orphan the archive step's discard can see (the name IS tracked now),
-- it is a chunk recorded for a different relation sitting under a live partition's name, with only
-- #452's no-block reset between it and adoption (the unfixed code did leave it there, and that reset is
-- what saved it). The swap must leave nothing under it. What the fine children hand from here on is
-- selected by sequence, not by name, because the bare name is shared with the old source.
select coalesce(max(seq), 0) as tr_seq from pgpm_test125.handed \gset
select is((select array_agg(lo) from pgpm.archive_ledger where parent_table = 'public.tr125'::regclass and child_name = :'tr_mono'),
  null, 'the fine child that took the source''s freed bare name starts with no coverage under it');

update pgpm.config set archive_byte_budget = 8 * 1024 * 1024 where parent_table = 'public.tr125'::regclass;
do $$ declare i int := 0; v_status text; begin
  while i < 40 and exists (select 1 from pgpm.part where parent_table = 'public.tr125'::regclass and hi::bigint <= 1000) loop
    call pgpm.maintain('public.tr125', v_status);
    i := i + 1;
  end loop;
end $$;
select is((select array_agg(distinct method) from pgpm.log where parent_table = 'public.tr125'::regclass and action = 'skip_archive'),
  null, 'no archive tick failed across the transitional rename and the swap');
select is((select array_agg(lo order by lo::bigint) from pgpm.part where parent_table = 'public.tr125'::regclass and hi::bigint <= 1000),
  null, 'every fine child of [0, 1000) was archived and retired');
select is((select array_agg(id order by id) from pgpm_test125.handed
            where parent = 'public.tr125'::regclass and seq > :'tr_seq'),
  (select array_agg(g) from generate_series(1::bigint, 900) g),
  'after the swap the fine children handed the strategy every row 1..900 exactly once, ids 1..15 the source had already exported included');

select * from finish();

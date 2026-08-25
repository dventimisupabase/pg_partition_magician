-- End-to-end: pgpm.transmute() dispatching to the new text_time control kind for a classic-cuid-shaped
-- TEXT primary key. Mirrors tests/12 (uuidv7 kind) and tests/85 (#325's frontier-drought guard) for the
-- new kind, since text_time inherits the EXACT same data-driven-frontier risk uuidv7 had pre-#325 and
-- must not regress it.
create extension if not exists pgtap;

select plan(7);

create table public.tt_search (id text primary key, body text);
insert into public.tt_search (id, body) values
  (pgpm._ts_to_text_time(now() - interval '13 months', 'c', 8, 36, 'ms'), 'oldest'),
  (pgpm._ts_to_text_time(now() - interval '11 months', 'c', 8, 36, 'ms'), 'newest');

create temporary table _before_tt as select count(*) as n from public.tt_search;

-- refusals, checked before anything is touched
select throws_like(
  $$ call pgpm.transmute('public.tt_search', 'id', interval '1 month') $$,
  'pg_partition_magician:%text_time needs p_tt_prefix%',
  'transmute refuses a text control column when the text_time encoding params are omitted'
);

select throws_like(
  $$ call pgpm.transmute('public.tt_search', 'id', interval '1 month',
       p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 99, p_tt_unit => 'ms') $$,
  'pg_partition_magician:%p_tt_radix must be 2-36%',
  'transmute refuses an out-of-range p_tt_radix'
);

call pgpm.transmute('public.tt_search', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');

select is(
  (select control_kind from pgpm.config where parent_table = 'public.tt_search'::regclass),
  'text_time', 'config: control_kind = text_time'
);

select is(
  (select relkind::text from pg_class where relname = 'tt_search' and relnamespace = 'public'::regnamespace),
  'p', 'tt_search is a partitioned table'
);

select is(
  (select count(*) from public.tt_search)::bigint,
  (select n from _before_tt)::bigint, 'row count conserved across the text_time migration'
);

select pgpm.resume('public.tt_search');
call pgpm.maintain('public.tt_search');

-- the #325 property: an 11-month-stale backfill must not wedge the forward grid.
select ok(
  exists (
    select 1 from pgpm.part
     where parent_table = 'public.tt_search'::regclass and attached
       and lo::timestamptz <= now() and hi::timestamptz > now()
  ),
  'a partition covers now() after one maintenance tick, despite an 11-month-stale data frontier'
);

select lives_ok(
  $$ insert into public.tt_search (id, body)
       values (pgpm._ts_to_text_time(now(), 'c', 8, 36, 'ms'), 'live') $$,
  'a fresh cuid-shaped row stamped at now() is accepted, not refused with "no partition ... found for row"'
);

select * from finish();

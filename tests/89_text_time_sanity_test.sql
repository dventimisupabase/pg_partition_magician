-- Verifies the text_time sanity heuristic (mirrors tests/13 + tests/39 for uuidv7): genuine cuid-shaped
-- text samples as plausible, a column with no relation to that shape samples as implausible and
-- transmute refuses it by default, and p_force_text_time overrides a column the sampling misjudges
-- (shape-valid, just an implausibly old timestamp) while an actually-wrong shape stays refused.
create extension if not exists pgtap;

select plan(5);

create table public.tts_genuine (id text primary key, body text);
insert into public.tts_genuine (id, body)
select pgpm._ts_to_text_time(now() - (g || ' hours')::interval, 'c', 8, 36, 'ms'), 'x'
from generate_series(1, 500) g;

select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tts_genuine', 'id', 'c', 8, 36, 'ms', 500)),
  '>=', 0.95::numeric,
  'genuine cuid-shaped column passes the sanity check'
);

-- a column with no relation to the declared shape at all (wrong prefix, wrong width)
create table public.tts_junk (id text primary key, body text);
insert into public.tts_junk (id, body)
select gen_random_uuid()::text, 'x' from generate_series(1, 500);

select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tts_junk', 'id', 'c', 8, 36, 'ms', 500)),
  '<', 0.5::numeric,
  'a column matching none of the declared text_time shape is flagged by the sanity check'
);

select throws_like(
  $$ call pgpm.transmute('public.tts_junk', 'id', interval '1 month',
       p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms') $$,
  'pg_partition_magician:%text_time%',
  'transmute refuses a column that samples as not matching the declared text_time shape'
);

-- shape-valid but an implausibly OLD timestamp: samples as implausible, yet the grid itself is
-- perfectly ordinary, so p_force_text_time is exactly the case it exists for.
create table public.tts_old (id text primary key, body text);
insert into public.tts_old (id, body)
select pgpm._ts_to_text_time(timestamptz '1990-01-01' + (g || ' hours')::interval, 'c', 8, 36, 'ms'), 'x'
from generate_series(1, 200) g;

select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tts_old', 'id', 'c', 8, 36, 'ms', 200)),
  '<', 0.5::numeric,
  'setup: a shape-valid but OLD text_time column still samples as implausible'
);

call pgpm.transmute('public.tts_old', 'id', interval '1 month',
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms', p_force_text_time => true);
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'tts_old'),
  'p', 'p_force_text_time => true overrides the sampling refusal and converts it'
);

select * from finish();

-- Proves the kind-dispatch layer (_encode/_decode/_grid_floor/_grid_next/_part_name) handles
-- 'text_time' correctly, still without going anywhere near pgpm.config or transmute -- those come
-- next. Grid math needs no new parameters at all: once _decode has produced a native timestamptz,
-- _grid_floor/_grid_next/_part_name already treat 'text_time' exactly like 'time'/'uuidv7' (same
-- calendar arithmetic), so this is really proving that extension, not new logic.
create extension if not exists pgtap;

select plan(6);

-- a realistic classic-cuid-shaped config: prefix 'c', 8 base36 digits, milliseconds.
select is(
  pgpm._decode('text_time', pgpm._ts_to_text_time(timestamptz '2026-03-15 12:00:00+00', 'c', 8, 36, 'ms'),
               'c', 8, 36, 'ms'),
  timestamptz '2026-03-15 12:00:00+00'::text,
  '_decode(text_time, ...) round-trips through the kind dispatcher, not just the raw codec (tests/86)'
);

select is(
  pgpm._encode('text_time', timestamptz '2026-03-15 12:00:00+00'::text, 'c', 8, 36, 'ms'),
  pgpm._ts_to_text_time(timestamptz '2026-03-15 12:00:00+00', 'c', 8, 36, 'ms'),
  '_encode(text_time, ...) matches the raw codec through the kind dispatcher'
);

select is(
  pgpm._grid_floor('text_time', '1 month', '2000-01-01 00:00:00+00', timestamptz '2026-03-15 12:00:00+00'::text),
  timestamptz '2026-03-01 00:00:00+00'::text,
  'grid_floor treats text_time as calendar-aligned, identically to time/uuidv7'
);

select is(
  pgpm._grid_next('text_time', '1 month',
    pgpm._grid_floor('text_time', '1 month', '2000-01-01 00:00:00+00', timestamptz '2026-03-15 12:00:00+00'::text)),
  timestamptz '2026-04-01 00:00:00+00'::text,
  'grid_next steps text_time forward by one calendar month'
);

select is(
  pgpm._part_name('events', 'text_time', '1 month', timestamptz '2026-03-01 00:00:00+00'::text),
  'events_p2026_03',
  'part_name formats a text_time child the same way as time/uuidv7 (calendar label, not the raw id)'
);

-- the ceiling guard (tests/86 proved it in the raw codec) must survive dispatch through _encode too,
-- since that is what obtain()'s exception handler actually calls.
select throws_ok(
  $$ select pgpm._encode('text_time', timestamptz '1970-01-01 00:00:01.296+00'::text, 'c', 2, 36, 'ms') $$,
  '22003', NULL,
  '_encode(text_time, ...) surfaces the overflow guard through the kind dispatcher, not just the raw codec'
);

select * from finish();

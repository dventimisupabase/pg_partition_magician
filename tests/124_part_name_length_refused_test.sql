-- Issue #510: pgpm._part_name cast <rel>_p<label> to name, which silently truncates to 63 bytes, and its own
-- comment called that cosmetic because pgpm.part holds the bounds. But obtain decides whether a forward
-- candidate already exists BY NAME (to_regclass on _part_name's result), so once the table's name was long
-- enough for the label to be cut, every candidate rendered the same 63 bytes, the monolith took that name at
-- transmute, and every forward cell was skipped as "already exists": no forward grid at transmute, none on
-- any tick, nothing logged, and the first write past the monolith's hi failed with PostgreSQL's "no partition
-- of relation found for row". One byte longer and the truncated monolith name equalled the truncated staging
-- name <rel>_pgpm_new, so the cutover's RENAME failed after phases 1 and 2 had committed. Same root cause: a
-- name derived from the table's was truncated and then used as an identity.
--
-- The fix is a contract, not a workaround: pgpm never truncates a name it derives from the table's.
-- _part_name refuses (a pg_partition_magician: error naming the offending name, its length and the bytes to
-- shorten by) instead of casting through name; transmute refuses the staging name the same way, up front,
-- before anything is committed; set_regrain refuses a target step whose fine names would not fit, at call
-- time, instead of letting every tick raise the same error from regrain_step. The boundary is pinned from
-- both sides throughout: a name of exactly 63 bytes is rendered whole and a 64-byte one is refused, and each
-- refusal is paired with the same shape one byte shorter converting and building its forward grid.
create extension if not exists pgtap;
select plan(35);
set timezone = 'UTC';

-- exact-length relation names (the digits in a name are decoration; the length is what matters)
\set rel60 a_table_name_that_is_sixty_characters_long_for_sure_yes_it_i
\set rel55 yearly_grid_whose_staging_name_is_one_byte_too_long_xxx
\set rel54 fine_month_label_fits_at_exactly_sixty_three_bytes_xxx
\set rel52 monthly_ok_but_daily_regrain_names_would_not_fit_xxx
\set rel44 coarse_month_name_one_byte_over_the_limit_xx
\set rel43 coarse_month_monolith_fits_exactly_sixty3_x
\set rel42 id_fine_name_fits_at_sixty_three_bytes_xxx
\set rel19 id_coarse_fits_at63

-- ============================================== (A) _part_name: the 63-byte boundary from both sides
-- 54 + 2 + 7 = 63: the last relation name whose fine monthly name fits
select is(
  pgpm._part_name(:'rel54', 'time', '1 month', '2026-01-01 00:00:00+00', null, 'UTC')::text,
  :'rel54' || '_p2026_01',
  '_part_name renders a 63-byte fine name whole');
select is(
  octet_length(pgpm._part_name(:'rel54', 'time', '1 month', '2026-01-01 00:00:00+00', null, 'UTC')::text),
  63, 'LIVENESS: that fine name is exactly 63 bytes, the identifier limit');
-- one byte longer is refused, naming the name, its length and how much to shorten by; never truncated
select throws_like(
  format($$ select pgpm._part_name(%L, 'time', '1 month', '2026-01-01 00:00:00+00', null, 'UTC') $$, :'rel55'),
  'pg_partition_magician:%' || :'rel55' || '_p2026_01%64 bytes%63-byte%1 byte%',
  '_part_name refuses a 64-byte fine name, naming it, its 64 bytes and the 1 byte to shorten by');

-- 43 + 2 + 7 + 4 + 7 = 63: the last relation name whose coarse (monolith) monthly name fits
select is(
  pgpm._part_name(:'rel43', 'time', '1 month', '2026-01-01 00:00:00+00', '2026-04-01 00:00:00+00', 'UTC')::text,
  :'rel43' || '_p2026_01_to_2026_04',
  '_part_name renders a 63-byte coarse name whole');
select throws_like(
  format($$ select pgpm._part_name(%L, 'time', '1 month', '2026-01-01 00:00:00+00', '2026-04-01 00:00:00+00', 'UTC') $$, :'rel44'),
  'pg_partition_magician:%' || :'rel44' || '_p2026_01_to_2026_04%64 bytes%63-byte%1 byte%',
  '_part_name refuses a 64-byte coarse name');

-- id grid: 42 + 2 + 19 = 63 for a fine name; 19 + 2 + 19 + 4 + 19 = 63 for a coarse one
select is(
  pgpm._part_name(:'rel42', 'id', '1000', '0', '1000', 'UTC')::text,
  :'rel42' || '_p0000000000000000000',
  '_part_name renders a 63-byte id fine name whole');
select throws_like(
  format($$ select pgpm._part_name(%L, 'id', '1000', '0', '1000', 'UTC') $$, :'rel43'),
  'pg_partition_magician:%' || :'rel43' || '_p0000000000000000000%64 bytes%',
  '_part_name refuses a 64-byte id fine name');
select is(
  pgpm._part_name(:'rel19', 'id', '1000', '0', '5000', 'UTC')::text,
  :'rel19' || '_p0000000000000000000_to_0000000000000005000',
  '_part_name renders a 63-byte id coarse name whole');

-- ============================================== (B) the issue's reproduction: a 60-character table
create table public.:rel60 (id bigint, t timestamptz not null default now(), primary key (id, t));
insert into public.:rel60 select i, now() - (i || ' days')::interval from generate_series(0, 60) i;

select is(octet_length(:'rel60'), 60, 'LIVENESS: the relation name is 60 bytes');
select is(
  octet_length(:'rel60' || '_p' || to_char(now() at time zone 'UTC', 'YYYY_MM')), 69,
  'LIVENESS: the fine monthly name this table needs is 69 bytes, so every forward candidate used to be cut to the same 63');

-- refused up front, by the first derived name transmute checks (its staging name, 69 bytes), and nothing
-- is committed. The message is a pgpm refusal, not a phase's raw error and not a silent conversion.
select throws_like(
  format($$ call pgpm.transmute('public.%I', 't', interval '1 month', p_obtain => 3) $$, :'rel60'),
  'pg_partition_magician:%' || :'rel60' || '_pgpm_new%69 bytes%63-byte%6 byte%',
  'transmute refuses the 60-character table, naming its 69-byte staging name and the bytes to shorten by');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = :'rel60'),
  'r', 'the refusal is up front: the table is left a plain table');
select ok(
  not exists (select 1 from pgpm.config where parent_table = format('public.%I', :'rel60')::regclass)
  and not exists (select 1 from pgpm.transmute_inflight where rel = :'rel60'),
  'nothing was registered and no claim was left behind');
select is(
  (select array_agg(id order by id) from public.:rel60),
  (select array_agg(i::bigint) from generate_series(0, 60) i),
  'every row is exactly where it was (ids 0..60)');

-- the issue's own mechanism, one byte over: a 44-character name whose staging name fits (53 bytes) but
-- whose coarse monolith name <rel>_p<lo>_to_<hi> is 64. _part_name refuses it while transmute is still
-- naming the monolith, before the claim, the CHECK or any commit.
create table public.:rel44 (id bigint, t timestamptz not null default now(), primary key (id, t));
insert into public.:rel44 select i, now() - (i || ' days')::interval from generate_series(0, 60) i;
select throws_like(
  format($$ call pgpm.transmute('public.%I', 't', interval '1 month', p_obtain => 3) $$, :'rel44'),
  'pg_partition_magician:%' || :'rel44' || '_p'
    || to_char(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', (now() - interval '60 days')::text, 'UTC')::timestamptz at time zone 'UTC', 'YYYY_MM')
    || '_to_'
    || to_char(pgpm._grid_next('time', '1 month', pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', now()::text, 'UTC'), 'UTC')::timestamptz at time zone 'UTC', 'YYYY_MM')
    || '%64 bytes%63-byte%1 byte%',
  'transmute refuses the 44-character table, naming its exact 64-byte monolith name and the 1 byte to shorten by');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = :'rel44'),
  'r', 'that refusal is up front too: still a plain table');
select ok(
  not exists (select 1 from pgpm.config where parent_table = format('public.%I', :'rel44')::regclass)
  and not exists (select 1 from pgpm.transmute_inflight where rel = :'rel44'),
  'nothing was registered and no claim was left behind');

-- ============================================== (C) one byte inside the limit converts and builds its grid
-- 43-character name, 61 daily rows spanning three months: the coarse monolith name is exactly 63 bytes.
create table public.:rel43 (id bigint, t timestamptz not null default now(), primary key (id, t));
insert into public.:rel43 select i, now() - (i || ' days')::interval from generate_series(0, 60) i;
call pgpm.transmute(format('public.%I', :'rel43'), 't', interval '1 month', p_obtain => 3);

select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = :'rel43'),
  'p', 'the 43-character table converts');
-- the monolith: [floor(min), next(floor(now()))) under its full coarse name
select is(
  (select child_name::text from pgpm.part where parent_table = format('public.%I', :'rel43')::regclass
    order by lo::timestamptz limit 1),
  :'rel43' || '_p'
    || to_char(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', (now() - interval '60 days')::text, 'UTC')::timestamptz at time zone 'UTC', 'YYYY_MM')
    || '_to_'
    || to_char(pgpm._grid_next('time', '1 month', pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', now()::text, 'UTC'), 'UTC')::timestamptz at time zone 'UTC', 'YYYY_MM'),
  'the monolith carries its full coarse name');
select is(
  (select octet_length(child_name::text) from pgpm.part where parent_table = format('public.%I', :'rel43')::regclass
    order by lo::timestamptz limit 1),
  63, 'LIVENESS: and that name is exactly 63 bytes, the boundary the refusal sits on');
-- the forward grid: p_obtain = 3 cells past the monolith, each by its exact name (identity, not a count)
select is(
  (select array_agg(p.child_name::text order by p.lo::timestamptz) from pgpm.part p
    where p.parent_table = format('public.%I', :'rel43')::regclass and p.attached
      and p.lo::timestamptz >= pgpm._grid_next('time', '1 month', pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', now()::text, 'UTC'), 'UTC')::timestamptz),
  (select array_agg(:'rel43' || '_p' || to_char((date_trunc('month', now()) + make_interval(months => k)) at time zone 'UTC', 'YYYY_MM') order by k)
     from generate_series(1, 3) k),
  'the three forward cells exist, by their exact names');
-- and a write one day past the monolith's hi has a home: the first forward cell
select lives_ok(
  format($$ insert into public.%I values (1000, %L) $$, :'rel43',
         pgpm._grid_next('time', '1 month', pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', now()::text, 'UTC'), 'UTC')::timestamptz + interval '1 day'),
  'a write one day past the monolith''s hi has a partition to land in');
select is(
  (select c.relname::text from public.:rel43 r join pg_class c on c.oid = r.tableoid where r.id = 1000),
  :'rel43' || '_p' || to_char((date_trunc('month', now()) + interval '1 month') at time zone 'UTC', 'YYYY_MM'),
  'and it landed in the first forward cell, by name');

-- ============================================== (D) the staging name is held to the same contract
-- 55-character name, yearly step, every row at now(): the monolith is one step wide, so its fine name is
-- 55 + 2 + 4 = 61 bytes and fits. The staging name <rel>_pgpm_new is 64 and does not.
create table public.:rel55 (id bigint, t timestamptz not null default now(), primary key (id, t));
insert into public.:rel55 (id) select i from generate_series(1, 5) i;

select is(
  octet_length(:'rel55' || '_p' || to_char(now() at time zone 'UTC', 'YYYY')), 61,
  'LIVENESS: the partition name this table needs fits (61 bytes), so what refuses it below is not _part_name');
select is(octet_length(:'rel55' || '_pgpm_new'), 64, 'LIVENESS: its staging name is 64 bytes');
select throws_like(
  format($$ call pgpm.transmute('public.%I', 't', interval '1 year', p_obtain => 1) $$, :'rel55'),
  'pg_partition_magician:%' || :'rel55' || '_pgpm_new%64 bytes%63-byte%1 byte%',
  'transmute refuses, naming the staging name, its 64 bytes and the 1 byte to shorten by');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = :'rel55'),
  'r', 'the staging refusal is up front too: still a plain table');
select ok(
  not exists (select 1 from pgpm.config where parent_table = format('public.%I', :'rel55')::regclass),
  'nothing was registered');

-- the same shape one byte shorter: staging name 63 bytes, converts, monolith under its fine yearly name
create table public.:rel54 (id bigint, t timestamptz not null default now(), primary key (id, t));
insert into public.:rel54 (id) select i from generate_series(1, 5) i;
call pgpm.transmute(format('public.%I', :'rel54'), 't', interval '1 year', p_obtain => 1);
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = :'rel54'),
  'p', 'a 54-character table (staging name exactly 63 bytes) converts');
select is(
  (select child_name::text from pgpm.part where parent_table = format('public.%I', :'rel54')::regclass
    order by lo::timestamptz limit 1),
  :'rel54' || '_p' || to_char(now() at time zone 'UTC', 'YYYY'),
  'its one-step monolith carries its fine yearly name whole');

-- ============================================== (E) set_regrain refuses a target step whose names cannot fit
-- 52-character name on a monthly grid: fine monthly names are 61 bytes and fit; fine daily names would be
-- 52 + 2 + 10 = 64. Refused at set_regrain, not at the first tick that would have logged skip_regrain forever.
create table public.:rel52 (id bigint, t timestamptz not null default now(), primary key (id, t));
insert into public.:rel52 (id) select i from generate_series(1, 5) i;
call pgpm.transmute(format('public.%I', :'rel52'), 't', interval '1 month', p_obtain => 1);
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = :'rel52'),
  'p', 'LIVENESS: the 52-character monthly table converts (its monthly names fit)');
select throws_like(
  format($$ select pgpm.set_regrain('public.%I', '1 day') $$, :'rel52'),
  'pg_partition_magician:%' || :'rel52' || '_p'
    || (select to_char(partition_anchor::timestamptz at time zone 'UTC', 'YYYY_MM_DD') from pgpm.config where parent_table = format('public.%I', :'rel52')::regclass)
    || '%64 bytes%63-byte%1 byte%',
  'set_regrain refuses a daily target whose fine names would be 64 bytes, naming the anchor cell''s name');
select is(
  (select regrain_to from pgpm.config where parent_table = format('public.%I', :'rel52')::regclass),
  null, 'regrain_to is untouched by the refusal');
-- the same target on the 43-character table fits (43 + 2 + 10 = 55) and is accepted
select lives_ok(
  format($$ select pgpm.set_regrain('public.%I', '1 day') $$, :'rel43'),
  'set_regrain accepts a daily target whose fine names fit');
select is(
  (select regrain_to from pgpm.config where parent_table = format('public.%I', :'rel43')::regclass),
  '1 day', 'and records it');

select * from finish();

-- A RANGE partition on a text column compares under the column's COLLATION, and the bounds text_time
-- computes are ordered by base-N place value, which is bytewise. Under en_US, case is a tertiary weight
-- ('a' sorts before 'P') while base62 puts a = 36 above P = 25, so random-payload KSUIDs on an en_US
-- column do not sort in timestamp order: the guide's exact KSUID recipe failed at VALIDATE with
-- "check constraint pgpm_monolith_bound ... is violated by some row", and a small table that happened
-- to pass routed rows to the wrong month. transmute and check_text_time now verify the declared
-- alphabet orders the way place value needs UNDER THE CONTROL COLUMN'S COLLATION and refuse otherwise,
-- naming collate "C" as the fix. Single-case alphabets (cuid's 0-9a-z, ULID's Crockford upper,
-- ObjectId's hex) order the same way under both and stay convertible; the ULID half below is the
-- positive control for that.
--
-- Every negative here is paired with a witness that the condition it denies was present: the two
-- literal KSUIDs from the bug report flip order between en_US.utf8 and "C", and the fixture is shown
-- to contain rows that sort outside their own month under en_US BEFORE the refusal is checked, so
-- the test cannot pass on a lucky sample.
create extension if not exists pgtap;

select plan(19);

-- ---------------------------------------------------------------------------------------- witnesses
-- 2saK... carries the LATER timestamp (bytewise 'a' > 'P'); en_US puts it first.
select is(
  ('2saKm0v8KSvNNElXuBiHn4cxHCt' collate "en_US.utf8") < ('2sPrMA6tMjurYkk7wnGc3E1fiV6' collate "en_US.utf8"),
  true, 'witness: under en_US.utf8 the later KSUID sorts BEFORE the earlier one'
);
select is(
  ('2saKm0v8KSvNNElXuBiHn4cxHCt' collate "C") < ('2sPrMA6tMjurYkk7wnGc3E1fiV6' collate "C"),
  false, 'witness: under "C" the same pair sorts in timestamp (bytewise) order'
);

-- KSUID with a RANDOM 128-bit payload, which is what real ones carry and what tests/91's bound-shaped
-- values (payload = 0) cannot exercise. Two random() draws give 106 bits of entropy across the whole
-- payload, so the first payload-influenced digit is uniformly mixed-case.
create function public.mk_ksuid(p_ts timestamptz) returns text language sql volatile as $$
  select pgpm._radix_encode(
    floor(extract(epoch from (p_ts - timestamptz '2014-05-13 16:53:20+00'))) * power(2::numeric, 128)
      + floor(random()::numeric * power(2::numeric, 64)) * power(2::numeric, 64)
      + floor(random()::numeric * power(2::numeric, 64)),
    62, 27, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz')
$$;
-- the month the KSUID's own timestamp falls in, and that month's [lo, hi) as text_time bounds
create function public.ksuid_month(p_id text) returns timestamptz language sql stable as $$
  select date_trunc('month', pgpm._text_time_to_ts(p_id, '', 27, 62, 's',
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'))
$$;
create function public.ksuid_bound(p_ts timestamptz) returns text language sql stable as $$
  select pgpm._ts_to_text_time(p_ts, '', 27, 62, 's',
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00')
$$;

select setseed(0.456);
create table public.tt_ksuid_en (id text collate "en_US.utf8" primary key, body text);
insert into public.tt_ksuid_en (id, body)
select public.mk_ksuid(now() - interval '14 months' + (g * interval '6 hours')), 'r' || g
  from generate_series(1, 300) g;

-- rows that sort OUTSIDE their own month's [lo, hi) under en_US: the exact defect, before the refusal
create temporary table _misordered_en as
select e.id
  from public.tt_ksuid_en e
 where not ((e.id collate "en_US.utf8") >= (public.ksuid_bound(public.ksuid_month(e.id)) collate "en_US.utf8")
        and (e.id collate "en_US.utf8") <  (public.ksuid_bound(public.ksuid_month(e.id) + interval '1 month') collate "en_US.utf8"));
select cmp_ok(
  (select count(*) from _misordered_en), '>', 0::bigint,
  'witness: the en_US fixture contains rows that sort outside their own month under en_US.utf8'
);

-- --------------------------------------------------------------------- refusal on an en_US.utf8 column
select throws_like(
  $$ call pgpm.transmute('public.tt_ksuid_en', 'id', interval '1 month',
       p_tt_prefix => '', p_tt_width => 27, p_tt_radix => 62, p_tt_unit => 's',
       p_tt_alphabet => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
       p_tt_discard_bits => 128, p_tt_epoch => timestamptz '2014-05-13 16:53:20+00') $$,
  $p$pg_partition_magician: column %tt_ksuid_en.id has collation "en_US.utf8"%digit 'Z' (value 35)%digit 'a' (value 36)%alter table %tt_ksuid_en alter column id type text collate "C"%$p$,
  'transmute refuses the KSUID recipe on an en_US.utf8 column, naming the collation, the first misordered digit pair and the collate "C" remedy'
);
-- p_force_text_time overrides a sampling heuristic; this is arithmetic, so it must not override this
select throws_like(
  $$ call pgpm.transmute('public.tt_ksuid_en', 'id', interval '1 month',
       p_tt_prefix => '', p_tt_width => 27, p_tt_radix => 62, p_tt_unit => 's',
       p_tt_alphabet => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
       p_tt_discard_bits => 128, p_tt_epoch => timestamptz '2014-05-13 16:53:20+00',
       p_force_text_time => true) $$,
  'pg_partition_magician: column %tt_ksuid_en.id has collation "en_US.utf8"%collate "C"%',
  'p_force_text_time does not bypass the collation refusal'
);
select is(
  (select relkind::text from pg_class where oid = 'public.tt_ksuid_en'::regclass),
  'r', 'the refused table is left untouched (still a plain table)'
);
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt_ksuid_en', 'id', '', 27, 62, 's', 1000,
       '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00') $$,
  $p$pg_partition_magician: column %tt_ksuid_en.id has collation "en_US.utf8"%digit 'Z' (value 35)%digit 'a' (value 36)%collate "C"%$p$,
  'check_text_time reports the same refusal instead of a plausible fraction'
);

-- ------------------------------------------------- refusal on a DEFAULT-collation column (the bug report)
-- A column declared without COLLATE carries the "default" pseudo-collation, which resolves to the
-- database's own. That is the shape the report had, and the message has to name the effective locale
-- for the operator to recognise it.
select is(
  (select datcollate from pg_database where datname = current_database()),
  'en_US.utf8', 'witness: this database''s default collation is en_US.utf8 (the trigger for the defect)'
);
create table public.tt_ksuid_default (id text primary key, body text);
insert into public.tt_ksuid_default select id, body from public.tt_ksuid_en;
select throws_like(
  $$ call pgpm.transmute('public.tt_ksuid_default', 'id', interval '1 month',
       p_tt_prefix => '', p_tt_width => 27, p_tt_radix => 62, p_tt_unit => 's',
       p_tt_alphabet => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
       p_tt_discard_bits => 128, p_tt_epoch => timestamptz '2014-05-13 16:53:20+00') $$,
  'pg_partition_magician: column %tt_ksuid_default.id has collation "default" (the database default, en_US.utf8)%collate "C"%',
  'a column on the database default collation is refused with the effective locale named'
);

-- ------------------------------------------------------- the same fixture on collate "C" converts cleanly
create table public.tt_ksuid_c (id text collate "C" primary key, body text);
insert into public.tt_ksuid_c select id, body from public.tt_ksuid_en;

call pgpm.transmute('public.tt_ksuid_c', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => '', p_tt_width => 27, p_tt_radix => 62, p_tt_unit => 's',
  p_tt_alphabet => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
  p_tt_discard_bits => 128, p_tt_epoch => timestamptz '2014-05-13 16:53:20+00');

select is(
  (select relkind::text from pg_class where oid = 'public.tt_ksuid_c'::regclass),
  'p', 'collate "C": the same random-payload KSUIDs convert (the VALIDATE scan passes)'
);
-- identity, not cardinality: the converted table holds exactly the ids the en_US one does
select is(
  (select array_agg(id order by id collate "C") from public.tt_ksuid_c),
  (select array_agg(id order by id collate "C") from public.tt_ksuid_en),
  'collate "C": every id survived the conversion, by identity'
);

-- routing: fresh random-payload rows into the fine month partitions maintain creates ahead of the
-- monolith, each asserted to sit in the child whose [lo, hi) contains its own timestamp
select pgpm.resume('public.tt_ksuid_c');
call pgpm.maintain('public.tt_ksuid_c');

create temporary table _fine_c as
select child_name, lo::timestamptz as lo, hi::timestamptz as hi
  from pgpm.part where parent_table = 'public.tt_ksuid_c'::regclass and attached and lo::timestamptz > now();
select cmp_ok(
  (select count(*) from _fine_c), '>=', 2::bigint,
  'witness: at least two fine month partitions exist ahead of the monolith'
);
insert into public.tt_ksuid_c (id, body)
select public.mk_ksuid(f.lo + (f.hi - f.lo) * (k / 4.0)), 'fresh_' || f.child_name || '_' || k
  from _fine_c f cross join generate_series(0, 3) k;

create temporary table _fresh_c as
select c.id, c.body, (select relname from pg_class where oid = c.tableoid) as actual_child,
       (select f.child_name from _fine_c f where f.lo <= public.ksuid_month(c.id) and public.ksuid_month(c.id) < f.hi) as expected_child
  from public.tt_ksuid_c c where c.body like 'fresh_%';
select cmp_ok(
  (select count(*) from _fresh_c
     where not ((id collate "en_US.utf8") >= (public.ksuid_bound(public.ksuid_month(id)) collate "en_US.utf8")
            and (id collate "en_US.utf8") <  (public.ksuid_bound(public.ksuid_month(id) + interval '1 month') collate "en_US.utf8"))),
  '>', 0::bigint,
  'witness: some of the fresh rows would sort outside their own month under en_US.utf8'
);
select is(
  (select array_agg(body order by body collate "C") from _fresh_c where actual_child is distinct from expected_child),
  null,
  'collate "C": every fresh row sits in the partition whose [lo, hi) contains its own timestamp'
);

-- --------------------------------------------- positive control: ULID (Crockford upper) on en_US.utf8
-- Single-case alphabets are monotone under en_US, so nothing changes for them. Verified rather than
-- assumed: the ULIDs here carry a random 80-bit payload, and the transmute below runs the VALIDATE scan
-- over them.
create function public.mk_ulid(p_ts timestamptz) returns text language sql volatile as $$
  select pgpm._ts_to_text_time(p_ts, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ')
      || (select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ', 1 + floor(random() * 32)::int, 1), '')
            from generate_series(1, 16))
$$;
create table public.tt_ulid_en (id text collate "en_US.utf8" primary key, body text);
insert into public.tt_ulid_en (id, body)
select public.mk_ulid(now() - interval '14 months' + (g * interval '6 hours')), 'r' || g
  from generate_series(1, 300) g;
select ok(
  exists (select 1 from public.tt_ulid_en where substr(id, 11, 1) ~ '[0-9]')
  and exists (select 1 from public.tt_ulid_en where substr(id, 11, 1) ~ '[A-Z]'),
  'witness: the ULID payloads start with both digits and letters'
);
select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tt_ulid_en', 'id', '', 10, 32, 'ms', 1000, '0123456789ABCDEFGHJKMNPQRSTVWXYZ')),
  '>=', 0.95::numeric,
  'ULID on en_US.utf8: check_text_time samples it as plausible rather than refusing'
);
call pgpm.transmute('public.tt_ulid_en', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
  p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
select is(
  (select relkind::text from pg_class where oid = 'public.tt_ulid_en'::regclass),
  'p', 'ULID on en_US.utf8: converts (the VALIDATE scan passes over random payloads)'
);
select pgpm.resume('public.tt_ulid_en');
call pgpm.maintain('public.tt_ulid_en');
create temporary table _fine_u as
select child_name, lo::timestamptz as lo, hi::timestamptz as hi
  from pgpm.part where parent_table = 'public.tt_ulid_en'::regclass and attached and lo::timestamptz > now();
insert into public.tt_ulid_en (id, body)
select public.mk_ulid(f.lo + (f.hi - f.lo) * (k / 4.0)), 'fresh_' || f.child_name || '_' || k
  from _fine_u f cross join generate_series(0, 3) k;
create temporary table _fresh_u as
select u.id, u.body, (select relname from pg_class where oid = u.tableoid) as actual_child,
       (select f.child_name from _fine_u f
         where f.lo <= pgpm._text_time_to_ts(u.id, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ')
           and pgpm._text_time_to_ts(u.id, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') < f.hi) as expected_child
  from public.tt_ulid_en u where u.body like 'fresh_%';
select cmp_ok((select count(*) from _fresh_u), '>=', 8::bigint, 'witness: fresh ULID rows were inserted across the fine partitions');
select is(
  (select array_agg(body order by body collate "C") from _fresh_u where actual_child is distinct from expected_child),
  null,
  'ULID on en_US.utf8: every fresh row sits in the partition whose [lo, hi) contains its own timestamp'
);

select * from finish();

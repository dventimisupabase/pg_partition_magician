-- Schema fidelity (B5). The migrated table must carry the source's schema, not just its rows. Asserts the
-- guarantees on the partitioned PARENT: the primary key (and that it includes the control column),
-- declared secondary indexes, column defaults, NOT NULL, and CHECK constraints. (Generated columns are
-- covered in tests/timescale/db/09.) Autocommit, disposable-db.
select plan(7);

select mk_hypertable_rich('hp_fid', 30);

call pgpm.from_hypertable('hp_fid', 'ts', interval '1 month', p_paused => false);

select is(
  (select count(*)::int from pg_constraint where conrelid = 'hp_fid'::regclass and contype = 'p'),
  1, 'the primary key is present on the migrated parent');
select ok(
  exists(
    select 1 from pg_constraint con, unnest(con.conkey) as ck
     where con.conrelid = 'hp_fid'::regclass and con.contype = 'p'
       and ck = (select attnum from pg_attribute where attrelid = 'hp_fid'::regclass and attname = 'ts')),
  'the primary key includes the control column');
-- the secondary index on status carried onto the parent (transmute suffixes the carried index's name,
-- so match by its indexed column, not the exact name)
select is(
  (select count(*)::int from pg_index i
    where i.indrelid = 'hp_fid'::regclass and not i.indisprimary
      and (select attname from pg_attribute where attrelid = 'hp_fid'::regclass and attnum = i.indkey[0]) = 'status'),
  1, 'the declared secondary index (on status) carried onto the parent');
select is(
  (select pg_get_expr(adbin, adrelid) from pg_attrdef d
     join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
    where d.adrelid = 'hp_fid'::regclass and a.attname = 'status'),
  '''active''::text', 'the column default carried over');
select is(
  (select attnotnull from pg_attribute where attrelid = 'hp_fid'::regclass and attname = 'status'),
  true, 'the NOT NULL carried over');
select is(
  (select count(*)::int from pg_constraint
    where conrelid = 'hp_fid'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%amount%>=%0%'),
  1, 'the CHECK constraint (amount >= 0) carried onto the parent');
-- the cutover pre-builds the destination's indexes under temp `_pgpm_new` names (before its brief lock),
-- then adopts/renames them; none of those temp indexes should survive the swap.
select is(
  (select count(*)::int from pg_class where relkind = 'i' and relname like '%\_pgpm\_new'),
  0, 'no temporary *_pgpm_new index survives the cutover (pre-built indexes adopted/renamed cleanly)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

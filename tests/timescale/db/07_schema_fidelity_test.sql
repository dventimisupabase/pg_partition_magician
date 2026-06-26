-- Schema fidelity (B5). The migrated table must carry the source's schema, not just its rows. Asserts the
-- guarantees that hold on the partitioned PARENT: the primary key (and that it includes the control
-- column), declared secondary indexes (by name), column defaults, and NOT NULL. (Two known gaps, tracked
-- separately, are deliberately NOT asserted here: a CHECK constraint does not reach the parent, and a
-- generated column cannot be migrated at all.) Autocommit, disposable-db.
select plan(5);

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

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).

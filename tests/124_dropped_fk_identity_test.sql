-- pgpm.dropped_fk records are identity-anchored (#498). A preserve-managed incoming FK is dropped by the
-- cutover and re-added later, in another session, from what the record says. Three ways the record used
-- to say the wrong thing, each a silently wrong result rather than an error:
--
--   F5-03  `definition` was pg_get_constraintdef() as rendered in the TRANSMUTING session, which leaves
--          the referenced table unqualified whenever that session's search_path can see it. Replayed by
--          pg_cron under the default search_path, `REFERENCES orders(id)` resolves to whatever `orders`
--          means THERE: an unrelated public.orders (the key comes back against the wrong table, logged
--          restore_incoming_fk) or nothing (fail_restore_incoming_fk every tick). Now captured with the
--          search_path pinned to pg_catalog, so the referenced table is always schema-qualified.
--   F5-02  a SELF-REFERENTIAL key was recorded with referencing_table = the original table's oid, which
--          the cutover renames into the monolith child, so the restore put the key on that one partition
--          and every row routed to a forward partition escaped it. Now recorded against the new parent.
--   F5-07  the same anchor reached from the other side: when the REFERENCING table is itself transmuted
--          before the key is restored, its cutover renamed the recorded oid into its monolith child. Now
--          the cutover moves every record in which the converted table is the referencer onto its new
--          parent, and untransmute moves them back onto the restored table.
--
-- Identity, not cardinality: each contract assertion names WHICH relation carries the key (the parent,
-- conparentid = 0) and which table the recorded text references. Each negative ("the orphan is refused",
-- "the decoy has no key") is paired with the liveness that made it possible ("the restore reported one
-- key re-added and logged exactly restore_incoming_fk", "a forward partition exists for that row").
create extension if not exists pgtap;
select plan(37);

-- ===================================== F5-03: the definition is search_path-relative =====================================
create schema app;
create table app.orders (id bigint primary key, v int);
create table app.items (id bigint primary key, order_id bigint references app.orders (id));
create table public.orders (id bigint primary key, v int);   -- an unrelated table that happens to share the name
insert into app.orders values (1, 1);
insert into app.items values (10, 1);

set search_path = app, public;
call pgpm.transmute('app.orders', 'id', 1000::bigint, p_incoming_fks => 'preserve', p_paused => false);
reset search_path;

select is(current_setting('search_path'), '"$user", public',
  'LIVENESS: the restoring session has the default search_path, as a pg_cron session does');
select isnt('public.orders'::regclass, 'app.orders'::regclass,
  'LIVENESS: the decoy public.orders is a different relation from app.orders');
select is((select definition from pgpm.dropped_fk where parent_table = 'app.orders'::regclass),
  'FOREIGN KEY (order_id) REFERENCES app.orders(id)',
  'the recorded definition names the referenced table schema-qualified, whatever the capturing search_path saw');
select is(pgpm.restore_incoming_fks('app.orders'), 1, 'LIVENESS: restore_incoming_fks reported one key re-added');
select is((select action from pgpm.log where parent_table = 'app.orders'::regclass
            and action in ('restore_incoming_fk', 'fail_restore_incoming_fk') order by id desc limit 1),
  'restore_incoming_fk', 'LIVENESS: and logged exactly restore_incoming_fk');

select is((select c.confrelid::regclass from pg_constraint c
            where c.conrelid = 'app.items'::regclass and c.conname = 'items_order_id_fkey' and c.contype = 'f'),
  'app.orders'::regclass, 'the restored key references app.orders, the table it was dropped from');
select ok(not exists (select 1 from pg_constraint where confrelid = 'public.orders'::regclass and contype = 'f'),
  'and nothing references the decoy public.orders');
select lives_ok($$ insert into app.items values (11, 1) $$,
  'a row referencing app.orders id 1 (which exists) is accepted');
select throws_like($$ insert into app.items values (12, 999) $$, '%violates foreign key constraint%',
  'a row referencing a missing app.orders id is refused');

-- ===================================== F5-02: a self-referential key follows the parent =====================================
create table public.f502 (id bigint primary key, parent_id bigint references public.f502 (id), v int);
insert into public.f502 values (1, null, 1), (2, 1, 2);
call pgpm.transmute('public.f502', 'id', 1000::bigint, p_incoming_fks => 'preserve', p_paused => false);

select is((select referencing_table from pgpm.dropped_fk where parent_table = 'public.f502'::regclass),
  'public.f502'::regclass, 'the self-referential key is recorded against the new parent, not the oid the cutover renamed');
select is((select definition from pgpm.dropped_fk where parent_table = 'public.f502'::regclass),
  'FOREIGN KEY (parent_id) REFERENCES public.f502(id)', 'and its definition is schema-qualified');
select is(pgpm.restore_incoming_fks('public.f502'), 1, 'LIVENESS: restore_incoming_fks re-added one key');
select is((select action from pgpm.log where parent_table = 'public.f502'::regclass
            and action in ('restore_incoming_fk', 'fail_restore_incoming_fk') order by id desc limit 1),
  'restore_incoming_fk', 'LIVENESS: and logged exactly restore_incoming_fk');
select isnt((select child_name from pgpm.part where parent_table = 'public.f502'::regclass and attached
              and lo::numeric <= 5000 and hi::numeric > 5000),
  (select child_name from pgpm.part where parent_table = 'public.f502'::regclass and attached and lo::numeric = 0),
  'LIVENESS: id 5000 routes to a forward partition, not to the monolith');

-- the contract: the key is a constraint on the NEW PARENT (conparentid = 0 there), so every partition enforces it
select is((select c.conrelid::regclass from pg_constraint c
            where c.conname = 'f502_parent_id_fkey' and c.contype = 'f' and c.conparentid = 0),
  'public.f502'::regclass, 'the restored self-referential key is defined on the new parent, not on the monolith');
select throws_like($$ insert into public.f502 values (5000, 999999, 5) $$, '%violates foreign key constraint%',
  'a row routed to a forward partition whose parent_id matches no row is refused');
select is((select count(*)::int from public.f502 where id = 5000), 0, 'and is not in the table');
select lives_ok($$ insert into public.f502 values (5001, 1, 5) $$,
  'the same partition accepts a row whose parent_id does exist');

-- the round trip: untransmute re-adds the self-referential key against the restored table (the record now
-- names the parent, which untransmute drops, so it has to re-anchor rather than replay the oid)
create table public.f502b (id bigint primary key, parent_id bigint references public.f502b (id));
insert into public.f502b values (1, null), (2, 1);
call pgpm.transmute('public.f502b', 'id', 1000::bigint, p_incoming_fks => 'preserve', p_paused => false);
select is(pgpm.restore_incoming_fks('public.f502b'), 1, 'LIVENESS: the self-referential key was restored on the parent');
select lives_ok($$ select pgpm.untransmute('public.f502b') $$, 'untransmute a self-referencing parent');
select is((select relkind from pg_class where oid = 'public.f502b'::regclass), 'r',
  'LIVENESS: f502b is a plain table again');
select is((select c.confrelid::regclass from pg_constraint c
            where c.conrelid = 'public.f502b'::regclass and c.conname = 'f502b_parent_id_fkey' and c.contype = 'f'),
  'public.f502b'::regclass, 'the self-referential key is back on the restored table, referencing itself');
select throws_like($$ insert into public.f502b values (3, 999999) $$, '%violates foreign key constraint%',
  'and it enforces');

-- ===================================== F5-07: the referencing table is transmuted next =====================================
create table public.f507_o (id bigint primary key, v int);
create table public.f507_i (id bigint primary key, o_id bigint references public.f507_o (id));
insert into public.f507_o values (1, 1), (2, 2);
insert into public.f507_i values (1, 1);
call pgpm.transmute('public.f507_o', 'id', 1000::bigint, p_incoming_fks => 'preserve', p_paused => false);
call pgpm.transmute('public.f507_i', 'id', 1000::bigint, p_paused => false);   -- the referencing table, converted next

select is((select relkind from pg_class where oid = 'public.f507_i'::regclass), 'p',
  'LIVENESS: f507_i is a partitioned table with forward partitions for the rows below');
select is((select referencing_table from pgpm.dropped_fk where parent_table = 'public.f507_o'::regclass),
  'public.f507_i'::regclass, 'the record follows the referencing table onto its new parent');
select is(pgpm.restore_incoming_fks('public.f507_o'), 1, 'LIVENESS: restore_incoming_fks re-added one key');
select is((select action from pgpm.log where parent_table = 'public.f507_o'::regclass
            and action in ('restore_incoming_fk', 'fail_restore_incoming_fk') order by id desc limit 1),
  'restore_incoming_fk', 'LIVENESS: and logged exactly restore_incoming_fk');

-- the contract: the key is a constraint on the referencing table's NEW PARENT, so every partition enforces it
select is((select c.conrelid::regclass from pg_constraint c
            where c.conname = 'f507_i_o_id_fkey' and c.contype = 'f' and c.conparentid = 0),
  'public.f507_i'::regclass, 'the restored key is defined on f507_i, not on its monolith partition');
select throws_like($$ insert into public.f507_i values (5000, 999999) $$, '%violates foreign key constraint%',
  'a referencing row routed to a forward partition with no matching f507_o row is refused');
select is((select count(*)::int from public.f507_i where id = 5000), 0, 'and is not in the table');
select lives_ok($$ insert into public.f507_i values (5001, 2) $$,
  'the same partition accepts a row whose o_id does exist');

-- the round trip: untransmuting the REFERENCING table moves the record back onto the restored table, so the
-- referenced parent's lifecycle (suspend, restore, validate) keeps finding the key where it is
create table public.f507b_o (id bigint primary key);
create table public.f507b_i (id bigint primary key, o_id bigint references public.f507b_o (id));
insert into public.f507b_o values (1);
insert into public.f507b_i values (1, 1);
call pgpm.transmute('public.f507b_o', 'id', 1000::bigint, p_incoming_fks => 'preserve', p_paused => false);
call pgpm.transmute('public.f507b_i', 'id', 1000::bigint, p_paused => false);
select is(pgpm.restore_incoming_fks('public.f507b_o'), 1, 'LIVENESS: the key was restored on f507b_i''s parent');
select lives_ok($$ select pgpm.untransmute('public.f507b_i') $$, 'untransmute the referencing table');
select is((select relkind from pg_class where oid = 'public.f507b_i'::regclass), 'r',
  'LIVENESS: f507b_i is a plain table again');
select is((select referencing_table from pgpm.dropped_fk where parent_table = 'public.f507b_o'::regclass),
  'public.f507b_i'::regclass, 'the record follows the referencing table back onto the restored table');
select is((select c.confrelid::regclass from pg_constraint c
            where c.conrelid = 'public.f507b_i'::regclass and c.conname = 'f507b_i_o_id_fkey' and c.contype = 'f'),
  'public.f507b_o'::regclass, 'and the key it names is live on that table, referencing f507b_o''s parent');
select is(pgpm.suspend_incoming_fks('public.f507b_o', true), 1,
  'so the parent''s own lifecycle still finds the key where the record says it is');

select * from finish();

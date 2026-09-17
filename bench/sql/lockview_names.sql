-- Relation-name snapshot for bench/lock_view.sh's names_snapshot() (issue #392). Extracted to its
-- own file, rather than inlined as a `-c` string, so bench/lock_view_names_scope_demo.sh can run
-- the EXACT query the harness runs -- against a synthetic two-schema fixture -- instead of a
-- hand-copied duplicate that could silently drift from what actually ships. Invoked with
-- `psql -qtA -F, -f`, so its result is a 4-column CSV: oid,name,parent,kind.
--
-- Folding a relation to a base table takes up to two hops, not one: index -> pg_index.indrelid,
-- else toast -> its owning table (via pg_class.reltoastrelid), else itself, applied TWICE (base1
-- then base2). That is enough to walk an index on a partition's own toast table down to the
-- partition itself; a single-hop version produced 131 rows on a real 31-partition retain-drop
-- capture instead of the roughly-ten the design predicts, because every dropped partition's own
-- index and toast table (and the toast's own index) sat in one-off rows instead of joining the
-- partition's. `based` then folds that base table's own name onto its managed parent's, when
-- pgpm.part says it is a child.
--
-- managed_parent and the partition-kind `case` branch below both carry the parent's OWN schema
-- (nspname), not just its bare relname, and join on (schema, child_name) rather than child_name
-- alone (issue #392 review, finding 2). pgpm.part's key is (parent_table, child_name), not
-- (parent_table, nspname, child_name), so two managed parents that happen to share a bare relname
-- in DIFFERENT schemas (public.orders and archive.orders, say) can register children with the
-- SAME bare child_name. A bare-name join then matches one child oid against BOTH parents' rows,
-- emitting duplicate CSV rows with different `parent` labels for the same oid; the loader
-- (bench/plot_lock_view.py's `_read_names`) does `out[oid] = Relation(...)`, so whichever
-- duplicate comes last in the CSV wins, and locks fold onto the wrong parent nondeterministically.
-- Partitions live in their parent's own schema, so scoping the join on that schema as well as the
-- bare name is enough to disambiguate. bench/lock_view_names_scope_demo.sh proves this
-- discriminates: reverting the schema scoping here reproduces the duplicate rows on a synthetic
-- two-schema fixture.
with base1 as (
  select c.oid,
         coalesce(i.indrelid,
                  (select t.oid from pg_class t where t.reltoastrelid = c.oid),
                  c.oid) as b
    from pg_class c
    left join pg_index i on i.indexrelid = c.oid
   where c.oid >= 16384
),
base2 as (
  select b1.oid,
         coalesce(i2.indrelid,
                  (select t2.oid from pg_class t2 where t2.reltoastrelid = b1.b),
                  b1.b) as b
    from base1 b1
    left join pg_index i2 on i2.indexrelid = b1.b
),
based as (
  select b2.oid, pc.relname as bare_name, pn.nspname as bare_nsp,
         pn.nspname || '.' || pc.relname as qname
    from base2 b2
    join pg_class pc on pc.oid = b2.b
    join pg_namespace pn on pn.oid = pc.relnamespace
),
managed_parent as (
  select pn.nspname as parent_nsp, p.child_name,
         pn.nspname || '.' || pc.relname as qname
    from pgpm.part p
    join pg_class pc on pc.oid = p.parent_table
    join pg_namespace pn on pn.oid = pc.relnamespace
)
select c.oid,
       n.nspname || '.' || c.relname,
       coalesce(mp.qname, bd.qname, '') as parent,
       case when c.relkind = 'i' then 'index'
            when n.nspname = 'pg_toast' then 'toast'
            when exists (select 1 from pgpm.part p
                           join pg_class ppc on ppc.oid = p.parent_table
                           join pg_namespace ppn on ppn.oid = ppc.relnamespace
                          where p.child_name = c.relname and ppn.nspname = n.nspname)
              then 'partition'
            else 'other' end
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join based bd on bd.oid = c.oid
  left join managed_parent mp on mp.parent_nsp = bd.bare_nsp and mp.child_name = bd.bare_name
 where c.oid >= 16384
 order by c.oid

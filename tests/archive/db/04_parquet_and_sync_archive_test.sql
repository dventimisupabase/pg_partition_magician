-- archive.to_s3_parquet, one of the synchronous functions (issue #240: "hook" is no longer the
-- right word for these -- pgpm.hook itself is gone entirely, so this is just a plain function an
-- operator calls directly, INLINE, before dropping a partition another way; no ledger, no
-- automatic scheduling, no archive_fn involvement). Proves it still works standalone, with no hook
-- mechanism at all: called directly against two real partitions, each PUT succeeding (the function
-- itself raises on any HTTP failure), then both drop normally via pgpm.retain() -- archive_fn stays
-- unset for this table, so the drop precondition never depended on this function having been
-- called; archiving first is purely the operator's own manual discipline, same as always.
select plan(3);

call mk_archive_table('a4', 60, 10, 20, p_paused => false);   -- monolith [0, 70), premakes 4 ahead
insert into public.a4 (id, payload) values (71, 'y');    -- into [70,80)
insert into public.a4 (id, payload) values (109, 'frontier');   -- advances the frontier to 109

select mk_archive_config('a4', false);

-- boundary = grid_floor(109 - 20, 10) = 80: eligible = monolith [0,70), [70,80).
select child_name as child_0,  lo as lo_0,  hi as hi_0  from pgpm.part where parent_table = 'public.a4'::regclass and lo = '0' \gset
select child_name as child_70, lo as lo_70, hi as hi_70 from pgpm.part where parent_table = 'public.a4'::regclass and lo = '70' \gset

select lives_ok(
  format($$ select archive.to_s3_parquet('public.a4', %L, %L, %L) $$, :'child_0', :'lo_0', :'hi_0'),
  'archive.to_s3_parquet runs as a plain function call against the monolith -- no hook registration needed');

select lives_ok(
  format($$ select archive.to_s3_parquet('public.a4', %L, %L, %L) $$, :'child_70', :'lo_70', :'hi_70'),
  'and again against the second eligible partition');

select is(pgpm.retain('public.a4'), 2,
  'both partitions drop normally afterward -- archiving first is the operator''s own manual step, not tied to the drop precondition');

select * from finish();

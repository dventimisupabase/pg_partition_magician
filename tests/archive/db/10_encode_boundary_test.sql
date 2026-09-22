-- archive._pq_encode_column_data's parameter boundary (issue #408).
--
-- This function was the ONE place among the module's audited `execute format(...)` sites where a
-- text parameter reached the executed statement through a bare %s with no quoting at all: the whole
-- FROM item (p_from_sql) and the whole ORDER BY list (p_order_by), twice each, in every one of the
-- seven type branches. Nothing untrusted ever reached it -- both callers built those two strings out
-- of catalog-derived, already-%I/%L-quoted pieces -- but the guarantee lived entirely in the callers,
-- so a third caller written later inherited nothing.
--
-- The fix moves the guarantee into the signature: there is no longer a parameter that carries SQL.
-- A relation arrives as p_schema/p_table (`name`, spliced with %I), a range as p_control/p_lo/p_hi
-- (%I and %L), and an ordering as p_order_by `name[]`, quote_ident'd element by element inside the
-- function. The tests below drive a statement-terminator payload through each of those parameters in
-- turn and assert it lands as a quoted identifier or a literal, never as SQL.
--
-- Each negative is paired with its witness, because "nothing bad happened" is also what an
-- unreachable code path looks like: every refusal asserts that the error names the payload, which is
-- only true if the payload actually reached the executed statement and was quoted there, and the
-- p_lo case asserts the injected string round-trips as a DATA value, byte for byte.
select plan(12);

-- The table under test, and the table the payloads try to drop. Deliberately asymmetric (3 rows in,
-- 2 encoded values out): a lost row and a resurrected one cannot cancel in the expected bytes.
create table public.victim10 (id int);

create table public.enc10 (
  id      bigint primary key,
  ctl     text not null,
  payload text
);
insert into public.enc10 (id, ctl, payload) values
  (1, 'a', 'alpha'),
  (2, 'b', null),                                                  -- filtered out of the values payload
  (3, $q$'); drop table public.victim10; --$q$, 'injected-as-data');

-- ---------------------------------------------------------------------------
-- The FROM item is built from typed pieces, not handed in
-- ---------------------------------------------------------------------------

select is(
  archive._pq_from_item('pu"blic', 'en c10'),
  '"pu""blic"."en c10"',
  'archive._pq_from_item %I-quotes a whole-relation read, so a quote in either name cannot end the identifier');

select is(
  archive._pq_from_item('public', 'enc10', 'ctl', $q$a'b$q$, 'z'),
  '(select * from public.enc10 where ctl >= ''a''''b'' and ctl < ''z'') x',
  'and %L-quotes the range bounds, so a quote in either bound cannot end the literal');

-- ---------------------------------------------------------------------------
-- Liveness: the ordinary call still encodes, and encodes the right rows
-- ---------------------------------------------------------------------------

select is(
  archive._pq_encode_column_data(
    p_schema => 'public', p_table => 'enc10', p_col => 'payload', p_pgtype => 'text',
    p_nullable => false, p_order_by => array['id']::name[]),
  archive._pq_plain_text('alpha') || archive._pq_plain_text('injected-as-data'),
  'the ordinary call encodes exactly the two non-null payloads, in p_order_by order');

-- ---------------------------------------------------------------------------
-- Every parameter that reaches the statement is quoted there
-- ---------------------------------------------------------------------------

-- THE PAYLOAD IS SHAPED TO ACTUALLY WORK, and that is the only reason the
-- "victim10 is still there" assertion below means anything. The obvious payload
-- (`enc10"; drop table victim10; --`) does not: spliced raw it leaves an unterminated identifier,
-- so the statement fails, so its own drop rolls back with it -- and "the table survived" then
-- passes against the vulnerable code too. This one completes what it interrupts: it closes the
-- SELECT, drops the table in a second statement, and supplies a third that returns the
-- (boolean[], bytea) pair the EXECUTE ... INTO needs, so nothing errors and the drop COMMITS.
-- Verified by construction: against a copy of this module with %I weakened to %s in
-- archive._pq_from_item, this call returns 0 and victim10 is gone.
select throws_like(
  $$ select archive._pq_encode_column_data(
       p_schema => 'public',
       p_table  => $p$enc10; drop table victim10; select null::boolean[],''::bytea$p$,
       p_col => 'payload', p_pgtype => 'text', p_nullable => false) $$,
  '%victim10%does not exist%',
  'a p_table carrying a whole statement sequence is read as one (absurd) relation name, not as SQL');

select throws_like(
  $$ select archive._pq_encode_column_data(
       p_schema => 'public', p_table => 'enc10', p_col => 'payload', p_pgtype => 'text',
       p_nullable => false,
       p_order_by => array['id) ; drop table public.victim10; --']::name[]) $$,
  '%victim10%does not exist%',
  'a p_order_by element carrying a statement terminator is read as one (absurd) column name');

-- An empty p_order_by used to be unrepresentable (the parameter was a string, and 'ctid' was its
-- default); as an array it is one `'{}'` away, and the failure it would cause is an `order by` with
-- nothing after it -- a syntax error naming a generated statement nobody wrote. Refuse it by name.
select throws_like(
  $$ select archive._pq_encode_column_data(
       p_schema => 'public', p_table => 'enc10', p_col => 'payload', p_pgtype => 'text',
       p_nullable => false, p_order_by => '{}'::name[]) $$,
  '%p_order_by is empty%',
  'an empty p_order_by is refused by name, not as a syntax error in a statement the caller never sees');

select throws_like(
  $$ select archive._pq_encode_column_data(
       p_schema => 'public', p_table => 'enc10', p_col => 'payload', p_pgtype => 'text',
       p_nullable => false, p_order_by => array['id']::name[],
       p_control => 'ctl"; drop table public.victim10; --', p_lo => 'a', p_hi => 'z') $$,
  '%victim10%does not exist%',
  'a p_control carrying a statement terminator is read as one (absurd) column name');

select throws_like(
  $$ select archive._pq_encode_column_data(
       p_schema => 'public', p_table => 'enc10',
       p_col => 'payload"; drop table public.victim10; --', p_pgtype => 'text',
       p_nullable => false) $$,
  '%victim10%does not exist%',
  'and p_col, already %I-quoted before this change, still is');

-- p_lo/p_hi are values, not identifiers, so the payload must survive as DATA rather than raise: the
-- one row whose control value IS the payload comes back, byte for byte, and nothing else does.
select is(
  archive._pq_encode_column_data(
    p_schema => 'public', p_table => 'enc10', p_col => 'payload', p_pgtype => 'text',
    p_nullable => false, p_order_by => array['ctl', 'id']::name[],
    p_control => 'ctl',
    p_lo => $q$'); drop table public.victim10; --$q$,
    p_hi => $q$'); drop table public.victim10; --~$q$),
  archive._pq_plain_text('injected-as-data'),
  'a p_lo carrying a statement terminator is compared as a literal -- it matches the row that holds it');

-- Load-bearing for the p_table payload above, which really does commit its drop against a %s
-- regression. The other three identifier payloads cannot: each one's statement fails, and the
-- failure rolls back the drop it contains, so for those this assertion is belt and braces and the
-- throws_like message is what discriminates. Do not read it as five live attempts.
select has_table('public', 'victim10',
  'and the table those payloads tried to drop is still there');

-- ---------------------------------------------------------------------------
-- The contract is in the signature, so keep it there
-- ---------------------------------------------------------------------------

-- #209's gotcha: CREATE OR REPLACE cannot change an installed function's arity, so a signature
-- change that forgets its `drop function if exists` line leaves the OLD, SQL-taking overload
-- installed beside the new one -- and every one of the assertions above would keep passing against
-- the new one while callers resolved to whichever matched.
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'archive' and p.proname = '_pq_encode_column_data'),
  1, 'exactly one archive._pq_encode_column_data is installed, so no prior SQL-taking arity survives');

select is(
  (select regexp_replace(pg_get_function_arguments(p.oid), ' DEFAULT [^,]*', '', 'g')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'archive' and p.proname = '_pq_encode_column_data'),
  'p_schema name, p_table name, p_col text, p_pgtype text, p_nullable boolean, '
  || 'p_order_by name[], p_decimal_scale integer, p_decimal_bytes integer, '
  || 'p_control name, p_lo text, p_hi text',
  'and its parameters are pinned: adding one means re-reading what this boundary promises (no parameter carries SQL)');

select * from finish();

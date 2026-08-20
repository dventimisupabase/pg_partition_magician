-- An installed copy of pgpm has to be able to say what it is. Support starts with "what version is in
-- this database", and until #322 there was no way to ask: the only version string lived in
-- extension.control, which the install.sql channel never reads, so a database installed from
-- install.sql carried no version at all.
--
-- Two separate things are asserted here, because they answer different questions:
--   pgpm.version()   -- what the CODE in this database is, baked into install.sql at build time.
--   pgpm.installed   -- the HISTORY of install.sql runs. Appended once per run, and appended LAST, so
--                       a row is present only if that run reached the end of the file.
create extension if not exists pgtap;

select plan(5);

select has_function('pgpm', 'version', 'pgpm.version() exists');

-- Shaped like a semver release, not a branch name or a date. RELEASING.md makes this the same string
-- as extension.control's default_version and the git tag; test.sh checks that pairing at the file
-- level, which pgTAP cannot do from inside the database.
select matches(
  pgpm.version(),
  '^[0-9]+\.[0-9]+\.[0-9]+$',
  'pgpm.version() is a bare semver triple');

select has_table('pgpm', 'installed', 'pgpm.installed exists');

-- Identity, not cardinality: name WHICH version was recorded. A count alone would pass if install.sql
-- recorded some other version, or recorded a row on behalf of a different install.
select is(
  (select array_agg(version order by id) from pgpm.installed),
  array[pgpm.version()],
  'a fresh install records exactly one row, for exactly this version');

-- The row describes THIS server, so a template database cloned into a differently-versioned server
-- cannot pass as a native install.
select is(
  (select pg_version from pgpm.installed order by id limit 1),
  current_setting('server_version'),
  'the recorded pg_version is the server that ran install.sql');

select * from finish();

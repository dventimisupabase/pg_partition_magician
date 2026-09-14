-- pgpm.schedule()/unschedule(): a thin, explicit wrapper around pg_cron for the three jobs pgpm needs
-- (maintain_all for all tables, maintain_obtain_all on its own cadence, and the idle pgpm_detach
-- dispatch target). pgpm never schedules on its own; this is the deliberate way to turn the scheduled
-- lifecycle on. Canonical job names 'pgpm'/'pgpm_obtain'/'pgpm_detach', idempotent re-scheduling,
-- targets the current database. (The test image installs pg_cron, so the happy path is exercised here.)
create extension if not exists pgtap;

select plan(18);

select is(
  (select count(*)::int from cron.job where jobname = 'pgpm' and database = current_database()),
  0, 'no pgpm cron job before scheduling');
select is(
  (select count(*)::int from cron.job where jobname = 'pgpm_obtain' and database = current_database()),
  0, 'no pgpm_obtain cron job before scheduling');

-- p_every and p_obtain_every are given DIFFERENT values here on purpose, to prove they wire to
-- separate jobs rather than one silently defaulting from the other.
select ok(pgpm.schedule('* * * * *', '*/2 * * * *') is not null, 'schedule() returns a job id');
select is(
  (select count(*)::int from cron.job where jobname = 'pgpm' and database = current_database()),
  1, 'schedule() registers exactly one pgpm job');
select is(
  (select command from cron.job where jobname = 'pgpm' and database = current_database()),
  'call pgpm.maintain_all()', 'the pgpm job calls maintain_all()');
select is(
  (select schedule from cron.job where jobname = 'pgpm' and database = current_database()),
  '* * * * *', 'the pgpm job carries p_every, not p_obtain_every');

select is(
  (select count(*)::int from cron.job where jobname = 'pgpm_obtain' and database = current_database()),
  1, 'schedule() also registers the pgpm_obtain job');
select is(
  (select command from cron.job where jobname = 'pgpm_obtain' and database = current_database()),
  'call pgpm.maintain_obtain_all()', 'the pgpm_obtain job calls maintain_obtain_all()');
select is(
  (select schedule from cron.job where jobname = 'pgpm_obtain' and database = current_database()),
  '*/2 * * * *', 'the pgpm_obtain job carries p_obtain_every, not p_every');

-- idempotent: re-scheduling updates the jobs in place, it does not duplicate.
select ok(pgpm.schedule('*/5 * * * *', '*/10 * * * *') is not null, 're-schedule returns a job id');
select is(
  (select count(*)::int from cron.job where jobname = 'pgpm' and database = current_database()),
  1, 're-scheduling does not create a second pgpm job');
select is(
  (select schedule from cron.job where jobname = 'pgpm' and database = current_database()),
  '*/5 * * * *', 're-scheduling updates the pgpm interval in place');
select is(
  (select count(*)::int from cron.job where jobname = 'pgpm_obtain' and database = current_database()),
  1, 're-scheduling does not create a second pgpm_obtain job');
select is(
  (select schedule from cron.job where jobname = 'pgpm_obtain' and database = current_database()),
  '*/10 * * * *', 're-scheduling updates the pgpm_obtain interval in place');

-- The third job, pgpm_detach (issue #268), is idle machinery: retire() rewrites its command when a
-- REFERENCED partition needs a concurrent detach, which PostgreSQL will not run from a function. It is
-- created alongside the maintenance jobs so the operator never has to know it exists. tests/78 owns the
-- dispatch contract; here it is only that schedule()/unschedule() keep the trio in step.
select is(
  (select count(*)::int from cron.job where jobname = 'pgpm_detach' and database = current_database()),
  1, 'schedule() also registers the pgpm_detach job');
select is(
  (select command from cron.job where jobname = 'pgpm_detach' and database = current_database()),
  'select 1', 'created IDLE: it does nothing until a referenced partition needs retiring');

-- unschedule removes them, and is a no-op the second time.
select is(pgpm.unschedule(), 3, 'unschedule() removes all three jobs');
select is(pgpm.unschedule(), 0, 'unschedule() is idempotent (0 when nothing is scheduled)');

select * from finish();

-- pgpm.schedule()/unschedule(): a thin, explicit wrapper around pg_cron for the one job pgpm needs
-- (maintain_all for all tables). pgpm never schedules on its own; this is the deliberate way to turn
-- the scheduled lifecycle on. One canonical job 'pgpm', idempotent re-scheduling, targets the current
-- database. (The test image installs pg_cron, so the happy path is exercised here.)
create extension if not exists pgtap;

select plan(12);

select is(
  (select count(*)::int from cron.job where jobname = 'pgpm' and database = current_database()),
  0, 'no pgpm cron job before scheduling');

select ok(pgpm.schedule('* * * * *') is not null, 'schedule() returns a job id');
select is(
  (select count(*)::int from cron.job where jobname = 'pgpm' and database = current_database()),
  1, 'schedule() registers exactly one job');
select is(
  (select command from cron.job where jobname = 'pgpm' and database = current_database()),
  'call pgpm.maintain_all()', 'the job calls maintain_all()');
select is(
  (select schedule from cron.job where jobname = 'pgpm' and database = current_database()),
  '* * * * *', 'the job carries the requested schedule');

-- idempotent: re-scheduling updates the one job in place, it does not duplicate.
select ok(pgpm.schedule('*/5 * * * *') is not null, 're-schedule returns a job id');
select is(
  (select count(*)::int from cron.job where jobname = 'pgpm' and database = current_database()),
  1, 're-scheduling does not create a second job');
select is(
  (select schedule from cron.job where jobname = 'pgpm' and database = current_database()),
  '*/5 * * * *', 're-scheduling updates the interval in place');

-- The second job, pgpm_detach (issue #268), is idle machinery: retire() rewrites its command when a
-- REFERENCED partition needs a concurrent detach, which PostgreSQL will not run from a function. It is
-- created alongside the maintenance job so the operator never has to know it exists. tests/78 owns the
-- dispatch contract; here it is only that schedule()/unschedule() keep the pair in step.
select is(
  (select count(*)::int from cron.job where jobname = 'pgpm_detach' and database = current_database()),
  1, 'schedule() also registers the pgpm_detach job');
select is(
  (select command from cron.job where jobname = 'pgpm_detach' and database = current_database()),
  'select 1', 'created IDLE: it does nothing until a referenced partition needs retiring');

-- unschedule removes them, and is a no-op the second time.
select is(pgpm.unschedule(), 2, 'unschedule() removes both jobs');
select is(pgpm.unschedule(), 0, 'unschedule() is idempotent (0 when nothing is scheduled)');

select * from finish();

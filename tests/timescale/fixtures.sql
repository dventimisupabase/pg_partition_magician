-- Fixtures for the `from_hypertable` test track (TimescaleDB only). Helper functions stamp out
-- hypertables of known shapes so the test bodies stay declarative. Loaded once per test database.
create extension if not exists timescaledb;

-- a KEYLESS time hypertable (no PK, no unique constraint) -- the common "Timescale as a partition
-- manager" shape. After un-hypertabling it has no reusable key, so pgpm refuses it (tier-3) until the
-- keyless path lands. Used for the no-key refusal.
create or replace function mk_plain_hypertable(
  p_name text, p_rows int default 240, p_chunk interval default '1 day', p_span interval default '10 days'
) returns void language plpgsql as $$
begin
  execute format('drop table if exists %I cascade', p_name);
  execute format('create table %I (ts timestamptz not null, device_id bigint, temp double precision)', p_name);
  perform create_hypertable(p_name, 'ts', chunk_time_interval => p_chunk);
  execute format($i$insert into %I (ts, device_id, temp)
    select now() - %L::interval + (g * (%L::interval / %s)), (g %% 10), random() * 100
    from generate_series(1, %s) g$i$, p_name, p_span, p_span, p_rows, p_rows);
end $$;

-- a KEYED time hypertable: UNIQUE (device_id, ts) including the time column (no PK). This is the shape
-- pgpm accepts today (Proposal B), with the control column not leading the key. device_id = g keeps the
-- pair unique.
create or replace function mk_keyed_hypertable(
  p_name text, p_rows int default 240, p_chunk interval default '1 day', p_span interval default '10 days'
) returns void language plpgsql as $$
begin
  execute format('drop table if exists %I cascade', p_name);
  execute format('create table %I (ts timestamptz not null, device_id bigint not null, temp double precision,
                  constraint %I unique (device_id, ts))', p_name, p_name || '_key');
  perform create_hypertable(p_name, 'ts', chunk_time_interval => p_chunk);
  execute format($i$insert into %I (ts, device_id, temp)
    select now() - %L::interval + (g * (%L::interval / %s)), g, random() * 100
    from generate_series(1, %s) g$i$, p_name, p_span, p_span, p_rows, p_rows);
end $$;

-- a keyed hypertable plus a drop_chunks retention policy (for retention translation).
create or replace function mk_hypertable_with_retention(
  p_name text, p_after interval default '90 days'
) returns void language plpgsql as $$
begin
  perform mk_keyed_hypertable(p_name);
  perform add_retention_policy(p_name, p_after);
end $$;

-- a keyless hypertable plus a continuous aggregate (Community image only; Apache cannot have one, but
-- the image can construct it so we can assert the refusal). For the CAGG refusal.
create or replace function mk_hypertable_cagg(p_name text) returns void language plpgsql as $$
begin
  perform mk_plain_hypertable(p_name);
  execute format($v$create materialized view %I with (timescaledb.continuous) as
    select time_bucket('1 day', ts) as bucket, count(*) as n from %I group by 1 with no data$v$,
    p_name || '_cagg', p_name);
end $$;

-- a hypertable with a second (space) dimension via add_dimension. For the multiple-dimensions refusal.
create or replace function mk_hypertable_space(p_name text) returns void language plpgsql as $$
begin
  execute format('drop table if exists %I cascade', p_name);
  execute format('create table %I (ts timestamptz not null, device_id bigint not null, temp double precision)', p_name);
  perform create_hypertable(p_name, 'ts', chunk_time_interval => interval '1 day');
  perform add_dimension(p_name, 'device_id', number_partitions => 4);
end $$;

-- full-rowset equality (both directions of EXCEPT empty), for migration fidelity checks.
create or replace function rows_equal(p_a text, p_b text) returns boolean language plpgsql as $$
declare n1 bigint; n2 bigint;
begin
  execute format('select count(*) from (select * from %s except select * from %s) d', p_a, p_b) into n1;
  execute format('select count(*) from (select * from %s except select * from %s) d', p_b, p_a) into n2;
  return n1 = 0 and n2 = 0;
end $$;

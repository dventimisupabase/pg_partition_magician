#!/usr/bin/env bash
# Disk-IO burst discriminator -- two modes, same lake:
#   MODE=throughput : sequential 1GB ctid-range chunk reads -> sustained MB/s over time.
#   MODE=iops       : random single-block ctid fetches      -> sustained IOPS over time.
# Both measure by DIRECT wall-clock timing of BOUNDED units (no pg_stat_io lag; deadline honored).
# Lake exceeds RAM so reads hit disk; many concurrent readers push toward the disk/instance cap.
# Aggregate per time-bucket = sum(units completed in bucket)/bucket_secs.
#   STABLE -> flat (gp3 volume/IOPS-bound).   BURSTING -> steps DOWN after credits deplete (a knee).
#
#   MODE=iops bench/io_burst_probe.sh
#   MODE=throughput LAKE_GB=100 bench/io_burst_probe.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
# shellcheck disable=SC1090
source ~/.pgpm-bench.env
set +a
: "${BENCH_PROJECT_REF:?}" "${BENCH_DB_PASSWORD:?}" "${BENCH_REGION:?}"

pooler_host="${BENCH_POOLER_HOST:-aws-0-${BENCH_REGION}.pooler.supabase.green}"
pw_enc="$(python3 -c 'import urllib.parse,os;print(urllib.parse.quote(os.environ["BENCH_DB_PASSWORD"],safe=""))')"
DSN="postgresql://postgres.${BENCH_PROJECT_REF}:${pw_enc}@${pooler_host}:5432/postgres?sslmode=require"

MODE="${MODE:-iops}"                 # iops | throughput
LAKE_GB="${LAKE_GB:-100}"            # must exceed RAM (64GB) so reads hit disk
BUILD_MAX_SECS="${BUILD_MAX_SECS:-480}"
MIN_GB="${MIN_GB:-80}"
WRITERS="${WRITERS:-12}"
READERS="${READERS:-12}"
SCAN_SECS="${SCAN_SECS:-360}"
CHUNK_BLK="${CHUNK_BLK:-131072}"     # throughput mode: 1GB chunks
IOPS_BATCH="${IOPS_BATCH:-500}"      # iops mode: random reads per timed batch
BUCKET="${BUCKET:-15}"
CHUNK="${CHUNK:-200000}"
OUT="${BENCH_PROBE_OUT:-$DIR/results/io_burst_probe}"; mkdir -p "$OUT"; rm -f "$OUT"/reader_*.log

q(){ psql "$DSN" -v ON_ERROR_STOP=1 -tAq -c "set statement_timeout=0" -c "$1"; }
now(){ q "select extract(epoch from clock_timestamp())::bigint"; }
sizeb(){ q "select coalesce(pg_total_relation_size('lake'),0)::bigint"; }

echo "== io_burst_probe (MODE=$MODE) : lake ${LAKE_GB}GB, ${READERS} readers x ${SCAN_SECS}s =="
echo "  $(q "select version()")  shared_buffers=$(q "select current_setting('shared_buffers')")"

q "drop table if exists lake" >/dev/null
q "create unlogged table lake (g bigint, pad text)" >/dev/null
q "create or replace procedure lake_fill(target_bytes bigint, chunk int) language plpgsql as \$\$
begin
  loop
    exit when pg_total_relation_size('lake') >= target_bytes;
    insert into lake select s, repeat(md5(s::text),32) from generate_series(1,chunk) s;
    commit;
  end loop;
end \$\$" >/dev/null
# Sequential throughput reader: 1GB ctid-range chunks.
q "create or replace procedure lake_read(dur int, cb int) language plpgsql as \$\$
declare deadline timestamptz := clock_timestamp() + make_interval(secs=>dur);
        maxblk bigint; sb bigint; eb bigint; t0 timestamptz; el float; c bigint;
begin
  set max_parallel_workers_per_gather=0; set synchronize_seqscans=off;
  select greatest(pg_relation_size('lake')/8192,cb+1) into maxblk;
  sb := (random()*(maxblk-cb))::bigint;
  loop
    exit when clock_timestamp() > deadline;
    eb := sb + cb; if eb > maxblk then sb := 0; eb := cb; end if;
    t0 := clock_timestamp();
    select count(*) into c from lake where ctid >= ('('||sb||',0)')::tid and ctid < ('('||eb||',0)')::tid;
    el := extract(epoch from clock_timestamp()-t0);
    raise notice 'SAMPLE % % %', extract(epoch from clock_timestamp())::bigint, cb*8192, round((cb*8192/1e6)/greatest(el,0.001));
    sb := eb;
  end loop;
end \$\$" >/dev/null
# Random IOPS reader: 'batch' single-block ctid fetches per timed sample.
q "create or replace procedure lake_iops(dur int, batch int) language plpgsql as \$\$
declare deadline timestamptz := clock_timestamp() + make_interval(secs=>dur);
        maxblk bigint; t0 timestamptz; el float; i int; c bigint; blk bigint;
begin
  set max_parallel_workers_per_gather=0;
  select greatest(pg_relation_size('lake')/8192,1) into maxblk;
  loop
    exit when clock_timestamp() > deadline;
    t0 := clock_timestamp();
    for i in 1..batch loop
      blk := (random()*maxblk)::bigint;
      select count(*) into c from lake where ctid = ('('||blk||',1)')::tid;   -- one random-block read
    end loop;
    el := extract(epoch from clock_timestamp()-t0);
    raise notice 'SAMPLE % % %', extract(epoch from clock_timestamp())::bigint, batch, round(batch/greatest(el,0.001));
  end loop;
end \$\$" >/dev/null

if [ "$MODE" = "iops" ]; then
  echo "== verify single-block fetch is a Tid Scan (one block) =="
  q "explain (costs off) select count(*) from lake where ctid = '(1,1)'::tid" | sed 's/^/  /'
else
  echo "== verify chunk read is a Tid Range Scan =="
  q "explain (costs off) select count(*) from lake where ctid >= '(0,0)'::tid and ctid < '($CHUNK_BLK,0)'::tid" | sed 's/^/  /'
fi

echo "== build: $WRITERS fillers -> ${LAKE_GB}GB (cap ${BUILD_MAX_SECS}s) =="
target=$(( LAKE_GB * 1000000000 )); bpids=()
for _ in $(seq 1 "$WRITERS"); do ( q "call lake_fill($target,$CHUNK)" >/dev/null 2>&1 ) & bpids+=("$!"); done
bstart=$(now)
while :; do
  sz=$(sizeb); el=$(( $(now) - bstart ))
  printf '  build: %4ds  lake=%6.1f GB\n' "$el" "$(echo "$sz/1000000000"|bc -l)"
  [ "$sz" -ge "$target" ] && break
  [ "$el" -ge "$BUILD_MAX_SECS" ] && { echo "  build cap hit"; break; }
  sleep 20
done
for p in "${bpids[@]}"; do kill "$p" 2>/dev/null || true; done; for p in "${bpids[@]}"; do wait "$p" 2>/dev/null || true; done
fin_gb=$(echo "$(sizeb)/1000000000"|bc -l)
echo "  lake built: $(printf '%.1f' "$fin_gb") GB"
if [ "$(printf '%.0f' "$fin_gb")" -lt "$MIN_GB" ]; then
  echo "  ABORT: lake < ${MIN_GB}GB (build too slow)."; q "drop table if exists lake" >/dev/null; exit 3
fi

echo "== measure ($MODE): $READERS readers x ${SCAN_SECS}s =="
mstart=$(now); rpids=()
for i in $(seq 1 "$READERS"); do
  if [ "$MODE" = "iops" ]; then ( q "call lake_iops($SCAN_SECS,$IOPS_BATCH)" >/dev/null 2>"$OUT/reader_$i.log" ) &
  else ( q "call lake_read($SCAN_SECS,$CHUNK_BLK)" >/dev/null 2>"$OUT/reader_$i.log" ) & fi
  rpids+=("$!")
done
for p in "${rpids[@]}"; do wait "$p" 2>/dev/null || true; done

echo "== aggregate over time =="
grep -h 'SAMPLE' "$OUT"/reader_*.log 2>/dev/null | awk '{print $(NF-2), $(NF-1), $NF}' > "$OUT/samples.txt" || true
MODE="$MODE" BUCKET="$BUCKET" MSTART="$mstart" WARMUP="${WARMUP:-90}" python3 - "$OUT/samples.txt" <<'PY'
import sys,os,collections
mode=os.environ["MODE"]; bucket=int(os.environ["BUCKET"]); t0=int(os.environ["MSTART"]); warm=int(os.environ["WARMUP"])
rows=[l.split() for l in open(sys.argv[1]) if l.strip()]
if not rows: print("  no samples"); sys.exit()
units=collections.defaultdict(float); perreader=collections.defaultdict(list)
for ep,u,rate in rows:
    b=(int(ep)-t0)//bucket; units[b]+=float(u); perreader[b].append(float(rate))
is_iops = (mode=="iops")
lbl = "agg_IOPS" if is_iops else "agg_MBps"
print("  {:>6}  {:>10}  {:>16}  {}".format("t_s",lbl,"per_reader",""))
ss=[]   # steady-state aggregate (post-warmup), used for the verdict to exclude cache cooldown
for b in sorted(units):
    a = units[b]/bucket if is_iops else (units[b]/1e6)/bucket
    pr=sum(perreader[b])/len(perreader[b]); tag=" (warmup, excluded)" if b*bucket < warm else ""
    if b*bucket >= warm: ss.append(a)
    print("  {:6d}  {:10.0f}  {:16.0f}{}".format(b*bucket,a,pr,tag))
unit="IOPS" if is_iops else "MB/s"
ref = "gp3 was 12000 IOPS; io2 now 32000" if is_iops else "instance baseline 1048 MB/s"
if len(ss) < 4:
    print("\n  VERDICT: INCONCLUSIVE -- too few post-warmup (>{}s) samples.".format(warm)); sys.exit()
n=len(ss); head=ss[:max(1,n//3)]; tail=ss[-max(1,n//3):]
pk=max(ss); h=sum(head)/len(head); t=sum(tail)/len(tail)
print("\n  STEADY STATE (excl. first {}s cache warmup): peak ~{:.0f} | head ~{:.0f} | tail ~{:.0f} {} | ref: {}".format(warm,pk,h,t,unit,ref))
if t < h*0.7:
    print("  VERDICT: BURSTING -- steady-state {} stepped DOWN (instance credits depleted).".format(unit))
elif is_iops and h < 14000:
    print("  VERDICT: CAPPED ~{:.0f} -- never cleared the old gp3/instance-baseline ceiling (io2 still optimizing, or instance-IOPS-bound).".format(h))
else:
    print("  VERDICT: STABLE -- steady-state {} held flat (no knee) -- io2 IOPS sustained.".format(unit))
PY

echo "== cleanup =="
q "drop table if exists lake" >/dev/null
q "drop procedure if exists lake_fill(bigint,int)" >/dev/null
q "drop procedure if exists lake_read(int,int)" >/dev/null
q "drop procedure if exists lake_iops(int,int)" >/dev/null
echo "  done."

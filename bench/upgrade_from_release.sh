#!/usr/bin/env bash
# Guard the in-place upgrade FROM A REAL RELEASED ARTIFACT: install the oldest release that has the
# transmute lifecycle, transmute a table under it with a preserve-managed incoming FK, re-run the current
# install.sql over it, and require the routine catalog to be identical to a fresh install's, with
# pgpm.schedule() resolving and one maintain tick restoring the FK.
# Run by CI (`./test.sh perf`, and `./test.sh discriminate` proves it catches its defect).
#
# THE DEFECT (issue #441). `create or replace function` with a CHANGED ARGUMENT LIST replaces nothing: it
# creates a second overload beside the first. install.sql carries a `drop function if exists <old
# signature>` line for every historical signature for exactly this reason, and four signature changes
# did not get theirs. On an install at 0.2.0, 0.3.0 or 0.4.0 the upgrade to 0.5.0 or 0.6.0 completed
# without error and pgpm.version() reported the new version, but pg_proc kept pgpm.schedule(text) beside
# pgpm.schedule(text, text) and pgpm.restore_incoming_fks(regclass) beside
# pgpm.restore_incoming_fks(regclass, bigint[]). The new parameter has a default, so the old call shape
# matches BOTH: `select pgpm.schedule()` fails with "is not unique", and so does the
# restore_incoming_fks(p_parent) call maintain() makes every tick. That one is inside a handler, so it
# lands in pgpm.log as one routine-looking `skip_restore_fk` row per tick, and a preserve-managed FK is
# never restored: RI stays off, silently, on precisely the installs that have been running longest.
#
# WHY bench/upgrade_in_place.sh CANNOT SEE IT. That guard degrades a FRESH install by dropping columns
# and upgrades it back, which is the right shape for a missing column backfill and the wrong one for a
# stale signature: a fresh install never has an old function signature to leave behind. Only a real
# older artifact does. The tag's install.sql IS the released artifact for the psql channel (the release
# bundle is the same file between a header and a COMMIT), so `git show <tag>:pgpm_core/install.sql` is
# the origin, and it is fed to psql on stdin so it needs no container path.
#
# WHY v0.2.0 AND NOT v0.1.0. 0.1.0 is the pre-transmute "adopt" release (sql/pg_partition_magician.sql):
# no transmute, no schedule, no restore_incoming_fks, no p_incoming_fks => 'preserve'. It cannot witness
# the two overloads that matter here, and an upgrade from it also leaves its seven adopt-era routines
# behind (adopt, adopt_by_id, adopt_by_uuidv7, _adopt, premake, retention, check_default), removed NAMES
# rather than overloads, so inert, and out of scope for this guard. v0.2.0 is the oldest tag with the
# whole lifecycle under test, and it carries all four stale signatures: the two above and the
# two-argument _encode/_decode that 0.3.0 widened with the text_time parameters.
#
# WHAT IT ASSERTS, and why each one is load-bearing:
#
#   0. PRECONDITION, loud: the origin artifact was obtained. CI checks out with depth 1 and no tags, so
#      the tag is fetched when missing, and a fetch or `git show` that fails is a FAIL, never a skip. A
#      guard that skipped here would be green having upgraded nothing.
#   1. LIVENESS WITNESS, the one this guard is worthless without: right after installing the origin and
#      BEFORE the upgrade, the four stale signatures are present in pg_proc, by exact identity, and none
#      of them is in the fresh oracle. Every later assertion is of the form "the upgrade removed X", and
#      all of them pass trivially against an origin that never had X (a wrong tag, a wrong path, an
#      artifact that installed something else). The origin's own pgpm.version() is checked for the
#      same reason.
#   2. LIVENESS WITNESS for the FK half: after the origin's transmute the incoming FK really is
#      suspended (pgpm.dropped_fk holds the row with restored_at null and the referencing table has no
#      FK constraint), so the post-upgrade tick has real restore work to do, not a no-op to succeed at.
#   3. The routine catalog after the upgrade is IDENTICAL to a fresh install: name, identity arguments,
#      kind (function or procedure) and result type, for every routine in schema pgpm. Differences are
#      printed BY NAME. This is the assertion the mutation breaks.
#   4. `select pgpm.schedule()` RESOLVES. This is a non-cron database, so the expected outcome is the
#      one specific "pg_cron is not installed" error, matched throws_like style; any other error, "is
#      not unique" in particular, FAILS. Never a blanket handler: that error is what proves the overload
#      resolved and execution reached the body.
#   5. One `call pgpm.maintain()` on the table transmuted under the origin completes, logs NO
#      `skip_restore_fk` row (exact action value), and DOES log `restore_incoming_fk` naming the
#      fixture's constraint, with the FK live again on the referencing table. The positive half is what
#      keeps the negative half honest: "nothing was skipped" is also true of a tick that did nothing.
#   6. Data survived BY IDENTITY (asymmetric fixture: 3 in, 1 out, 2 surviving) and the upgrade was
#      RECORDED in pgpm.installed, the same two checks upgrade_in_place.sh makes, for the same reasons.
#
# Usage: upgrade_from_release.sh <container> <db> [install.sql]
# The install path is a CONTAINER path and defaults to the real one; bench/discriminate.sh passes a
# MUTANT copy instead, to prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
FRESH="${DB}_fresh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results"        # gitignored
fail=0

# The origin. Hardcoded on purpose: this guard's claim is about upgrading from THIS release, and the
# liveness witness below checks that what got installed really is it.
ORIGIN_TAG="v0.2.0"
ORIGIN_VERSION="0.2.0"
ORIGIN_PATH="pgpm_core/install.sql"
ORIGIN_SQL="$OUT/origin-$ORIGIN_TAG.sql"

q()  { docker exec "$C" psql -U postgres -d "$1" -qtA -c "$2"; }
run() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
          psql -U postgres -d "$1" -qtA -v ON_ERROR_STOP=1 -c "$2"; }
install_into() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
                   psql -U postgres -q -d "$1" -v ON_ERROR_STOP=1 -f "$INSTALL"; }
install_origin_into() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$C" \
                          psql -U postgres -q -d "$1" -v ON_ERROR_STOP=1 -f - < "$ORIGIN_SQL"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Every routine in schema pgpm, one line each: name, identity arguments, kind (f/p) and result type. A
# LIST rather than a hash so a difference is reported by name (a stale overload reads as
# `schedule(p_every text) f bigint`, only after upgrade). prokind is "char", which `||` will not take
# without the cast; an uncast version of this query errors, returns nothing, and nothing-equals-nothing
# is a pass, which is why the oracle's line count is checked below.
ROUTINES_SQL="select proname||'('||pg_get_function_identity_arguments(oid)||') '||prokind::text||' '||coalesce(pg_get_function_result(oid), '')
              from pg_proc where pronamespace = 'pgpm'::regnamespace"
routines() { q "$1" "$ROUTINES_SQL" | LC_ALL=C sort; }

# The four signatures the origin ships and the current install.sql must drop (#441). Exact identity
# strings, in the routines() format, so a near miss cannot count as present.
STALE="_decode(p_kind text, p_colvalue text) f text
_encode(p_kind text, p_native text) f text
restore_incoming_fks(p_parent regclass) f integer
schedule(p_every text) f bigint"
N_STALE=$(printf '%s\n' "$STALE" | grep -c .)
count_present() { # <routines file>: how many of the STALE lines it contains
  printf '%s\n' "$STALE" | while read -r sig; do grep -qxF -- "$sig" "$1" && echo 1; done | grep -c 1
}

# ---------------------------------------------------------------------------- precondition: the origin
mkdir -p "$OUT"
if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$ORIGIN_TAG^{commit}" >/dev/null 2>&1; then
  echo "      tag $ORIGIN_TAG is not in this checkout (CI checks out shallow and without tags); fetching it"
  if ! out=$(git -C "$ROOT" fetch --no-tags --depth=1 origin tag "$ORIGIN_TAG" 2>&1); then
    echo "FAIL  could not fetch tag $ORIGIN_TAG; without the origin artifact this guard verifies nothing"
    printf '%s\n' "$out" | sed 's/^/      /'; exit 1
  fi
fi
if ! git -C "$ROOT" show "$ORIGIN_TAG:$ORIGIN_PATH" > "$ORIGIN_SQL" 2>/tmp/ufr_show.err || [ ! -s "$ORIGIN_SQL" ]; then
  echo "FAIL  git show $ORIGIN_TAG:$ORIGIN_PATH produced nothing; without the origin artifact this guard verifies nothing"
  sed 's/^/      /' /tmp/ufr_show.err; exit 1
fi
printf 'PASS  %-58s %s\n' "origin artifact obtained" "$ORIGIN_TAG:$ORIGIN_PATH ($(wc -c < "$ORIGIN_SQL" | tr -d ' ') bytes)"

# ---------------------------------------------------------------------------- fresh oracle
docker exec "$C" psql -U postgres -q -c "drop database if exists $FRESH" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $FRESH" >/dev/null 2>&1
if ! install_into "$FRESH" >/tmp/ufr_fresh.log 2>&1; then
  echo "FAIL  the fresh oracle install did not complete"; sed 's/^/      /' /tmp/ufr_fresh.log; exit 1
fi
routines "$FRESH" > /tmp/ufr_fresh_routines.txt
N_ORACLE=$(grep -c . /tmp/ufr_fresh_routines.txt)
if [ "$N_ORACLE" -lt 1 ]; then
  echo "FAIL  the fresh oracle lists no routines at all: the identity comparison would compare nothing"; exit 1
fi
# The oracle must be able to tell the stale shapes apart from the current ones, or assertion 3 could
# not fail on them: none of the four may be in a fresh install.
check "precondition: a fresh install has none of the $N_STALE stale signatures" "$(count_present /tmp/ufr_fresh_routines.txt)" "0"
if [ "$fail" != 0 ]; then
  echo "      the STALE list names a signature the current code still ships; fix the list before trusting anything below"; exit 1
fi

# ---------------------------------------------------------------------------- the origin, with state
docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! install_origin_into "$DB" >/tmp/ufr_origin.log 2>&1; then
  echo "FAIL  the origin install ($ORIGIN_TAG) did not complete"; sed 's/^/      /' /tmp/ufr_origin.log; exit 1
fi

# ASSERTION 1, the liveness witness. Everything below asserts the upgrade removed something; all of it
# passes against an origin that never had it.
check "the origin really is $ORIGIN_VERSION" "$(q "$DB" "select pgpm.version()")" "$ORIGIN_VERSION"
routines "$DB" > /tmp/ufr_origin_routines.txt
check "the origin carries all $N_STALE stale signatures" "$(count_present /tmp/ufr_origin_routines.txt)" "$N_STALE"
if [ "$fail" != 0 ]; then
  echo "      the origin is not what this guard thinks it is; nothing below would be evidence of anything"; exit 1
fi

# A managed table with a preserve-managed incoming FK, transmuted UNDER THE ORIGIN. Asymmetric rows: 3
# in, 1 out, so a lost insert and a resurrected delete cannot cancel into a plausible count. The FK stays
# dropped after the origin's transmute until a maintain tick restores it, and no tick runs before the
# upgrade, so the restore is the upgraded code's to do. p_obtain is small only to keep the fixture quick.
run "$DB" "create table public.ev (id bigint primary key, body text)" >/dev/null
run "$DB" "create table public.ev_child (id bigint primary key, ev_id bigint references public.ev(id))" >/dev/null
run "$DB" "insert into public.ev (id, body) values (10, 'keep-a'), (20, 'doomed'), (30, 'keep-b')" >/dev/null
run "$DB" "delete from public.ev where body = 'doomed'" >/dev/null
run "$DB" "insert into public.ev_child (id, ev_id) values (1, 10), (3, 30)" >/dev/null
if ! run "$DB" "call pgpm.transmute('public.ev', 'id', 1000::bigint, p_obtain => 2, p_paused => false, p_incoming_fks => 'preserve')" >/tmp/ufr_transmute.log 2>&1; then
  echo "FAIL  the origin's transmute did not complete"; sed 's/^/      /' /tmp/ufr_transmute.log; exit 1
fi
BODIES_BEFORE=$(q "$DB" "select string_agg(body, ',' order by body) from public.ev")

# ASSERTION 2, the FK-half liveness witness: the FK is really suspended going into the upgrade.
check "the origin recorded the FK as dropped and unrestored" \
      "$(q "$DB" "select string_agg(constraint_name || ':' || coalesce(restored_at::text, 'unrestored'), ',') from pgpm.dropped_fk where parent_table = 'public.ev'::regclass")" \
      "ev_child_ev_id_fkey:unrestored"
check "no FK is live on the referencing table before the upgrade" \
      "$(q "$DB" "select count(*) from pg_constraint where conrelid = 'public.ev_child'::regclass and contype = 'f' and conparentid = 0")" "0"

# ---------------------------------------------------------------------------- the upgrade
if ! install_into "$DB" >/tmp/ufr_upgrade.log 2>&1; then
  echo "FAIL  the in-place upgrade did not complete"; sed 's/^/      /' /tmp/ufr_upgrade.log; fail=1
fi

# ASSERTION 3. Named differences: `only after upgrade` is what a stale overload looks like.
routines "$DB" > /tmp/ufr_routines.txt
if cmp -s /tmp/ufr_fresh_routines.txt /tmp/ufr_routines.txt; then
  printf 'PASS  %-58s %s\n' "the pgpm routines match a fresh install exactly" "$N_ORACLE routines"
else
  printf 'FAIL  %-58s\n' "the pgpm routines differ from a fresh install"
  comm -23 /tmp/ufr_fresh_routines.txt /tmp/ufr_routines.txt | sed 's/^/      only in fresh:      /'
  comm -13 /tmp/ufr_fresh_routines.txt /tmp/ufr_routines.txt | sed 's/^/      only after upgrade: /'
  fail=1
fi

# ASSERTION 4. throws_like, not a blanket handler: the one error a non-cron database is entitled to
# raise is the pg_cron one, and raising it proves the call resolved. A clean return would mean pg_cron
# is present here, which is also a resolution; anything else is the defect.
if out=$(run "$DB" "select pgpm.schedule()" 2>&1); then
  printf 'PASS  %-58s %s\n' "pgpm.schedule() resolves" "scheduled (pg_cron is present): job $out"
elif printf '%s' "$out" | grep -q 'pg_partition_magician: pg_cron is not installed in this database'; then
  printf 'PASS  %-58s %s\n' "pgpm.schedule() resolves" "raised the pg_cron-not-installed error, as a non-cron database should"
else
  printf 'FAIL  %-58s %s\n' "pgpm.schedule() did not resolve" "$(printf '%s' "$out" | head -1)"
  fail=1
fi

# ASSERTION 5. The tick must complete, must not skip the restore, and must have restored, by name.
if run "$DB" "call pgpm.maintain('public.ev')" >/tmp/ufr_tick.log 2>&1; then
  printf 'PASS  %-58s %s\n' "maintain() completed after the upgrade" "$(tr -d '\n' < /tmp/ufr_tick.log)"
else
  printf 'FAIL  %-58s\n' "maintain() failed after the upgrade"; sed 's/^/      /' /tmp/ufr_tick.log; fail=1
fi
check "the tick logged no skip_restore_fk row" \
      "$(q "$DB" "select coalesce(string_agg(method, ' | ' order by id), 'none') from pgpm.log where parent_table = 'public.ev'::regclass and action = 'skip_restore_fk'")" \
      "none"
check "the tick restored the preserve-managed FK, by name" \
      "$(q "$DB" "select coalesce(string_agg(method, ',' order by id), 'none') from pgpm.log where parent_table = 'public.ev'::regclass and action = 'restore_incoming_fk'")" \
      "ev_child_ev_id_fkey"
check "the FK is live again on the referencing table" \
      "$(q "$DB" "select count(*) from pg_constraint where conrelid = 'public.ev_child'::regclass and contype = 'f' and conparentid = 0 and confrelid = 'public.ev'::regclass")" "1"

# ASSERTION 6.
check "rows survived, by identity"   "$(q "$DB" "select string_agg(body, ',' order by body) from public.ev")" "$BODIES_BEFORE"
check "the upgrade run was recorded" "$(q "$DB" "select count(*)||'/'||max(version) from pgpm.installed")" "2/$(q "$FRESH" "select pgpm.version()")"

docker exec "$C" psql -U postgres -q -c "drop database if exists $FRESH" >/dev/null 2>&1
exit "$fail"

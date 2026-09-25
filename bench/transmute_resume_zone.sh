#!/usr/bin/env bash
# Run tests/128_transmute_resume_zone_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all, and bench/day_label_utc.sh for the first sibling of this one).
#
# What THIS file guards (issue #506): a transmute resumed from a session in another zone adopts the zone
# its claimed bound was computed in, so the monolith and every later grid computation share one lattice.
# tests/128's witnesses pin that the New York and UTC lattices really differ above now(), that the first
# session really failed in phase 2 with the claim left behind, and that the re-run really RESUMED; this
# wrapper proves those witnesses would notice the adoption removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_resume_session_zone  -- the resume registers the resuming session's zone again, so the
#                                     monolith's New York bound is not a boundary in the recorded UTC
#                                     and obtain leaves a month-wide hole past it, which is #506
#
# Usage: transmute_resume_zone.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/128_transmute_resume_zone_test.sql}" \
GRID_TZ_LABEL="a resumed transmute keeps the zone its bound was computed in" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"

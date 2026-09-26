#!/usr/bin/env bash
# Run tests/126_naive_column_utc_grid_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all, and bench/day_label_utc.sh for the first sibling of this one).
#
# What THIS file guards (issue #504): a timestamp or date control column has no zone, so its grid is its
# own wall clock. transmute records partition_tz = 'UTC' for it whatever the session's zone, its day and
# hour cells are whole wall days and hours in the column's own values, and set_partition_tz refuses to
# move it. tests/126's witnesses pin that the session really was in New York, that today's 00:00Z
# boundary really reads as yesterday there, and that the two hourly cells either side of the fall-back
# really share a New York wall time; this wrapper proves those witnesses would notice the rule removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   naive_column_grid_in_session_zone  -- a naive column records the transmuting session's zone again and
#                                         set_partition_tz accepts a change for it: the date column's
#                                         monolith excludes today and VALIDATE fails, the hourly cells
#                                         collide into an empty range, and the zone change is accepted
#
# Usage: naive_column_utc_grid.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/126_naive_column_utc_grid_test.sql}" \
GRID_TZ_LABEL="a naive control column's grid is its own wall clock (UTC)" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"

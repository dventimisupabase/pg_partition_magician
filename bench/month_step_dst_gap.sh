#!/usr/bin/env bash
# Run tests/127_month_step_dst_gap_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all, and bench/day_label_utc.sh for the first sibling of this one).
#
# What THIS file guards (issue #505): _grid_next of a month boundary is the next month boundary even
# where midnight on the 1st fell in a DST gap and the boundary instant therefore reads 01:00 on the wall
# clock. tests/127 pins the pair regrain_step computes (floor of the cursor, next of that floor, floor of
# that) on America/Asuncion 2023-10 and Asia/Amman 2016-04, each with a witness that the gap really
# exists, and under two session zones; this wrapper proves those assertions would notice the snap gone.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   grid_next_month_unsnapped  -- the calendar step adds the months to the boundary's raw 01:00 wall
#                                 reading again, so next(floor(Oct)) is an hour past floor(Nov) and
#                                 regrain's consecutive sub-ranges overlap, which is #505's wedge
#
# Usage: month_step_dst_gap.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/127_month_step_dst_gap_test.sql}" \
GRID_TZ_LABEL="a month step is one lattice across a DST gap at midnight on the 1st" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"

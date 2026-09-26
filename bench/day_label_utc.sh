#!/usr/bin/env bash
# Run tests/125_day_label_utc_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same
# "the assertions were reached at all" count, so read that file's header for why a wrapper around a
# plain pgTAP file exists at all.
#
# What THIS file guards (issue #503): a fixed-step (day, week) partition is labelled by the UTC date of
# its start, in every partition_tz. Nearly every assertion in tests/125 is a negative ("no hole", "two
# different names") that a run which never set the collision up would satisfy just as well, so the file
# pins its setup with liveness witnesses (the two cell starts really share a wall date in the zone, the
# chosen Sunday really has a fall-back, the grid really crossed it), and this wrapper is what proves
# those witnesses would notice the label rule being removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   part_name_day_label_in_zone  -- day and week labels rendered as the wall date in partition_tz again,
#                                   so the two day cells straddling a fall-back share a name and obtain
#                                   skips the second, which is the permanent one-day hole of #503
#
# Usage: day_label_utc.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/125_day_label_utc_test.sql}" \
GRID_TZ_LABEL="day and week labels are the UTC date of the cell start" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"

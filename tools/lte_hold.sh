#!/bin/bash
# Manual SSH override: pause the automatic LTE power-saving schedule and
# make sure the modem is on right now. Run this while connected during an
# upload window if you want to keep working past the point where
# archive_and_clean.sh would normally switch the radio back off.
#
# Uses its own flag file, separate from archive_and_clean.sh's own
# LTE_HOLD_FLAG (which it creates/deletes around its own upload run) - see
# that script's module-level comment for why they used to share one file
# and what that broke. lte_off.sh checks both before powering the modem
# off, so it doesn't matter which one archive_and_clean.sh is currently
# using for itself.
#
# Run tools/lte_release.sh before disconnecting to resume the schedule -
# otherwise the modem stays on (and reachable) until you do. A reboot also
# clears this - /tmp is tmpfs (see mount_tmpfs.sh), so a hold never
# outlives the machine it was set on.

BASEDIR="$(dirname "$0")/.."
MANUAL_HOLD_FLAG="/tmp/rtkbase_lte_hold_manual"

touch "$MANUAL_HOLD_FLAG"
echo "Auto flight-mode schedule paused (${MANUAL_HOLD_FLAG} created)."
bash "${BASEDIR}/tools/lte_on.sh"

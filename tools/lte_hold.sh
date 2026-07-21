#!/bin/bash
# Manual SSH override: pause the automatic LTE power-saving schedule and
# make sure the modem is on right now. Run this while connected during an
# upload window if you want to keep working past the point where
# archive_and_clean.sh would normally switch the radio back off.
#
# Run tools/lte_release.sh before disconnecting to resume the schedule -
# otherwise the modem stays on (and reachable) until you do.

BASEDIR="$(dirname "$0")/.."
HOLD_FLAG="/tmp/rtkbase_lte_hold"

touch "$HOLD_FLAG"
echo "Auto flight-mode schedule paused (${HOLD_FLAG} created)."
"${BASEDIR}/tools/lte_on.sh"

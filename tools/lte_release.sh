#!/bin/bash
# Resume the automatic LTE power-saving schedule and switch the radio off
# right away. Run this right before disconnecting SSH after using
# tools/lte_hold.sh.

BASEDIR="$(dirname "$0")/.."
HOLD_FLAG="/tmp/rtkbase_lte_hold"

rm -f "$HOLD_FLAG"
echo "Auto flight-mode schedule resumed (${HOLD_FLAG} removed)."
"${BASEDIR}/tools/lte_off.sh"

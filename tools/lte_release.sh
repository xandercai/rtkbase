#!/bin/bash
# Resume the automatic LTE power-saving schedule and switch the radio off
# right away. Run this right before disconnecting SSH after using
# tools/lte_hold.sh.
#
# Only ever touches the manual flag - never archive_and_clean.sh's own
# LTE_HOLD_FLAG, which it manages entirely by itself (see that script's
# module-level comment).

BASEDIR="$(dirname "$0")/.."
MANUAL_HOLD_FLAG="/tmp/rtkbase_lte_hold_manual"

rm -f "$MANUAL_HOLD_FLAG"
echo "Auto flight-mode schedule resumed (${MANUAL_HOLD_FLAG} removed)."
bash "${BASEDIR}/tools/lte_off.sh"

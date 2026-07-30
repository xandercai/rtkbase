#!/bin/bash
# Append one instantaneous load-power sample to a per-window CSV accumulator.
# Driven once a minute by mppt_power_sample.timer; archive_and_clean.sh
# uploads and rotates the file every upload window, giving the dashboard a
# minute-resolution series to derive per-hour avg/min/max load power from -
# the every-2h point snapshots can't represent a load that jumps around.
#
# The accumulator lives in /tmp (tmpfs on these stations): no SD wear, and
# losing a partial window across a reboot is acceptable.
#
# The timer fires at second :30 of every minute, deliberately off-grid from
# mppt_charge_guard.timer and rtkbase_archive.timer (both fire at :00/:02),
# so two processes never open the same RS485 serial port at once.

BASEDIR="$(dirname "$0")/.."
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

[ -z "${mppt_port}" ] && exit 0

SAMPLE_FILE="/tmp/rtkbase_mppt_power_$(hostname).csv"

"${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/mppt_read.py" \
    --port "${mppt_port}" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}" \
  | "${BASEDIR}/venv/bin/python" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    # mppt_read already reported its own error on stderr; a missed sample
    # once in a while is fine, do not add a traceback on top of it.
    sys.exit(0)
print(d["timestamp_utc"] + "," + str(d["load_power_w"]))
' >> "${SAMPLE_FILE}"

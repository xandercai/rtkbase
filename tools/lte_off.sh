#!/bin/bash
# Turn the LTE modem's radio off / airplane mode (AT+CFUN=0), unless a
# manual SSH hold is active (see tools/lte_hold.sh). Called by
# lte_modem_off.timer at the end of each fixed online window, and by
# lte_release.sh to force an immediate off when releasing the hold (which
# clears the flag first, so the check below sees it already gone).

BASEDIR="$(dirname "$0")/.."
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

HOLD_FLAG="/tmp/rtkbase_lte_hold"
if [ -f "$HOLD_FLAG" ]; then
    echo "lte_off: hold active (${HOLD_FLAG}), leaving modem on."
    exit 0
fi

if [ -z "${modem_at_port}" ]; then
    echo "lte_off: modem_at_port is empty, nothing to do."
    exit 0
fi

"${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/lte_at.py" \
    --port "${modem_at_port}" --baudrate "${modem_baudrate:-115200}" --cmd "AT+CFUN=0"

# No radio during airplane mode, so there's nothing for Tailscale to connect
# over. Stop tailscaled itself (kills its background DERP/netcheck retry
# loop) and the watchdog that would otherwise try to bring it back up every
# cycle. lte_on.sh restarts both when the modem comes back on.
if command -v tailscale &>/dev/null; then
    systemctl stop tailscale_watchdog.timer 2>/dev/null
    systemctl stop tailscaled 2>/dev/null
fi

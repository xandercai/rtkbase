#!/bin/bash
# Turn the LTE modem's radio on (AT+CFUN=1). Called by lte_modem_on.timer
# ahead of the scheduled upload window, and by lte_hold.sh for manual
# SSH access.

BASEDIR="$(dirname "$0")/.."
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

if [ -z "${modem_at_port}" ]; then
    echo "lte_on: modem_at_port is empty, nothing to do."
    exit 0
fi

"${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/lte_at.py" \
    --port "${modem_at_port}" --baudrate "${modem_baudrate:-115200}" --cmd "AT+CFUN=1"

# Radio is back: bring tailscaled and its watchdog back up (lte_off.sh
# stopped both when entering airplane mode).
if command -v tailscale &>/dev/null; then
    systemctl start tailscaled 2>/dev/null
    systemctl start tailscale_watchdog.timer 2>/dev/null
fi

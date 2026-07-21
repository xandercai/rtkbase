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

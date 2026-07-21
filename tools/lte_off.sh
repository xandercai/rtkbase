#!/bin/bash
# Turn the LTE modem's radio off / airplane mode (AT+CFUN=0). Called at the
# end of archive_and_clean.sh once all uploads finish, and by
# lte_release.sh to resume the power-saving schedule immediately.

BASEDIR="$(dirname "$0")/.."
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

if [ -z "${modem_at_port}" ]; then
    echo "lte_off: modem_at_port is empty, nothing to do."
    exit 0
fi

"${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/lte_at.py" \
    --port "${modem_at_port}" --baudrate "${modem_baudrate:-115200}" --cmd "AT+CFUN=0"

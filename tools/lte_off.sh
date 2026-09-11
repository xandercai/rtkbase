#!/bin/bash
# Turn the LTE modem's radio off / airplane mode (AT+CFUN=0), unless a
# hold is active. Called by lte_modem_off.timer at the end of each fixed
# online window, by archive_and_clean.sh itself in upload_window mode, and
# by lte_release.sh to force an immediate off when releasing the manual
# hold (which clears its own flag first, so the check below sees it
# already gone).
#
# Two independent flags, checked side by side: HOLD_FLAG is
# archive_and_clean.sh's own, held only for the duration of its own run
# (see that script's module-level comment); MANUAL_HOLD_FLAG is set/cleared
# by tools/lte_hold.sh / lte_release.sh, the SSH override. They used to be
# the same file, which
# meant a manual hold requested while archive_and_clean.sh already owned
# the flag - the common case, since by the time a human notices the modem
# is on and manages to SSH in, that script has usually already started and
# already created it - got silently deleted the moment that run finished,
# often well before the human's session was done with it. Kept separate,
# neither side can ever delete a hold it didn't create.

BASEDIR="$(dirname "$0")/.."
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

HOLD_FLAG="/tmp/rtkbase_lte_hold"
MANUAL_HOLD_FLAG="/tmp/rtkbase_lte_hold_manual"
if [ -f "$HOLD_FLAG" ] || [ -f "$MANUAL_HOLD_FLAG" ]; then
    echo "lte_off: hold active (HOLD_FLAG=$([ -f "$HOLD_FLAG" ] && echo present || echo absent), MANUAL_HOLD_FLAG=$([ -f "$MANUAL_HOLD_FLAG" ] && echo present || echo absent)), leaving modem on."
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

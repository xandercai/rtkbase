#!/bin/bash
# tailscale_watchdog.sh
# Checks that Tailscale is connected and SSH is reachable via the Tailscale
# interface. Restarts whichever component has failed.
# Intended to be run every 5 minutes via a systemd timer.

LOG_PREFIX="$(date '+%Y-%m-%d %H:%M:%S') [tailscale-watchdog]"

BASEDIR="$(dirname "$0")/.."
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

# ── 0. Is there any internet uplink at all right now? ───────────────────────
# A client Pi behind a master's LTE share is offline most of the time (the
# master's modem sits in airplane mode between upload windows), and so is
# any station whose WiFi is out of range. Trying to bring Tailscale up then
# can only fail - and every failure lands in the uploaded journal as an
# error. Nothing to repair while offline; check again next cycle.
if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    echo "${LOG_PREFIX} No internet uplink right now, skipping this check."
    exit 0
fi

# ── 1. Is tailscaled running? ────────────────────────────────────────────────
if ! systemctl is-active --quiet tailscaled; then
    echo "${LOG_PREFIX} tailscaled is not running, restarting..."
    systemctl restart tailscaled
    sleep 10
fi

# ── 2. Is Tailscale authenticated and connected? ─────────────────────────────
TS_STATUS=$(tailscale status --json 2>/dev/null | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState',''))" 2>/dev/null)

if [ "${TS_STATUS}" != "Running" ]; then
    echo "${LOG_PREFIX} Tailscale state is '${TS_STATUS}', attempting tailscale up..."
    # Recent Tailscale versions refuse a bare "tailscale up" if the node was
    # first brought up with any non-default flag (e.g. --ssh), so recovery
    # has to repeat exactly those flags - see tailscale_up_flags in
    # settings.conf. Unquoted on purpose: it's a list of flags.
    # shellcheck disable=SC2086
    tailscale up ${tailscale_up_flags} --timeout 30s
    sleep 10
    TS_STATUS=$(tailscale status --json 2>/dev/null | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState',''))" 2>/dev/null)
fi

if [ "${TS_STATUS}" != "Running" ]; then
    echo "${LOG_PREFIX} Tailscale still not running after recovery attempt. Will retry next cycle."
    exit 1
fi

# ── 3. Is sshd running? ──────────────────────────────────────────────────────
if ! systemctl is-active --quiet ssh; then
    echo "${LOG_PREFIX} sshd is not running, restarting..."
    systemctl restart ssh
    sleep 5
fi

# ── 4. Is SSH actually reachable on the Tailscale IP? ────────────────────────
TS_IP=$(tailscale ip -4 2>/dev/null)

if [ -z "${TS_IP}" ]; then
    echo "${LOG_PREFIX} Could not determine Tailscale IP, skipping SSH check."
    exit 0
fi

if ! timeout 5 bash -c "echo > /dev/tcp/${TS_IP}/22" 2>/dev/null; then
    echo "${LOG_PREFIX} SSH port not reachable on ${TS_IP}, restarting sshd..."
    systemctl restart ssh
    sleep 5
    if ! timeout 5 bash -c "echo > /dev/tcp/${TS_IP}/22" 2>/dev/null; then
        echo "${LOG_PREFIX} SSH still unreachable after restart. Will retry next cycle."
        exit 1
    fi
fi

echo "${LOG_PREFIX} OK - Tailscale: ${TS_IP}, SSH: reachable"
exit 0

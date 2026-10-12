#!/bin/bash
# Pre-deployment self-check. Run it on site before driving out, while the
# station still has WiFi, as the rtkbase user:
#
#   ~/rtkbase/tools/field_check.sh
#
# Everything a station needs to work unattended once powered up in the
# field is checked here, so problems surface while they are still a
# one-minute fix: GNSS logging, time sync, LTE/role, Drive upload auth,
# Tailscale login (and key expiry), MPPT, storage, power supply.
# Read-only: it changes nothing. Exit code = number of FAILs.

BASEDIR="$(cd "$(dirname "$0")/.." && pwd)"
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )
source "${BASEDIR}/tools/hw_detect.sh"

fails=0 ; warns=0
pass() { printf '  \e[32mPASS\e[0m  %s\n' "$*" ; }
warn() { printf '  \e[33mWARN\e[0m  %s\n' "$*" ; warns=$((warns + 1)) ; }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*" ; fails=$((fails + 1)) ; }
section() { printf '\n\e[1m%s\e[0m\n' "$*" ; }
unit_active()  { systemctl is-active --quiet "$1" ; }
unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null ; }

section "GNSS logging"
if [ -e /dev/ttyGNSS ]; then pass "/dev/ttyGNSS -> $(readlink -f /dev/ttyGNSS)"
else fail "/dev/ttyGNSS missing - receiver unplugged, or no udev rule for it (tools/udev_rules/91-gnss.rules)"; fi
for u in str2str_tcp str2str_file; do
    unit_active "$u" && pass "$u running" || fail "$u not running (journalctl -u $u)"
done
newest=$(ls -1t "${datadir}"/*."${receiver_format:-ubx}" 2>/dev/null | head -n 1)
if [ -z "$newest" ]; then
    fail "no .${receiver_format:-ubx} file in ${datadir}"
elif [ $(( $(date +%s) - $(stat -c %Y "$newest") )) -lt 120 ]; then
    pass "recording: $(basename "$newest") ($(du -h "$newest" | cut -f1))"
else
    fail "newest raw file $(basename "$newest") hasn't grown for $(( ($(date +%s) - $(stat -c %Y "$newest")) / 60 )) min"
fi

section "Time"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then pass "system clock synchronized ($(date '+%F %T %Z'))"
else fail "system clock NOT synchronized - file names and upload windows depend on it (chronyc sources -v)"; fi

section "Network role / LTE"
role=$(current_network_role)
case "$role" in
    master) pass "role: master (LTE modem present)" ;;
    client) pass "role: client (no LTE modem)" ;;
    *)      fail "role unknown - rtkbase_network_role.timer hasn't run (systemctl status rtkbase_network_role.timer)" ;;
esac
unit_enabled rtkbase_network_role.timer || fail "rtkbase_network_role.timer not enabled"
if modem=$(resolve_modem_port); then
    pass "LTE modem AT port: ${modem}"
    for u in lte_modem_on.timer lte_modem_off.timer; do unit_enabled "$u" || fail "$u not enabled"; done
    ip -4 addr show usb0 2>/dev/null | grep -q inet \
        && pass "usb0 has an address: $(ip -4 -o addr show usb0 | awk '{print $4}')" \
        || warn "usb0 has no address right now (normal while the modem is in airplane mode between windows)"
    [ "${lte_online_minutes:-10}" -lt 15 ] && [ "${lte_share:-1}" = "1" ] \
        && warn "lte_online_minutes=${lte_online_minutes:-10}: if a client Pi shares this LTE, both uploads must fit - 15 is safer"
elif [ "$role" = "master" ]; then
    fail "role is master but no modem AT port found"
fi
if nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx lte-share-eth0; then
    pass "sharing LTE on eth0 (192.168.100.1)"
fi
wifi=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}' | paste -sd, -)
[ -n "$wifi" ] && pass "WiFi profiles (auto-connect for SSH on site): ${wifi}" \
               || warn "no WiFi profile configured - only Tailscale over LTE will give SSH access"

section "Uploads (Google Drive)"
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    if rclone lsd gdrive: --config "$HOME/.config/rclone/rclone.conf" --max-depth 1 --contimeout 15s --timeout 30s >/dev/null 2>&1; then
        pass "rclone can reach gdrive:"
    else
        fail "rclone cannot list gdrive: - token expired/missing? (rclone config reconnect gdrive:)"
    fi
else
    warn "no internet right now - Drive access not tested"
fi
unit_enabled rtkbase_archive.timer && pass "rtkbase_archive.timer enabled, next: $(systemctl list-timers rtkbase_archive.timer --no-legend | awk '{print $1, $2, $3}')" \
                                   || fail "rtkbase_archive.timer not enabled"
failed=$(cat "${BASEDIR}/logs/upload_failure_count" 2>/dev/null || echo 0)
[ "${failed:-0}" -gt 0 ] && warn "last ${failed} upload cycle(s) failed completely"

section "Remote access (Tailscale)"
if command -v tailscale >/dev/null 2>&1; then
    ts_json=$(tailscale status --json 2>/dev/null)
    state=$(echo "$ts_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)
    [ "$state" = "Running" ] && pass "Tailscale running as $(tailscale ip -4 2>/dev/null)" \
                             || fail "Tailscale state '${state:-unknown}' - run 'sudo tailscale up ${tailscale_up_flags}' and log in"
    expiry=$(echo "$ts_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("Self",{}).get("KeyExpiry",""))' 2>/dev/null)
    if [ -n "$expiry" ]; then
        days=$(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 ))
        warn "Tailscale node key expires in ${days} days - disable key expiry for this machine in the admin console, or remote access stops then"
    elif [ "$state" = "Running" ]; then
        pass "Tailscale key expiry disabled"
    fi
    unit_enabled tailscale_watchdog.timer || warn "tailscale_watchdog.timer not enabled"
else
    warn "Tailscale not installed - no remote access over LTE"
fi

section "Power / MPPT / temperature"
if command -v vcgencmd >/dev/null 2>&1; then
    throttled=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    case "$throttled" in
        0x0) pass "no undervoltage/throttling since boot" ;;
        "")  warn "could not read vcgencmd get_throttled" ;;
        *)   fail "undervoltage/throttling flagged (get_throttled=${throttled}) - supply too weak for Pi + modem? USB dropouts follow" ;;
    esac
fi
if mppt=$(resolve_mppt_port); then
    if reading=$(flock -w 20 /run/lock/rtkbase_epever485.lock "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/mppt_read.py" \
            --port "$mppt" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}" 2>&1); then
        pass "MPPT answers on ${mppt}: $(echo "$reading" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("battery %s V, SOC %s%%, battery temp %s C" % (d["battery_voltage_v"], d["battery_soc_pct"], d["battery_temperature_c"]))' 2>/dev/null)"
    else
        fail "MPPT on ${mppt} doesn't answer: ${reading}"
    fi
    unit_enabled mppt_charge_guard.timer && pass "low-temperature charge guard enabled" || fail "mppt_charge_guard.timer not enabled"
else
    warn "no MPPT adapter (/dev/epever485) - no charge guard / power data (fine if this station has none)"
fi
if find /sys/bus/w1/devices -maxdepth 1 -name '28-*' -print -quit 2>/dev/null | grep -q .; then
    pass "DS18B20: $(bash "${BASEDIR}/tools/thermal_read.sh" 2>&1)"
else
    warn "no DS18B20 found (needs to be wired at install time for the 1-Wire overlay - see settings.conf [thermal])"
fi

section "Storage / logs"
free_mb=$(df -Pm "${datadir}" | awk 'NR==2 {print $4}')
[ "$free_mb" -ge "${min_free_space:-500}" ] && pass "${free_mb} MB free on the data partition" \
                                             || fail "only ${free_mb} MB free (min_free_space=${min_free_space:-500})"
awk '$1=="tmpfs" && ($2=="/var/log" || $2 ~ /data\/?$/) {found=1} END {exit !found}' /etc/fstab \
    && fail "/etc/fstab still puts /var/log or the data dir on tmpfs - run 'sudo ./mount_tmpfs.sh' and reboot" \
    || pass "data and logs are on the SD card"
[ -d /var/log/journal ] && pass "persistent journal enabled" || warn "journal is not persistent (sudo ./mount_tmpfs.sh)"
unit_active rtkbase_web.service && warn "web UI is running (web_ui_enabled) - not needed in the field"

printf '\n%s FAIL, %s WARN\n' "$fails" "$warns"
[ "$fails" -eq 0 ] && echo "Ready for the field." || echo "Fix the FAILs before deploying."
exit "$fails"

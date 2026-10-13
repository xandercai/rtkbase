#!/bin/bash
# Pre-deployment check, run as the rtkbase user while still on WiFi:
#   ~/rtkbase/tools/field_check.sh
# Read-only. Exit code = number of FAILs.

BASEDIR="$(cd "$(dirname "$0")/.." && pwd)"
# skip settings.conf's own BASEDIR line, it would point to this script's dir
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' | grep -v '^BASEDIR=' )
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
# raw observations, i.e. the receiver was configured by install.sh
# (a new receiver usually outputs NMEA only)
if [ -n "$newest" ] && [ "${receiver_format:-ubx}" != "sbf" ]; then
    if [ "$(stat -c %s "$newest")" -lt 20000 ]; then
        warn "$(basename "$newest") too small yet to check for raw observations - run this check again in a minute"
    else
        raw=$(python3 - "$newest" "${receiver_format:-ubx}" <<'EOF'
import sys
path, fmt = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()[-300000:]
if fmt == "ubx":
    print("RXM-RAWX" if b"\xb5\x62\x02\x15" in data else "")
elif fmt == "rtcm3":
    found = set()
    i = 0
    while True:
        i = data.find(b"\xd3", i)
        if i < 0 or i + 5 > len(data):
            break
        if data[i + 1] & 0xFC == 0:
            found.add((data[i + 3] << 4) | (data[i + 4] >> 4))
        i += 1
    print(",".join(str(m) for m in sorted(found) if 1071 <= m <= 1137))
EOF
)
        [ -n "$raw" ] && pass "raw observations recorded (${raw})" \
                      || fail "no raw observations in $(basename "$newest") - receiver not configured? sudo ~/rtkbase/tools/install.sh --detect-gnss --configure-gnss --start-services"
    fi
fi

section "Time"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then pass "system clock synchronized ($(date '+%F %T %Z'))"
else fail "system clock NOT synchronized - file names and upload windows depend on it (chronyc sources -v)"; fi
if [ -f /etc/fake-hwclock.data ]; then
    saved_age_min=$(( ($(date +%s) - $(date -u -d "$(cat /etc/fake-hwclock.data)" +%s)) / 60 ))
    [ "$saved_age_min" -le 30 ] && pass "time for the next boot saved ${saved_age_min} min ago" \
                                || fail "saved boot time is ${saved_age_min} min old - is rtkbase_clock_save.timer running?"
else
    fail "no saved time (fake-hwclock) - after a power cut the clock restarts at the image date (install.sh --gpsd-chrony)"
fi
unit_enabled rtkbase_clock_save.timer || fail "rtkbase_clock_save.timer not enabled"
grep -q '^makestep 1 -1' /etc/chrony/chrony.conf \
    || warn "chrony only steps the clock during its first updates (set 'makestep 1 -1' in /etc/chrony/chrony.conf)"
gnss_reach=$(chronyc -n sources 2>/dev/null | awk '$2=="GNSS" {print $5}')
[ -n "$gnss_reach" ] && [ "$gnss_reach" != "0" ] && pass "GNSS time source reachable (chrony)" \
    || warn "GNSS time source not reachable - without network the clock can't be corrected"

section "Network role / LTE"
role=$(current_network_role)
case "$role" in
    master) pass "role: master (LTE modem present)" ;;
    client) pass "role: client (no LTE modem)" ;;
    *)
        if [ "$(systemctl show -p ActiveState --value rtkbase_network_role.service 2>/dev/null)" = "activating" ]; then
            warn "role detection still running (waits up to ${modem_wait_seconds:-60}s after boot for a modem) - run this check again in a minute"
        else
            fail "role unknown - rtkbase_network_role.timer hasn't run (systemctl status rtkbase_network_role.timer)"
        fi
        ;;
esac
unit_enabled rtkbase_network_role.timer || fail "rtkbase_network_role.timer not enabled"
if modem=$(resolve_modem_port); then
    pass "LTE modem AT port: ${modem}"
    for u in lte_modem_on.timer lte_modem_off.timer; do unit_enabled "$u" || fail "$u not enabled"; done
    # network interface and connection (both exist even in airplane mode)
    if [ -e /sys/class/net/usb0 ]; then
        pass "LTE network interface usb0: $(ip -4 -o addr show usb0 2>/dev/null | awk '{print $4}')"
    else
        fail "LTE modem has no network interface (usb0) - see journalctl -u rtkbase_network_role"
    fi
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -qx 'lte-usb0:usb0' \
        && pass "connection lte-usb0 active" \
        || fail "connection lte-usb0 not active (nmcli connection show)"
    # radio, registration, signal, internet
    at() { "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/lte_at.py" --port "$modem" --baudrate "${modem_baudrate:-115200}" --cmd "$1" 2>/dev/null ; }
    cfun=$(at "AT+CFUN?" | grep -oE '\+CFUN: *[0-9]+' | grep -oE '[0-9]+$')
    case "$cfun" in
        1)
            stat=$(at "AT+CEREG?" | grep -oE '\+CEREG: *[0-9]+,[0-9]+' | cut -d, -f2)
            case "$stat" in 1) reg="registered" ;; 5) reg="registered (roaming)" ;; 2) reg="searching" ;; 3) reg="registration denied" ;; *) reg="not registered" ;; esac
            rssi=$(at "AT+CSQ" | grep -oE '\+CSQ: *[0-9]+' | grep -oE '[0-9]+$')
            if [ -n "$rssi" ] && [ "$rssi" != "99" ]; then signal="$(( -113 + 2 * rssi )) dBm (CSQ ${rssi})"; else signal="unknown"; fi
            if ping -I usb0 -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
                pass "LTE reaches the internet - ${reg}, signal ${signal}"
            else
                fail "LTE radio is on but no internet through usb0 - ${reg}, signal ${signal}"
            fi
            ;;
        0|4)
            warn "LTE radio is off (airplane mode between upload windows), internet not tested - run ~/rtkbase/tools/lte_hold.sh, this check again, then ~/rtkbase/tools/lte_release.sh"
            ;;
        *)
            fail "LTE modem doesn't answer AT+CFUN? on ${modem}"
            ;;
    esac
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
if command -v tailscale >/dev/null 2>&1 && ! unit_active tailscaled && resolve_modem_port >/dev/null; then
    # lte_off.sh stops tailscaled while the modem is in airplane mode
    warn "tailscaled is stopped (normal on a master between LTE windows) - to check the login: sudo systemctl start tailscaled && tailscale status"
elif command -v tailscale >/dev/null 2>&1; then
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
overflow="${overflow_dir:-${BASEDIR}/data_overflow}"
if [ "$(findmnt -n -o FSTYPE --target "${datadir}" 2>/dev/null)" = "tmpfs" ]; then
    pass "data dir in RAM: $(df -Ph "${datadir}" | awk 'NR==2 {print $3 " used of " $2}')"
else
    fail "data dir ${datadir} is not a RAM disk - run 'sudo ./mount_tmpfs.sh' and reboot"
fi
overflow_n=$(find "$overflow" -maxdepth 1 -name '*.7z' 2>/dev/null | wc -l)
[ "$overflow_n" -gt 0 ] && warn "${overflow_n} archive(s) waiting in the SD overflow ($(du -sh "$overflow" | cut -f1))"
[ -d "$overflow" ] && sd_dir="$overflow" || sd_dir="$BASEDIR"
free_mb=$(df -Pm "$sd_dir" 2>/dev/null | awk 'NR==2 {print $4}')
[ "${free_mb:-0}" -ge "${min_free_space:-500}" ] && pass "${free_mb} MB free on the SD card" \
                                                 || fail "only ${free_mb} MB free on the SD card (min_free_space=${min_free_space:-500})"
awk '$1=="tmpfs" && $2=="/var/log" {found=1} END {exit !found}' /etc/fstab \
    && fail "/etc/fstab still puts /var/log on tmpfs - run 'sudo ./mount_tmpfs.sh' and reboot"
[ -d /var/log/journal ] && pass "persistent journal enabled" || warn "journal is not persistent (sudo ./mount_tmpfs.sh)"
unit_active rtkbase_web.service && warn "web UI is running (web_ui_enabled) - not needed in the field"

printf '\n%s FAIL, %s WARN\n' "$fails" "$warns"
[ "$fails" -eq 0 ] && echo "Ready for the field." || echo "Fix the FAILs before deploying."
exit "$fails"

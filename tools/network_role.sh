#!/bin/bash
# Decides whether this Pi is the LTE master or a client, and configures
# NetworkManager to match - so a station installed on office WiFi works as
# soon as it is powered up in the field, with no SSH session needed.
# Run as root by rtkbase_network_role.timer: shortly after boot, then every
# couple of minutes (cheap and idempotent - profiles are only rewritten
# when the role changes).
#
#   master  an LTE modem is present. usb0 is the uplink (lte-usb0). If
#           lte_share='1', eth0 serves a client Pi: but only after a DHCP
#           probe on eth0 got no answer. Plugged into a LAN that has its own
#           DHCP server (office, home router) it stays a plain DHCP client,
#           so it can never turn into a second DHCP server on someone's LAN.
#   client  no modem. eth0 is a DHCP client that waits indefinitely for a
#           master (or any router), WiFi stays as configured at install
#           time and wins the default route whenever it's connected.
#
# Route metrics (lower wins): eth0 as a LAN client 100 (master) / 700
# (client: that link is just the master's LTE), WiFi 600 (NetworkManager's
# default), lte-usb0 800. So whenever WiFi is connected, traffic uses it
# and LTE data isn't spent; LTE only carries traffic without WiFi. Nothing
# else changes with WiFi - the LTE on/off schedule, uploads and Tailscale
# all run exactly as without it. A WiFi that is connected but can't reach
# the internet (phone hotspot with mobile data off) is temporarily demoted
# below LTE, see check_wifi_route().
#
# settings.conf: network_role='auto'|'master'|'client', lte_share='1'|'0',
# modem_wait_seconds (how long to wait at boot for the modem to enumerate).

BASEDIR="$(cd "$(dirname "$0")/.." && pwd)"
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )
source "${BASEDIR}/tools/hw_detect.sh"

ETH_IFACE="eth0"
LTE_IFACE="usb0"
ETH_CON="eth0-dhcp"
SHARE_CON="lte-share-eth0"
LTE_CON="lte-usb0"
SHARE_ADDR="192.168.100.1/24"
DHCP_PROBE_SECONDS=30
# NetworkManager's "infinity" for ipv4.dhcp-timeout
DHCP_FOREVER=2147483647

log() { echo "network_role: $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "network_role: needs root" >&2
    exit 1
fi
if ! command -v nmcli >/dev/null 2>&1; then
    echo "network_role: NetworkManager (nmcli) not found, nothing to do" >&2
    exit 0
fi

mkdir -p "$(dirname "${NETWORK_ROLE_FILE}")"
previous_role=$(current_network_role)

# ---------------------------------------------------------------- role ---
detect_role() {
    case "${network_role:-auto}" in
        master|client) echo "${network_role}" ; return ;;
    esac
    [ "${modem_at_port}" = "none" ] && { echo client ; return ; }
    # First run after boot: the modem can take a while to enumerate (and
    # its udev rule to create /dev/ttymodemAT), so give it a chance before
    # settling on "client" for this boot.
    local wait_s=0
    [ "$previous_role" = "unknown" ] && wait_s="${modem_wait_seconds:-60}"
    local waited=0
    while true; do
        # Only the AT-port symlink counts, not "usb0 exists": both supported
        # modems' udev rules create it, while a mosaic-X5's USB-ethernet
        # gadget also shows up as usb0 on a station with no modem at all.
        if resolve_modem_port >/dev/null; then
            echo master ; return
        fi
        [ "$waited" -ge "$wait_s" ] && break
        sleep 2 ; waited=$((waited + 2))
    done
    echo client
}

# ------------------------------------------------------------ profiles ---
con_exists() { nmcli -t -f NAME connection show | grep -qxF "$1" ; }
con_active() { nmcli -t -f NAME connection show --active | grep -qxF "$1" ; }

ensure_con() {
    # $1 = name, $2 = ifname, rest = properties
    local name="$1" ifname="$2" ; shift 2
    if con_exists "$name"; then
        nmcli connection modify "$name" connection.interface-name "$ifname" "$@"
    else
        nmcli connection add type ethernet con-name "$name" ifname "$ifname" "$@" >/dev/null
    fi
}

# Any other wired profile that could grab eth0 or usb0 - a generic
# "Wired connection 1" with no interface name, a netplan-generated one, an
# old "Cellular Modem" from lte_network_mgmt.sh - would fight ours for the
# device (usb0 and eth0 both being ethernet-class is exactly how that
# happens). Disable its autoconnect rather than deleting it.
disable_competing_profiles() {
    local name type ifname
    while IFS=: read -r name type; do
        [ "$type" = "802-3-ethernet" ] || continue
        case "$name" in "$ETH_CON"|"$SHARE_CON"|"$LTE_CON") continue ;; esac
        ifname=$(nmcli -g connection.interface-name connection show "$name" 2>/dev/null)
        case "$ifname" in ""|"$ETH_IFACE"|"$LTE_IFACE")
            if [ "$(nmcli -g connection.autoconnect connection show "$name")" = "yes" ]; then
                log "disabling autoconnect on competing wired profile '${name}' (interface '${ifname:-any}')"
                nmcli connection modify "$name" connection.autoconnect no
            fi
            ;;
        esac
    done < <(nmcli -t -f NAME,TYPE connection show)
}

apply_master_profiles() {
    ensure_con "$LTE_CON" "$LTE_IFACE" \
        ipv4.method auto ipv4.route-metric 800 ipv6.route-metric 800 \
        connection.autoconnect yes connection.autoconnect-priority 20
    # an already-active lte-usb0 (e.g. created with metric 200 by an older
    # version) only picks the new metric up on reapply
    con_active "$LTE_CON" && nmcli device reapply "$LTE_IFACE" >/dev/null
    ensure_con "$ETH_CON" "$ETH_IFACE" \
        ipv4.method auto ipv4.route-metric 100 ipv4.dhcp-timeout "$DHCP_PROBE_SECONDS" \
        connection.autoconnect yes connection.autoconnect-priority 10
    if [ "${lte_share:-1}" = "1" ]; then
        # never autoconnect: only maybe_share_eth0() below brings it up,
        # after the DHCP probe has failed
        ensure_con "$SHARE_CON" "$ETH_IFACE" \
            ipv4.method shared ipv4.addresses "$SHARE_ADDR" ipv6.method disabled \
            connection.autoconnect no
    elif con_exists "$SHARE_CON"; then
        nmcli connection modify "$SHARE_CON" connection.autoconnect no
    fi
    disable_competing_profiles
}

apply_client_profiles() {
    con_active "$SHARE_CON" && nmcli connection down "$SHARE_CON" >/dev/null
    con_exists "$SHARE_CON" && nmcli connection modify "$SHARE_CON" connection.autoconnect no
    # wait as long as it takes: the master may boot later, or only bring
    # its share up after its own DHCP probe times out
    ensure_con "$ETH_CON" "$ETH_IFACE" \
        ipv4.method auto ipv4.route-metric 700 ipv4.dhcp-timeout "$DHCP_FOREVER" \
        connection.autoconnect yes connection.autoconnect-priority 10
    disable_competing_profiles
}

# ------------------------------------------------- master: eth0 sharing ---
maybe_share_eth0() {
    [ "${lte_share:-1}" = "1" ] || return 0
    [ "$(cat /sys/class/net/${ETH_IFACE}/carrier 2>/dev/null)" = "1" ] || return 0
    con_active "$SHARE_CON" && return 0
    con_active "$ETH_CON" && return 0
    log "eth0 has a link but no connection - probing for a DHCP server (${DHCP_PROBE_SECONDS}s)..."
    if nmcli --wait $((DHCP_PROBE_SECONDS + 10)) connection up "$ETH_CON" >/dev/null 2>&1; then
        log "eth0 got a DHCP lease - on a LAN, staying a DHCP client (not sharing LTE)."
        return 0
    fi
    log "no DHCP server on eth0 - sharing LTE to the client Pi as ${SHARE_ADDR}."
    nmcli connection up "$SHARE_CON" >/dev/null || log "failed to bring up ${SHARE_CON}"
}

# ------------------------------------------------- WiFi without internet ---
WIFI_IFACE="wlan0"
# worse than LTE (800) and a client's master link (700)
WIFI_PENALTY_METRIC=950

_wifi_reaches_internet() {
    ping -I "$WIFI_IFACE" -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -I "$WIFI_IFACE" -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && return 0
    # networks that filter ping; a captive portal answers something else
    # than 204 and correctly counts as "no internet"
    [ "$(curl --interface "$WIFI_IFACE" -s -m 6 -o /dev/null -w '%{http_code}' \
        http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)" = "204" ]
}

# A WiFi that is connected but doesn't reach the internet would otherwise
# keep the default route and black-hole every upload while LTE sits idle.
# Demote it below LTE/eth0 until it works again. Only the running device
# is changed (nmcli device modify / reapply) - never the saved WiFi
# profile - so the next association starts from its normal priority.
check_wifi_route() {
    local metric
    metric=$(ip -4 route show default dev "$WIFI_IFACE" 2>/dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "metric") {print $(i + 1); exit}}')
    [ -n "$metric" ] || return 0     # WiFi not connected / no default route
    if _wifi_reaches_internet; then
        if [ "$metric" = "$WIFI_PENALTY_METRIC" ]; then
            log "WiFi reaches the internet again - it takes priority over LTE again."
            nmcli device reapply "$WIFI_IFACE" >/dev/null
        fi
    elif [ "$metric" != "$WIFI_PENALTY_METRIC" ]; then
        log "WiFi is connected but doesn't reach the internet - routing via LTE/eth0 until it does."
        nmcli device modify "$WIFI_IFACE" ipv4.route-metric "$WIFI_PENALTY_METRIC" ipv6.route-metric "$WIFI_PENALTY_METRIC" >/dev/null
    fi
}

# ---------------------------------------------------------------- main ---
role=$(detect_role)
if [ "$role" != "$previous_role" ]; then
    log "role: ${role} (was ${previous_role})"
    if [ "$role" = "master" ]; then apply_master_profiles; else apply_client_profiles; fi
    echo "$role" > "${NETWORK_ROLE_FILE}"
fi
[ "$role" = "master" ] && maybe_share_eth0
check_wifi_route
exit 0

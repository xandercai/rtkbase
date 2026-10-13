#!/bin/bash
# Pick the LTE master/client role and configure NetworkManager for it.
# Run as root by rtkbase_network_role.timer (at boot, then every 2 min).
# Profiles are only rewritten when the role changes.
#
#   master  LTE modem present, uplink on usb0. With lte_share='1', eth0
#           serves a client Pi, but only if nobody answers DHCP on eth0
#           (on an office/home LAN it stays a normal DHCP client).
#   client  no modem. eth0 waits for DHCP from the master.
#
# Route metrics (lower wins): eth0 LAN 100 (master) / 700 (client),
# WiFi 600, lte-usb0 800. WiFi is always preferred over LTE; a WiFi
# without internet is demoted, see check_wifi_route().
#
# settings.conf: network_role (auto|master|client), lte_share,
# modem_wait_seconds.

BASEDIR="$(cd "$(dirname "$0")/.." && pwd)"
# skip settings.conf's own BASEDIR line, it would point to this script's dir
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' | grep -v '^BASEDIR=' )
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
    # first run after boot: give the modem time to enumerate
    local wait_s=0
    [ "$previous_role" = "unknown" ] && wait_s="${modem_wait_seconds:-60}"
    local waited=0
    while true; do
        # AT port only: a mosaic-X5 also shows up as usb0
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

# Generic wired profiles ("Wired connection 1", netplan ones, the old
# "Cellular Modem") would compete for eth0/usb0. Disable their autoconnect.
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
    # apply the new metric to an already active connection
    con_active "$LTE_CON" && nmcli device reapply "$LTE_IFACE" >/dev/null
    ensure_con "$ETH_CON" "$ETH_IFACE" \
        ipv4.method auto ipv4.route-metric 100 ipv4.dhcp-timeout "$DHCP_PROBE_SECONDS" \
        connection.autoconnect yes connection.autoconnect-priority 10
    if [ "${lte_share:-1}" = "1" ]; then
        # brought up only by maybe_share_eth0()
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
    # no DHCP timeout: the master may come up later
    ensure_con "$ETH_CON" "$ETH_IFACE" \
        ipv4.method auto ipv4.route-metric 700 ipv4.dhcp-timeout "$DHCP_FOREVER" \
        connection.autoconnect yes connection.autoconnect-priority 10
    disable_competing_profiles
}

# ------------------------------------------------- master: modem netdev ---
# The Teltonika's RNDIS interfaces could be claimed by the option serial
# driver before rndis_host got them (then no usb0). 92-usb-teltonika-at.rules
# now limits option to vendor-specific interfaces; this repairs a boot where
# it already happened by handing the RNDIS interface back to rndis_host.
modem_usb_dev() {
    # sysfs dir of the USB device the AT port belongs to
    local tty dev
    tty=$(basename "$(readlink -f /dev/ttymodemAT)")
    dev=$(readlink -f "/sys/class/tty/${tty}/device") || return 1
    dirname "$(dirname "$dev")"
}

modem_has_netdev() {
    local n
    for n in /sys/class/net/*; do
        [[ "$(readlink -f "$n/device" 2>/dev/null)" == "$1"/* ]] && return 0
    done
    return 1
}

repair_modem_netdev() {
    local usbdev intf i rndis="" data=""
    [ -e /dev/ttymodemAT ] || return 0
    # give the modem time to finish enumerating after it (re)appeared
    [ $(( $(date +%s) - $(stat -c %Y /dev/ttymodemAT) )) -ge 30 ] || return 0
    usbdev=$(modem_usb_dev) && [ -d "$usbdev" ] || return 0
    modem_has_netdev "$usbdev" && return 0
    for intf in "$usbdev"/*:*; do
        case "$(cat "$intf/bInterfaceClass" 2>/dev/null)" in
            e0) rndis=$(basename "$intf") ;;
            0a) data=$(basename "$intf") ;;
        esac
    done
    if [ -z "$rndis" ]; then
        log "LTE modem has no network interface, and no RNDIS interface to bind"
        return 0
    fi
    log "LTE modem has no network interface - handing ${rndis} back to rndis_host"
    for i in "$rndis" "$data"; do
        [ -n "$i" ] && [ -e "$usbdev/$i/driver" ] && echo "$i" > "$usbdev/$i/driver/unbind"
    done
    echo "$rndis" > /sys/bus/usb/drivers/rndis_host/bind || log "binding ${rndis} to rndis_host failed"
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
# worse than LTE (800) and the client's eth0 (700)
WIFI_PENALTY_METRIC=950

_wifi_reaches_internet() {
    ping -I "$WIFI_IFACE" -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -I "$WIFI_IFACE" -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && return 0
    # for networks that block ping; a captive portal won't return 204
    [ "$(curl --interface "$WIFI_IFACE" -s -m 6 -o /dev/null -w '%{http_code}' \
        http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)" = "204" ]
}

# Demote a connected WiFi that has no internet (e.g. hotspot without data)
# below LTE/eth0, restore it once it works. Only the running device is
# changed, not the saved profile.
check_wifi_route() {
    local metric
    metric=$(ip -4 route show default dev "$WIFI_IFACE" 2>/dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "metric") {print $(i + 1); exit}}')
    [ -n "$metric" ] || return 0     # WiFi not connected
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
if [ "$role" = "master" ]; then
    repair_modem_netdev
    maybe_share_eth0
fi
check_wifi_route
exit 0

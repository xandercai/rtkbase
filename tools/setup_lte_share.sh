#!/bin/bash
# One-time network setup for a two-Pi deployment: this Pi has the LTE modem
# (SIM7600, exposed as the "usb0" ethernet-class interface) and shares that
# connection over its physical "eth0" port to a second, identical Pi that
# has no LTE hardware of its own.
#
# By default NetworkManager/netplan bind a single generic ethernet profile
# to whichever ethernet-class device is available, so usb0 and eth0 end up
# fighting over the same connection once both are plugged in. This splits
# them into two dedicated connections:
#   - lte-usb0:        usb0, plain DHCP client -> the internet uplink
#   - lte-share-eth0:  eth0, static IP + NetworkManager "shared" mode
#                       (auto DHCP server + NAT) -> serves the second Pi
#
# Run once, before connecting the Ethernet cable to the second Pi:
#   sudo ./tools/setup_lte_share.sh

set -e

LTE_IFACE="usb0"
SHARE_IFACE="eth0"
SHARE_ADDR="192.168.100.1/24"
LTE_ROUTE_METRIC="200"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script needs root/sudo."
    exit 1
fi

for iface in "$LTE_IFACE" "$SHARE_IFACE"; do
    if ! ip link show "$iface" &>/dev/null; then
        echo "Error: interface ${iface} not found. Is the modem/cable connected?"
        exit 1
    fi
done

echo '################################'
echo 'REMOVING CONFLICTING CONNECTIONS'
echo '################################'
for iface in "$LTE_IFACE" "$SHARE_IFACE"; do
    existing=$(nmcli -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | cut -d: -f2)
    if [ -n "$existing" ] && [ "$existing" != "lte-usb0" ] && [ "$existing" != "lte-share-eth0" ]; then
        echo "Removing '${existing}' (was generically matching ${iface})"
        nmcli connection delete "$existing"
    fi
done
# also drop any stale profiles left over from a previous run of this script
nmcli -t -f NAME connection show | grep -qx "lte-usb0" && nmcli connection delete lte-usb0
nmcli -t -f NAME connection show | grep -qx "lte-share-eth0" && nmcli connection delete lte-share-eth0

echo '################################'
echo 'CONFIGURING LTE UPLINK ('"${LTE_IFACE}"')'
echo '################################'
nmcli connection add type ethernet ifname "$LTE_IFACE" con-name lte-usb0 \
    ipv4.method auto \
    ipv4.route-metric "$LTE_ROUTE_METRIC" \
    connection.autoconnect yes

echo '################################'
echo 'CONFIGURING SHARED LAN ('"${SHARE_IFACE}"' -> '"${SHARE_ADDR}"')'
echo '################################'
nmcli connection add type ethernet ifname "$SHARE_IFACE" con-name lte-share-eth0 \
    ipv4.method shared \
    ipv4.addresses "$SHARE_ADDR" \
    connection.autoconnect yes

nmcli connection up lte-usb0
nmcli connection up lte-share-eth0

echo '################################'
echo 'DONE'
echo '################################'
nmcli device status
ip addr show "$SHARE_IFACE" | grep 'inet '
echo ''
echo 'Now connect the Ethernet cable to the second Pi. It should pick up an'
echo "address in the ${SHARE_ADDR%.*}.0/24 range automatically."

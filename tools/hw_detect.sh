#!/bin/bash
# Sourced (not executed) by the scripts that talk to optional hardware,
# right after they load settings.conf. Resolves that hardware at run time
# instead of trusting whatever install.sh happened to find: stations are
# installed on office WiFi, often without the MPPT or even the LTE modem
# attached, and are expected to just work once powered up in the field.
#
# modem_at_port / mppt_port in settings.conf:
#   '' or 'auto' -> use the udev symlink (/dev/ttymodemAT, /dev/epever485)
#                   whenever it exists at that moment
#   'none'       -> never use that hardware on this station
#   a path       -> use that path (if it exists)

_resolve_port() {
    # $1 = configured value, $2 = auto-detect symlink
    case "$1" in
        none) return 1 ;;
        ''|auto) [ -e "$2" ] && { echo "$2"; return 0; } ; return 1 ;;
        *) [ -e "$1" ] && { echo "$1"; return 0; } ; return 1 ;;
    esac
}

resolve_modem_port() { _resolve_port "${modem_at_port}" /dev/ttymodemAT ; }
resolve_mppt_port()  { _resolve_port "${mppt_port}" /dev/epever485 ; }

# Written by tools/network_role.sh at boot: 'master' (has the LTE modem,
# shares it over eth0) or 'client' (uploads over WiFi, or through a master
# on eth0). 'unknown' until network_role.sh has run.
NETWORK_ROLE_FILE=/run/rtkbase/network_role
current_network_role() { cat "${NETWORK_ROLE_FILE}" 2>/dev/null || echo unknown ; }

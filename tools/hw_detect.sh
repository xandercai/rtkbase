#!/bin/bash
# Sourced after settings.conf. Resolves optional hardware at run time, so a
# station installed without its modem/MPPT attached still works in the field.
#
# modem_at_port / mppt_port:
#   '' or 'auto'  use /dev/ttymodemAT / /dev/epever485 if present
#   'none'        never use it
#   a path        use that path

_resolve_port() {
    # $1 = configured value, $2 = udev symlink
    case "$1" in
        none) return 1 ;;
        ''|auto) [ -e "$2" ] && { echo "$2"; return 0; } ; return 1 ;;
        *) [ -e "$1" ] && { echo "$1"; return 0; } ; return 1 ;;
    esac
}

resolve_modem_port() { _resolve_port "${modem_at_port}" /dev/ttymodemAT ; }
resolve_mppt_port()  { _resolve_port "${mppt_port}" /dev/epever485 ; }

# master / client / unknown, written by tools/network_role.sh
NETWORK_ROLE_FILE=/run/rtkbase/network_role
current_network_role() { cat "${NETWORK_ROLE_FILE}" 2>/dev/null || echo unknown ; }

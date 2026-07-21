#!/bin/bash
#
# Script to add the user name and user path in unit file
# then copy these services to the correct location.

man_help() {
 echo 'Options:'
 echo '        -h | --help'
 echo '        -p | --python_path'
 echo '                        path to the web app python venv binary'
 echo '                        (usually /home/your_username/rtkbase/venv/bin/python)'
 echo '        -u | --user  <username>'
 echo '                        Specify user used in the service unit. Without this argument'
 echo '                        the user return by the logname command will be used.'
 exit 0
}

BASEDIR="$(dirname "$0")/.."
ARG_HELP=0
ARG_PYPATH=0
ARG_USER=0
PARSED_ARGUMENTS=$(getopt --name copy_unit --options hp:u: --longoptions help,python_path:,user: -- "$@")
VALID_ARGUMENTS=$?
if [ "$VALID_ARGUMENTS" != "0" ]; then
    #man_help
    echo 'Try '\''copy_unit.sh --help'\'' for more information'
    exit 1
  fi
#echo "PARSED_ARGUMENTS is $PARSED_ARGUMENTS"
  eval set -- "$PARSED_ARGUMENTS"
  while :
    do
      case "$1" in
        -h | --help)        ARG_HELP=1                     ; shift   ;;
        -p | --python_path) ARG_PYPATH="${2}"              ; shift 2 ;;
        -u | --user)        ARG_USER="${2}"                ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        # If invalid options were passed, then getopt should have reported an error,
        # which we checked as VALID_ARGUMENTS when getopt was called...
        *) echo "Unexpected option: $1 - this should not happen."
          usage ;;
      esac
    done
[ $ARG_HELP -eq 1 ] && man_help
[ "${ARG_PYPATH}" == 0 ] && echo 'Please enter the python venv path with the -p argument' && exit
[ "${ARG_USER}" == 0 ] && ARG_USER=$(logname)
#echo 'user=' "${ARG_USER}"

# xcai->
if [ -f "${BASEDIR}/settings.conf" ]; then
  conf_file="${BASEDIR}/settings.conf"
elif [ -f "${BASEDIR}/settings.conf.default" ]; then
  conf_file="${BASEDIR}/settings.conf.default"
else
    # Error handling if neither file exists
    echo "Error: Neither '${BASEDIR}/settings.conf' nor '${BASEDIR}/settings.conf.default'."
    exit 1
fi

FILE_ROTATE_TIME=$(grep '^file_rotate_time=' "$conf_file" | cut -d"'" -f2)

# if undefined then 1 day for archive and upload
if [ -z "$FILE_ROTATE_TIME" ]; then FILE_ROTATE_TIME=24; fi

# upload every 1 hour
if [ "$FILE_ROTATE_TIME" -eq 1 ] || [ "$FILE_ROTATE_TIME" -eq 0 ]; then
    FILE_ROTATE_INTERVAL="*-*-* *:01:02"
# upload every 24 hours
elif [ "$FILE_ROTATE_TIME" -eq 24 ]; then
    FILE_ROTATE_INTERVAL="*-*-* 00:01:02"
else
# only support 2, 3, 4, 6, 8, 12 hours for now, which are all divisors of 24
    # FILE_ROTATE_INTERVAL="*-*-* */${FILE_ROTATE_TIME}:01:02"
    FILE_ROTATE_INTERVAL="*-*-* 00/${FILE_ROTATE_TIME}:01:02"
fi

INIT_TIME=$(grep '^init_time=' "$conf_file" | cut -d"'" -f2)
# if undefined then 5 minutes for initial GNSS searching delay before first run
if [ -z "$INIT_TIME" ]; then INIT_TIME=5; fi

# dynamic modify timer ini
echo 'Configue rtkbase_archive.timer.ROTATE_INTERVAL = ' "$FILE_ROTATE_INTERVAL"
# sed -i "s/{{ROTATE_INTERVAL}}/${FILE_ROTATE_INTERVAL}/g" "${BASEDIR}/unit/rtkbase_archive.timer"
# "/" may not work if use "*-*-* */${FILE_ROTATE_TIME}:01:02"
sed -i "s|{{ROTATE_INTERVAL}}|${FILE_ROTATE_INTERVAL}|g" "${BASEDIR}/unit/rtkbase_archive.timer"

echo 'Configue rtkbase_archive.timer.INITIAL_TIME = ' "$INIT_TIME"
sed -i "s/{{INITIAL_TIME}}/${INIT_TIME}min/g" "${BASEDIR}/unit/rtkbase_archive.timer"

# dynamic modify lte_modem_on.timer: fire N minutes before every
# rtkbase_archive.timer run, on the same wall-clock grid (built from the
# same FILE_ROTATE_TIME), so the modem is registered on the network with
# time to spare before archive_and_clean.sh needs to upload.
LTE_ON_BEFORE=$(grep '^lte_on_before_minutes=' "$conf_file" | cut -d"'" -f2)
# if undefined then wake the modem 2 minutes ahead of the upload window
if [ -z "$LTE_ON_BEFORE" ]; then LTE_ON_BEFORE=2; fi

LTE_ROTATE_TIME=$FILE_ROTATE_TIME
[ "$LTE_ROTATE_TIME" -eq 0 ] && LTE_ROTATE_TIME=1

LTE_ON_MINUTE=$((1 - LTE_ON_BEFORE))
if [ "$LTE_ON_MINUTE" -lt 0 ]; then
    LTE_ON_MINUTE=$((LTE_ON_MINUTE + 60))
    LTE_HOUR_BORROW=1
else
    LTE_HOUR_BORROW=0
fi
LTE_ON_HOUR_START=$(( (LTE_ROTATE_TIME - LTE_HOUR_BORROW) % LTE_ROTATE_TIME ))
LTE_ON_CALENDAR="*-*-* ${LTE_ON_HOUR_START}/${LTE_ROTATE_TIME}:${LTE_ON_MINUTE}:02"

# Also cover the boot-triggered first run (rtkbase_archive.timer's own
# OnBootSec): wake the modem a bit earlier than that so it's ready in time.
LTE_ON_BOOT_MIN=$((INIT_TIME - LTE_ON_BEFORE))
if [ "$LTE_ON_BOOT_MIN" -le 0 ]; then
    LTE_ON_BOOT_SEC="10s"
else
    LTE_ON_BOOT_SEC="${LTE_ON_BOOT_MIN}min"
fi

echo 'Configue lte_modem_on.timer.LTE_ON_CALENDAR = ' "$LTE_ON_CALENDAR"
# "/" appears in the calendar expression, so use "|" as the sed delimiter
sed -i "s|{{LTE_ON_CALENDAR}}|${LTE_ON_CALENDAR}|g" "${BASEDIR}/unit/lte_modem_on.timer"

echo 'Configue lte_modem_on.timer.LTE_ON_BOOT_SEC = ' "$LTE_ON_BOOT_SEC"
sed -i "s/{{LTE_ON_BOOT_SEC}}/${LTE_ON_BOOT_SEC}/g" "${BASEDIR}/unit/lte_modem_on.timer"

# dynamic modify tailscale_watchdog.timer
TS_WATCHDOG_INTERVAL=$(grep '^tailscale_watchdog_interval=' "$conf_file" | cut -d"'" -f2)
# if undefined then check every 5 minutes
if [ -z "$TS_WATCHDOG_INTERVAL" ]; then TS_WATCHDOG_INTERVAL=5; fi

# build an OnCalendar expression (same convention as rtkbase_archive.timer) so
# every unit wakes on the same wall-clock grid instead of drifting relative to
# its own boot time. Relies on the LTE modem keeping the system clock synced.
if [ "$TS_WATCHDOG_INTERVAL" -ge 60 ]; then
    TS_WATCHDOG_HOURS=$((TS_WATCHDOG_INTERVAL / 60))
    TS_WATCHDOG_CALENDAR="*-*-* 0/${TS_WATCHDOG_HOURS}:00:00"
else
    TS_WATCHDOG_CALENDAR="*-*-* *:0/${TS_WATCHDOG_INTERVAL}:00"
fi

TS_WATCHDOG_BOOT_DELAY=$(grep '^tailscale_watchdog_boot_delay=' "$conf_file" | cut -d"'" -f2)
# if undefined then wait 2 minutes after boot before the first check
if [ -z "$TS_WATCHDOG_BOOT_DELAY" ]; then TS_WATCHDOG_BOOT_DELAY=2; fi

echo 'Configue tailscale_watchdog.timer.TS_WATCHDOG_INTERVAL = ' "$TS_WATCHDOG_CALENDAR"
# "/" appears in the calendar expression, so use "|" as the sed delimiter
sed -i "s|{{TS_WATCHDOG_INTERVAL}}|${TS_WATCHDOG_CALENDAR}|g" "${BASEDIR}/unit/tailscale_watchdog.timer"

echo 'Configue tailscale_watchdog.timer.TS_WATCHDOG_BOOT_DELAY = ' "${TS_WATCHDOG_BOOT_DELAY}min"
sed -i "s/{{TS_WATCHDOG_BOOT_DELAY}}/${TS_WATCHDOG_BOOT_DELAY}min/g" "${BASEDIR}/unit/tailscale_watchdog.timer"
# <-xcai


if ! [ $(id -u) = 0 ]; then
   echo "This script needs root/sudo"
   exit 1
fi

for file_path in "${BASEDIR}"/unit/*.service "${BASEDIR}"/unit/*.timer
    do
        file_name=$(basename "${file_path}")
        echo copying "${file_name}"
        sed -e 's|{script_path}|'"$(dirname "$(dirname "$(readlink -f "$0")")")"'|' -e 's|{user}|'"${ARG_USER}"'|' -e 's|{python_path}|'"${ARG_PYPATH}"'|' "${file_path}" > /etc/systemd/system/"${file_name}"
    done

systemctl daemon-reload

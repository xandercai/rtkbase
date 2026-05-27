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

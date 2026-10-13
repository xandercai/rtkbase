#!/bin/bash
# Low-temperature MPPT charge guard, run by mppt_charge_guard.timer.
# Writes the EPEVER "charging device on/off" coil (address 0): off below
# mppt_charge_min_temp_c, on again above it + mppt_charge_hysteresis_c.
#
# Temperature: DS18B20 if present, else the MPPT's battery_temperature_c.
# If neither can be read for mppt_charge_failsafe_minutes, charging is
# turned back on, so a dead sensor can't drain the battery (0 disables).

BASEDIR="$(dirname "$0")/.."
# skip settings.conf's own BASEDIR line, it would point to this script's dir
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' | grep -v '^BASEDIR=' )
source "${BASEDIR}/tools/hw_detect.sh"

if ! mppt_port=$(resolve_mppt_port); then
    echo "mppt_charge_guard: no MPPT adapter on this station, nothing to do."
    exit 0
fi

LOGS_DIR="${BASEDIR}/logs"
mkdir -p "${LOGS_DIR}"
# on the SD card so they survive a reboot
UNKNOWN_SINCE_FILE="${LOGS_DIR}/mppt_guard_temp_unknown_since"
LAST_STATE_FILE="${LOGS_DIR}/mppt_guard_last_coil"
EPEVER_LOCK="/run/lock/rtkbase_epever485.lock"

threshold="${mppt_charge_min_temp_c:-2}"
hysteresis="${mppt_charge_hysteresis_c:-1.5}"
failsafe_minutes="${mppt_charge_failsafe_minutes:-120}"

_mppt() {
    # the RS485 port is shared with mppt_power_sample.sh and archive_and_clean.sh
    flock -w 20 "${EPEVER_LOCK}" "${BASEDIR}/venv/bin/python" "$@"
}

write_coil() {
    # $1 = 0|1, $2 = reason
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $2"
    if _mppt "${BASEDIR}/tools/mppt_write_coil.py" \
        --port "${mppt_port}" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}" \
        --address 0 --value "$1"
    then
        echo "$1" > "${LAST_STATE_FILE}"
        return 0
    fi
    return 1
}

temperature_c=''
source_label=''

if find /sys/bus/w1/devices -maxdepth 1 -name '28-*' -print -quit 2>/dev/null | grep -q .; then
    if reading=$(bash "${BASEDIR}/tools/thermal_read.sh"); then
        temperature_c=$(echo "$reading" | grep -oE '"temperature_c":-?[0-9.]+' | cut -d: -f2)
        source_label="DS18B20"
    else
        echo "mppt_charge_guard: DS18B20 read failed, falling back to the MPPT's own battery temperature."
    fi
fi

if [ -z "$temperature_c" ]; then
    if reading=$(_mppt "${BASEDIR}/tools/mppt_read.py" \
        --port "${mppt_port}" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}")
    then
        # json.dumps() adds a space after the colon
        temperature_c=$(echo "$reading" | grep -oE '"battery_temperature_c": *-?[0-9.]+' | grep -oE '\-?[0-9.]+$')
        source_label="MPPT battery_temperature_c"
    fi
fi

if [ -z "$temperature_c" ]; then
    now=$(date +%s)
    unknown_since=$(cat "${UNKNOWN_SINCE_FILE}" 2>/dev/null)
    [[ "$unknown_since" =~ ^[0-9]+$ ]] || { unknown_since=$now; echo "$now" > "${UNKNOWN_SINCE_FILE}"; }
    unknown_minutes=$(( (now - unknown_since) / 60 ))

    if [ "$failsafe_minutes" -gt 0 ] 2>/dev/null && [ "$unknown_minutes" -ge "$failsafe_minutes" ]; then
        write_coil 1 "No battery temperature readable for ${unknown_minutes} min (fail-safe at ${failsafe_minutes} min) - re-enabling MPPT charging so the station can't drain to a dead battery." >&2
        exit 1
    fi
    echo "mppt_charge_guard: no temperature readable for ${unknown_minutes} min, leaving charging state unchanged (fail-safe at ${failsafe_minutes} min)." >&2
    exit 1
fi
rm -f "${UNKNOWN_SINCE_FILE}"

# < threshold: off, >= threshold + hysteresis: on, in between: unchanged
decision=$(awk -v t="$temperature_c" -v th="$threshold" -v h="$hysteresis" \
    'BEGIN { if (t < th) print "off"; else if (t >= th + h) print "on"; else print "hold" }')
last_state=$(cat "${LAST_STATE_FILE}" 2>/dev/null)

case "$decision" in
    off)
        write_coil 0 "${source_label} reads ${temperature_c}C (< ${threshold}C), disabling MPPT charging."
        ;;
    on)
        write_coil 1 "${source_label} reads ${temperature_c}C (>= ${threshold}C + ${hysteresis}C), allowing MPPT charging."
        ;;
    hold)
        if [ -z "$last_state" ]; then
            # no previous state yet: treat as not cold
            write_coil 1 "${source_label} reads ${temperature_c}C (within hysteresis band, no previous state), allowing MPPT charging."
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - ${source_label} reads ${temperature_c}C (within ${threshold}..$(awk -v a="$threshold" -v b="$hysteresis" 'BEGIN{print a+b}')C band), keeping charging $([ "$last_state" = "1" ] && echo on || echo off)."
        fi
        ;;
esac

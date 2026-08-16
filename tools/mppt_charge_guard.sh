#!/bin/bash
# Low-temperature MPPT charge guard. Prefers the Raspberry Pi's own DS18B20
# sensor (tools/thermal_read.sh) over the MPPT's own battery_temperature_c
# reading, when one is wired (settings.conf thermal_sensor_present='1') -
# it's mounted directly on the battery, whereas the controller's own probe
# reads closer to the controller box. Falls back to battery_temperature_c
# otherwise, so stations with no DS18B20 still get cold-charge protection
# instead of just losing the guard entirely. Writes the "Charging device
# on/off" coil (address 0) accordingly: below mppt_charge_min_temp_c,
# charging is switched off; otherwise it's switched (back) on. Run
# periodically by mppt_charge_guard.timer, independent of the archive/upload
# schedule.

BASEDIR="$(dirname "$0")/.."
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

if [ -z "${mppt_port}" ]; then
    echo "mppt_charge_guard: mppt_port is empty, nothing to do."
    exit 0
fi

if [ "${thermal_sensor_present:-0}" = "1" ]; then
    reading=$(bash "${BASEDIR}/tools/thermal_read.sh")
    if [ $? -ne 0 ]; then
        echo "mppt_charge_guard: thermal sensor read failed, leaving charging state unchanged."
        exit 1
    fi
    temperature_c=$(echo "$reading" | grep -oE '"temperature_c":-?[0-9.]+' | cut -d: -f2)
    source_label="DS18B20"
else
    reading=$("${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/mppt_read.py" \
        --port "${mppt_port}" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}")
    if [ $? -ne 0 ]; then
        echo "mppt_charge_guard: MPPT read failed, leaving charging state unchanged."
        exit 1
    fi
    temperature_c=$(echo "$reading" | grep -oE '"battery_temperature_c":-?[0-9.]+' | cut -d: -f2)
    source_label="MPPT battery_temperature_c"
fi

if [ -z "$temperature_c" ]; then
    echo "mppt_charge_guard: could not parse temperature from '${reading}', leaving charging state unchanged."
    exit 1
fi

threshold="${mppt_charge_min_temp_c:-2}"
below=$(awk -v t="$temperature_c" -v th="$threshold" 'BEGIN { print (t < th) ? 1 : 0 }')

if [ "$below" -eq 1 ]; then
    coil_value=0
    action="below threshold, disabling"
else
    coil_value=1
    action="at/above threshold, allowing"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - ${source_label} reads ${temperature_c}C (threshold ${threshold}C), ${action} MPPT charging."
"${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/mppt_write_coil.py" \
    --port "${mppt_port}" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}" \
    --address 0 --value "$coil_value"

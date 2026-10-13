#!/bin/bash
# Read the first 1-Wire (DS18B20-class) temperature sensor found under
# /sys/bus/w1/devices and print a single line of JSON on stdout.
# Requires the w1-gpio/w1-therm kernel modules and a matching dtoverlay,
# configured automatically by tools/install.sh during rtkbase_requirements().

sensor_dir=$(find /sys/bus/w1/devices -maxdepth 1 -name '28-*' -print -quit 2>/dev/null)

if [ -z "$sensor_dir" ]; then
    echo "thermal_read: no 1-Wire (DS18B20-class) sensor found under /sys/bus/w1/devices" >&2
    exit 1
fi

sensor_file="${sensor_dir}/w1_slave"
reading=$(cat "$sensor_file" 2>/dev/null)

if [ -z "$reading" ]; then
    echo "thermal_read: could not read ${sensor_file}" >&2
    exit 1
fi

if ! echo "$reading" | head -n1 | grep -q 'YES'; then
    echo "thermal_read: CRC check failed reading ${sensor_file}" >&2
    exit 1
fi

raw_millideg=$(echo "$reading" | tail -n1 | grep -oE 't=-?[0-9]+' | cut -d= -f2)

if [ -z "$raw_millideg" ]; then
    echo "thermal_read: could not parse temperature from ${sensor_file}" >&2
    exit 1
fi

temperature_c=$(awk -v v="$raw_millideg" 'BEGIN { printf "%.3f", v / 1000 }')
timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
sensor_id=$(basename "$sensor_dir")

printf '{"temperature_c":%s,"sensor_id":"%s","timestamp_utc":"%s"}\n' \
    "$temperature_c" "$sensor_id" "$timestamp_utc"

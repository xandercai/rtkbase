#!/bin/bash

# This script updates the systemd timer for RTKBase archive and upload based on the file_rotate_time setting.
# It safely handles both integer and decimal hour values, converting them to appropriate systemd timer units (hours or minutes).
# Usage: sudo ./update_timer.sh
# Note: This script must be run with sudo to modify systemd timer files.

BASEDIR="$(dirname "$0")"
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' ) #import settings

# 1. Read variables
if [ -f "${BASEDIR}/settings.conf" ]; then
    source <( grep '=' "${BASEDIR}/settings.conf" )
else
    echo "Error: settings.conf not found."
    exit 1
fi

# Default fallback if empty
file_rotate_time="${file_rotate_time:-24}"

# 2. Check if the value contains a decimal point (.)
if [[ "$file_rotate_time" == *.* ]]; then
    # Convert hours directly to minutes using bc (e.g., 0.1 * 60 = 6)
    # If bc is missing, install it with: sudo apt install bc
    time_in_minutes=$(echo "$file_rotate_time * 60" | bc | cut -d'.' -f1)

    # Safety fallback if the calculation results in 0 minutes
    if [ "$time_in_minutes" -eq 0 ] || [ -z "$time_in_minutes" ]; then
        time_in_minutes=6
    fi

    UNIT_STRING="${time_in_minutes}min"
else
    # It's a clean integer, keep it as hours
    UNIT_STRING="${file_rotate_time}h"
fi

# 3. Safely deploy the generated file with integer-based units
sudo tee /etc/systemd/system/rtkbase_archive.timer > /dev/null <<EOF
[Unit]
Description=RTKBase archive and upload timer (Smart Auto-updated)

[Timer]
OnBootSec=5min
OnUnitActiveSec=${UNIT_STRING}
Unit=rtkbase_archive.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl restart rtkbase_archive.timer

echo "Success: Timer synchronized safely to ${UNIT_STRING}"

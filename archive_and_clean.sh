#!/bin/bash

# If the target user is still root, abort the script immediately to avoid path corruption
if [ "$HOME" = "/root" ]; then
    echo "Error: The identified user is 'root'."
    echo "This can happen if you used 'sudo su' or executed the script directly as the root user."
    echo "Please log in as a normal user (e.g., 'pi' or 'base') and run: sudo ./mount_tmpfs.sh"
    exit 1
fi

BASEDIR="$(dirname "$0")"
# load config
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

GDRIVE_REMOTE="gdrive:GNSS_IR_Data"  # you may need to change this to your actual rclone remote name and path
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
RCLONE_CONF_TMP="/tmp/rclone.conf"

# Writable RAM copy of rclone.conf to stop Token Refresh Read-Only errors
if [ ! -f "$RCLONE_CONF_TMP" ]; then
    if [ -f "$RCLONE_CONF" ]; then
        cp "$RCLONE_CONF" "$RCLONE_CONF_TMP"
        echo "copy ${RCLONE_CONF} to ${RCLONE_CONF_TMP}"
    else
        echo "Error：${RCLONE_CONF} does not exist, please check your rclone installation and configuration."
        exit 1
    fi
fi

# filter time (rotate time to mins minus 2 mins buffer)
# for example: if file_rotate_time='1'，filter out files before 1*60 - 2 = 59 mins
if [ -n "${file_rotate_time}" ]; then
    buffer_minutes=$(awk -v t="$file_rotate_time" 'BEGIN {print int(t * 60 - 2)}')
else
    buffer_minutes=1438 # default filter time 1 day
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Scan and upload new .ubx files in ${datadir} before ${buffer_minutes} mins..."

cd "${datadir}" || exit 1

for file in *.ubx; do
    [[ -e "$file" ]] || continue

    # filter out and protect the current writing file
    if [[ $(find "$file" -mmin +"${buffer_minutes}") ]]; then
        echo "Compressing raw data file: $file"
        gzip -c "$file" > "${file}.gz"

        # upload to Google Drive
        rclone move "${file}.gz" "${GDRIVE_REMOTE}" --config "${RCLONE_CONF_TMP}" --no-update-modtime

        if [ $? -eq 0 ]; then
            echo "Sync successfully, delete source file: $file"
            rm -f "$file"
        else
            echo "Sync failed, try again later: $file"
            rm -f "${file}.gz"
        fi
    fi
done

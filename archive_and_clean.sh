#!/bin/bash

# If the target user is still root, abort the script immediately to avoid path corruption
if [ "$HOME" = "/root" ]; then
    echo "Error: The identified user is 'root'."
    echo "This can happen if you used 'sudo su' or executed the script directly as the root user."
    echo "Please log in as a normal user (e.g., 'pi' or 'base') and run: sudo ./mount_tmpfs.sh"
    exit 1
fi

BASEDIR="$(dirname "$0")"

# Load configuration variables
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

GDRIVE_REMOTE="gdrive:GNSS_IR_Data" # Change this to your actual rclone remote name and path
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
RCLONE_CONF_TMP="/tmp/rclone.conf" # Writable RAM copy of rclone.conf to stop Token Refresh Read-Only errors

if [ ! -f "$RCLONE_CONF_TMP" ]; then
    if [ -f "$RCLONE_CONF" ]; then
        cp "$RCLONE_CONF" "$RCLONE_CONF_TMP"
        echo "copy ${RCLONE_CONF} to ${RCLONE_CONF_TMP}"
    else
        echo "Error：${RCLONE_CONF} does not exist, please check your rclone installation and configuration."
        exit 1
    fi
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Scan and compress new .ubx files in ${datadir} every ${file_rotate_time} hour..."
cd "${datadir}" || exit 1

# Initialize an array to keep track of files successfully compressed during this run
processed_files=()

# ----------------- STEP 1: COMPRESSION ONLY -----------------
# Batch compress all eligible .ubx files into .7z archives without triggering rclone yet
for file in *.ubx; do
    [[ -e "$file" ]] || continue

    # Default 5-minute age check to avoid processing files that are still being written by the system
    if [[ $(find "$file" -mmin +1) ]]; then
        echo "Compressing raw data file: $file"

        # 7z parameters optimized for high pattern-matching density on GNSS streams
        7z a -t7z -m0=lzma2 -mx=9 -md=128m -mfb=273 -ms=on -mhc=on "${file%.*}.7z" "$file" >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            # Record successfully compressed file names for later step verification
            processed_files+=("$file")
        else
            echo "Compression failed for: $file"
            rm -f "${file%.*}.7z"
        fi
    fi
done

# Terminate early if there are no compressed files ready for upload
if [ ${#processed_files[@]} -eq 0 ]; then
    echo "No files ready for upload."
    exit 0
fi

# ----------------- STEP 2: BATCH UPLOAD VIA SINGLE RCLONE CALL -----------------
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting batch upload to Google Drive..."

# Temporary log file to track rclone operation results for local sync logic
RCLONE_LOG="/tmp/rclone_upload.log"

# Trigger a single rclone session with built-in API throttling and exponential backoff.
# '--tpslimit 10' restricts transactions per second to strictly avoid 403 quota errors.
# 'rclone move' automatically drops local .7z copies only upon verified cloud delivery.
rclone move "./" "${GDRIVE_REMOTE}" \
    --config "${RCLONE_CONF_TMP}" \
    --no-update-modtime \
    --include "*.7z" \
    --transfers 4 \
    --checkers 8 \
    --tpslimit 10 \
    --log-level INFO \
    --log-file "$RCLONE_LOG"

# ----------------- STEP 3: SAFE CLEANUP OF ORIGINAL SOURCE FILES -----------------
echo "Cleaning up local source .ubx files..."
for file in "${processed_files[@]}"; do
    sevenz_name="${file%.*}.7z"

    # Verify if the .7z archive was wiped by rclone, or confirm successful transfer via the log
    if [ ! -f "$sevenz_name" ] && grep -q -E "Moved|Copied" "$RCLONE_LOG" 2>/dev/null; then
        echo "Sync successfully, delete source file: $file"
        rm -f "$file"
    else
        # If the local .7z remains, the transfer failed. Keep the .ubx source for retry cycles.
        echo "Sync failed, keeping source file for next run: $file"
    fi
done

# Wipe the temporary transaction log file
rm -f "$RCLONE_LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Batch job finished."

#!/bin/bash

# If the target user is still root, abort the script immediately to avoid path corruption
if [ "$HOME" = "/root" ]; then
    echo "Error: The identified user is 'root'."
    echo "Please log in as a normal user and run: sudo ./mount_tmpfs.sh"
    exit 1
fi

BASEDIR="$(dirname "$0")"

# Load configuration variables
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

GDRIVE_REMOTE="gdrive:GNSS_IR_Data"
GDRIVE_LOG_REMOTE="gdrive:GNSS_IR_Data/logs"
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
RCLONE_CONF_TMP="/tmp/rclone.conf"
LOG_TMP="/tmp/rtkbase_journal_${HOSTNAME}.log"

# ============================================================
# Main logic
# ============================================================

if [ ! -f "$RCLONE_CONF_TMP" ]; then
    if [ -f "$RCLONE_CONF" ]; then
        cp "$RCLONE_CONF" "$RCLONE_CONF_TMP"
        echo "copy ${RCLONE_CONF} to ${RCLONE_CONF_TMP}"
    else
        echo "Error: ${RCLONE_CONF} does not exist, please check your rclone installation and configuration."
        exit 1
    fi
fi

HOSTNAME=$(hostname)

echo "$(date '+%Y-%m-%d %H:%M:%S') - Scan and compress new .ubx files in ${datadir} every ${file_rotate_time} hour..."

cd "${datadir}" || exit 1

# ----------------- STEP 1: COMPRESSION -----------------
processed_files=()

for file in *.ubx; do
    [[ -e "$file" ]] || continue

    if [[ $(find "$file" -mmin +1) ]]; then
        echo "Compressing raw data file: $file"
        7z a -t7z -m0=lzma2 -mx=9 -md=128m -mfb=273 -ms=on -mhc=on "${file%.*}_${HOSTNAME}.7z" "$file" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            processed_files+=("$file")
        else
            echo "Compression failed for: $file"
            rm -f "${file%.*}_${HOSTNAME}.7z"
        fi
    fi
done

# ----------------- STEP 2: EXPORT SYSTEMD JOURNAL -----------------
# Export the last file_rotate_time hours of journal to a temp file
echo "$(date '+%Y-%m-%d %H:%M:%S') - Exporting systemd journal (last ${file_rotate_time}h)..."
journalctl --since "-${file_rotate_time}h" --no-pager --output=short-iso > "${LOG_TMP}" 2>/dev/null
if [ $? -ne 0 ] || [ ! -s "${LOG_TMP}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: journal export empty or failed, skipping log upload."
    rm -f "${LOG_TMP}"
fi

# ----------------- STEP 3: UPLOAD -----------------
RCLONE_LOG="/tmp/rclone_upload.log"

# Upload .ubx archives if any were compressed
if [ ${#processed_files[@]} -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting batch upload of GNSS data to Google Drive..."
    rclone move "./" "${GDRIVE_REMOTE}" \
        --config "${RCLONE_CONF_TMP}" \
        --no-update-modtime \
        --include "*.7z" \
        --transfers 4 \
        --checkers 8 \
        --tpslimit 10 \
        --log-level INFO \
        --log-file "$RCLONE_LOG"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - No GNSS files ready for upload."
fi

# Upload journal log if export succeeded
if [ -f "${LOG_TMP}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading journal log to Google Drive..."
    rclone copyto "${LOG_TMP}" "${GDRIVE_LOG_REMOTE}/$(date '+%Y-%m-%d_%H-%M-%S')_${HOSTNAME}_journal.log" \
        --config "${RCLONE_CONF_TMP}" \
        --no-update-modtime \
        --log-level INFO \
        --log-file "$RCLONE_LOG"
    rm -f "${LOG_TMP}"
fi

# ----------------- STEP 4: CLEANUP -----------------
if [ ${#processed_files[@]} -gt 0 ]; then
    echo "Cleaning up local source .ubx files..."
    for file in "${processed_files[@]}"; do
        sevenz_name="${file%.*}_${HOSTNAME}.7z"
        if [ ! -f "$sevenz_name" ] && grep -q -E "Moved|Copied" "$RCLONE_LOG" 2>/dev/null; then
            echo "Sync successfully, delete source file: $file"
            rm -f "$file"
        else
            echo "Sync failed, keeping source file for next run: $file"
        fi
    done
fi

rm -f "$RCLONE_LOG"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Batch job finished."

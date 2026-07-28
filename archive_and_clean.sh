#!/bin/bash

# If the target user is still root, abort the script immediately to avoid path corruption
if [ "$HOME" = "/root" ]; then
    echo "Error: The identified user is 'root'."
    echo "Please log in as a normal user and run: sudo ./mount_tmpfs.sh"
    exit 1
fi

BASEDIR="$(dirname "$0")"
HOSTNAME=$(hostname)

# Load configuration variables
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

GDRIVE_GNSS_REMOTE="gdrive:GNSS_IR_Data"
GDRIVE_JOURNAL_REMOTE="gdrive:GNSS_IR_JOURNAL"
GDRIVE_MPPT_REMOTE="gdrive:GNSS_IR_MPPT"
GDRIVE_THERMAL_REMOTE="gdrive:GNSS_IR_THERMAL"
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
RCLONE_CONF_TMP="/tmp/rclone.conf"

# Each upload source gets its own rclone log file. They must not be shared:
# STEP 5 below greps a source's log to decide whether it's safe to delete the
# local .ubx files, and a log shared across sources could show a success from
# an unrelated upload (e.g. the journal) while the GNSS data upload actually
# failed, causing source files to be deleted despite never having synced.
RCLONE_LOG_GNSS="/tmp/rclone_upload_gnss.log"
RCLONE_LOG_JOURNAL="/tmp/rclone_upload_journal.log"
RCLONE_LOG_MPPT="/tmp/rclone_upload_mppt.log"
RCLONE_LOG_THERMAL="/tmp/rclone_upload_thermal.log"

JOURNAL_TMP="/tmp/rtkbase_journal_${HOSTNAME}.log"
MPPT_TMP="/tmp/rtkbase_mppt_${HOSTNAME}.json"
THERMAL_TMP="/tmp/rtkbase_thermal_${HOSTNAME}.json"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"

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

echo "$(date '+%Y-%m-%d %H:%M:%S') - Scan and compress new .ubx files in ${datadir} every ${file_rotate_time} hour..."

cd "${datadir}" || exit 1

# ----------------- STEP 1: COMPRESSION (GNSS raw data) -----------------
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

if [ ${#processed_files[@]} -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting batch upload of GNSS data to Google Drive..."
    rclone move "./" "${GDRIVE_GNSS_REMOTE}" \
        --config "${RCLONE_CONF_TMP}" \
        --no-update-modtime \
        --include "*.7z" \
        --transfers 4 \
        --checkers 8 \
        --tpslimit 10 \
        --log-level INFO \
        --log-file "$RCLONE_LOG_GNSS"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - No GNSS files ready for upload."
fi

# ----------------- STEP 2: MPPT STATUS (point-in-time snapshot) -----------------
# mppt_port is only set once install.sh --detect-mppt has paired the
# RS485-USB adapter with a udev symlink. Empty means no MPPT hardware here.
if [ -n "${mppt_port}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Reading MPPT status from ${mppt_port}..."
    if "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/mppt_read.py" \
        --port "${mppt_port}" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}" \
        > "${MPPT_TMP}"
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading MPPT snapshot to Google Drive..."
        rclone copyto "${MPPT_TMP}" "${GDRIVE_MPPT_REMOTE}/${TIMESTAMP}_${HOSTNAME}_mppt.json" \
            --config "${RCLONE_CONF_TMP}" \
            --no-update-modtime \
            --log-level INFO \
            --log-file "$RCLONE_LOG_MPPT"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: MPPT read failed, skipping upload."
    fi
    rm -f "${MPPT_TMP}"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - MPPT not configured (mppt_port is empty), skipping."
fi

# ----------------- STEP 3: THERMAL SENSOR (point-in-time snapshot) -----------------
echo "$(date '+%Y-%m-%d %H:%M:%S') - Reading thermal sensor..."
if bash "${BASEDIR}/tools/thermal_read.sh" > "${THERMAL_TMP}"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading thermal snapshot to Google Drive..."
    rclone copyto "${THERMAL_TMP}" "${GDRIVE_THERMAL_REMOTE}/${TIMESTAMP}_${HOSTNAME}_thermal.json" \
        --config "${RCLONE_CONF_TMP}" \
        --no-update-modtime \
        --log-level INFO \
        --log-file "$RCLONE_LOG_THERMAL"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: thermal sensor read failed, skipping upload."
fi
rm -f "${THERMAL_TMP}"

# ----------------- STEP 4: SYSTEM JOURNAL (continuous log) -----------------
# Exported last, after STEP 2/3 have already run and logged their own
# success/failure - so this same run's journal upload is a self-contained
# record of what happened, instead of only showing up in the *next* run's
# journal export two hours later.
# file_rotate_time=0 means "hourly" (see copy_unit.sh), so treat it like 1
# here too, otherwise "--since -0h" would export next to nothing.
journal_window="${file_rotate_time:-24}"
[ "$journal_window" -eq 0 ] 2>/dev/null && journal_window=1

echo "$(date '+%Y-%m-%d %H:%M:%S') - Exporting systemd journal (last ${journal_window}h)..."
# --output=json (one JSON object per line) instead of plain short-iso text:
# this keeps each entry's PRIORITY field, which is how rtkdashboard flags
# genuinely unexpected problems (anything at warning level or worse) instead
# of only ones matching a hand-maintained keyword list. Anything a unit
# writes to stderr is auto-tagged PRIORITY=err by systemd's own
# StandardError=journal handling, so this catches new failure modes with no
# extra code on the writing side, as long as it goes to stderr like normal.
# --output-fields restricts each entry to only what parsers.py actually
# reads (see _alert_from_json_line) - journalctl's full json record has
# several dozen _-prefixed fields we never use, and cutting them out keeps
# this export fast even over a multi-hour window on a busy box.
journalctl --since "-${journal_window}h" --no-pager --output=json \
    --output-fields=MESSAGE,PRIORITY,SYSLOG_IDENTIFIER,_COMM,__REALTIME_TIMESTAMP \
    > "${JOURNAL_TMP}" 2>/dev/null
if [ $? -ne 0 ] || [ ! -s "${JOURNAL_TMP}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: journal export empty or failed, skipping log upload."
    rm -f "${JOURNAL_TMP}"
fi

if [ -f "${JOURNAL_TMP}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading journal log to Google Drive..."
    rclone copyto "${JOURNAL_TMP}" "${GDRIVE_JOURNAL_REMOTE}/${TIMESTAMP}_${HOSTNAME}_journal.log" \
        --config "${RCLONE_CONF_TMP}" \
        --no-update-modtime \
        --log-level INFO \
        --log-file "$RCLONE_LOG_JOURNAL"
    rm -f "${JOURNAL_TMP}"
fi

# ----------------- STEP 5: CLEANUP -----------------
# Only the GNSS upload's own log decides whether local .ubx sources are safe
# to delete - it must never be influenced by the other three sources.
if [ ${#processed_files[@]} -gt 0 ]; then
    echo "Cleaning up local source .ubx files..."
    for file in "${processed_files[@]}"; do
        sevenz_name="${file%.*}_${HOSTNAME}.7z"
        if [ ! -f "$sevenz_name" ] && grep -q -E "Moved|Copied" "$RCLONE_LOG_GNSS" 2>/dev/null; then
            echo "Sync successfully, delete source file: $file"
            rm -f "$file"
        else
            echo "Sync failed, keeping source file for next run: $file"
        fi
    done
fi

rm -f "$RCLONE_LOG_GNSS" "$RCLONE_LOG_JOURNAL" "$RCLONE_LOG_MPPT" "$RCLONE_LOG_THERMAL"

# ----------------- STEP 6: LTE MODEM POWER-SAVING (upload_window mode) -----------------
# lte_modem_off.timer always turns the modem off at the fixed
# lte_online_minutes deadline (see settings.conf [lte]) - that's the only
# off-trigger in fixed_window mode, and a safety net here too in case this
# script hangs before reaching this point. In upload_window mode, turn it
# off right now instead of waiting for that deadline, since uploads are
# already done - lte_off.sh already checks the hold flag and no-ops safely
# if called again later by the timer.
if [ "${lte_schedule_mode:-fixed_window}" = "upload_window" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads done (upload_window mode), switching LTE modem off..."
    bash "${BASEDIR}/tools/lte_off.sh"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Batch job finished."

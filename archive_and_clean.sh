#!/bin/bash

# If the target user is still root, abort the script immediately to avoid path corruption
if [ "$HOME" = "/root" ]; then
    echo "Error: The identified user is 'root'."
    echo "Please log in as a normal user and run: sudo ./mount_tmpfs.sh"
    exit 1
fi

# absolute: the script cd's into the data dir below
BASEDIR="$(cd "$(dirname "$0")" && pwd)"
HOSTNAME=$(hostname)

# Load configuration variables
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )
source "${BASEDIR}/tools/hw_detect.sh"
# empty = not present on this station (see tools/hw_detect.sh)
MODEM_PORT=$(resolve_modem_port)
MPPT_PORT=$(resolve_mppt_port)
NETWORK_ROLE=$(current_network_role)
SCRIPT_START=$(date +%s)

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

# LOGS_DIR is on the SD card and survives a reboot, unlike /tmp and the
# data dir (tmpfs).
LOGS_DIR="${BASEDIR}/logs"
mkdir -p "${LOGS_DIR}"
FAILURE_COUNT_FILE="${LOGS_DIR}/upload_failure_count"
LTE_HOLD_FLAG="/tmp/rtkbase_lte_hold"
MANUAL_HOLD_FLAG="/tmp/rtkbase_lte_hold_manual"

# How many consecutive prior cycles had zero successful uploads across all
# four sources (see any_upload_succeeded below) - read once up front so
# STEP 0 can act on it before this cycle's own uploads run, not just record
# it after the fact. A missing/non-numeric file (first run ever, or a
# corrupted write) is treated as "0 prior failures" rather than aborting.
PRIOR_FAILED_CYCLES=$(cat "$FAILURE_COUNT_FILE" 2>/dev/null || echo 0)
[[ "$PRIOR_FAILED_CYCLES" =~ ^[0-9]+$ ]] || PRIOR_FAILED_CYCLES=0
any_upload_succeeded=0

# Runs an rclone upload; on failure, prints the tail of its own log so the
# real error (rate limit, auth, timeout...) lands in journalctl instead of
# vanishing - rclone's --log-file writes to a local file, not stdout, and
# every one of those files gets deleted at the end of this script (STEP 5)
# regardless of outcome, so without this the only trace of a failure used
# to be the fact that the file never showed up on Drive days later.
_rclone_upload_or_warn() {
    local log_file="$1" label="$2"
    shift 2
    if rclone "$@" --log-file "$log_file"; then
        return 0
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: ${label} upload failed:"
    tail -n 20 "$log_file" 2>/dev/null | sed 's/^/    /'
    return 1
}

# Cheap reachability probe, independent of any rclone/Drive-specific
# failure (auth expiry, API rate limit, corrupt rclone.conf) - used by
# STEP 0 below to tell "the modem/network itself looks down" (worth
# resetting the modem for) apart from "network is fine but something else
# broke" (a reset would just interrupt a working connection for nothing).
# 8.8.8.8 rather than a hostname - DNS itself being down is one of the
# failure modes this needs to detect, so the probe can't depend on it.
_network_reachable() {
    ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1
}

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

# Hold the LTE modem on for the duration of this run. lte_modem_off.timer
# runs on its own fixed schedule regardless of whether this script is still
# uploading (it's a safety net "in case this script hangs" - see its own
# service description), so a slow/flaky-network run can have its network cut
# out from under it mid-upload. lte_off.sh already honors this same flag,
# so holding it here just extends that same mechanism to our own run.
#
# This flag is ours alone - tools/lte_hold.sh/lte_release.sh's manual SSH
# override uses a separate file (MANUAL_HOLD_FLAG), which lte_off.sh checks
# independently. They used to share this one file, which meant a
# manual hold requested while this script already owned the flag - the
# common case, since by the time a human notices the modem is on and
# manages to SSH in, this script has usually already started and already
# created it - got silently deleted the moment this run finished, often
# well before the human's session was done with it. Never reintroduce that
# coupling: this block must only ever create/release its own flag.
#
# Only release it if THIS run is the one that created it - guards against a
# second concurrent run (shouldn't normally happen, but costs nothing to
# guard against) clearing the first one's hold out from under it. The trap
# is a safety net for abnormal exits (STEP 6 below releases it explicitly
# on the normal path, before its own lte_off.sh call, so upload_window mode
# can still power the modem off promptly once uploads are actually done).
# (LTE_HOLD_FLAG itself is defined further up, alongside MANUAL_HOLD_FLAG,
# since STEP 0 below needs both before this block runs.)
LTE_HOLD_CREATED_BY_US=0
if [ ! -f "$LTE_HOLD_FLAG" ]; then
    touch "$LTE_HOLD_FLAG"
    LTE_HOLD_CREATED_BY_US=1
fi
release_lte_hold() {
    if [ "$LTE_HOLD_CREATED_BY_US" -eq 1 ]; then
        rm -f "$LTE_HOLD_FLAG"
    fi
}
trap release_lte_hold EXIT

# ----------------- STEP 0: MODEM RESET AFTER PROLONGED FAILURE -----------------
# If every source failed to upload for several cycles in a row, the modem
# is *one* plausible culprit - but so is a token expiry, a Drive-side rate
# limit, or a corrupt rclone.conf, none of which a power-cycle would fix,
# and all of which it would still interrupt a perfectly working connection
# for. _network_reachable() (see its own comment above) is what tells these
# apart: only reset when the network genuinely looks down, not just because
# uploads happen to be failing. Runs before STEP 1 rather than after this
# cycle's own uploads, so a fixed modem gets to actually help this same
# cycle instead of only the next one two hours later.
#
# Skips the reset outright if a manual SSH hold is active - MANUAL_HOLD_FLAG
# means a human is using this exact connection right now, and a surprise
# power-cycle would kick them off. LTE_HOLD_FLAG (this script's own hold,
# just created above) is irrelevant here - it says nothing about a human
# being present.
if [ "${lte_reset_after_failed_cycles:-0}" -gt 0 ] 2>/dev/null \
    && [ "$PRIOR_FAILED_CYCLES" -ge "${lte_reset_after_failed_cycles}" ] \
    && [ -n "${MODEM_PORT}" ]
then
    if [ -f "$MANUAL_HOLD_FLAG" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads have failed ${PRIOR_FAILED_CYCLES} cycles in a row, but a manual SSH hold is active - skipping modem reset."
    elif ! _network_reachable; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads have failed ${PRIOR_FAILED_CYCLES} consecutive cycles and the network is unreachable - power-cycling the LTE modem before retrying..."
        "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/lte_at.py" \
            --port "${MODEM_PORT}" --baudrate "${modem_baudrate:-115200}" --cmd "AT+CFUN=0"
        sleep 5
        "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/lte_at.py" \
            --port "${MODEM_PORT}" --baudrate "${modem_baudrate:-115200}" --cmd "AT+CFUN=1"
        # Give the modem a moment to re-register with the network before
        # STEP 1 below starts relying on it - a bare CFUN=1 returns long
        # before the modem has actually found a cell tower.
        sleep 15
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads have failed ${PRIOR_FAILED_CYCLES} consecutive cycles, but the network is reachable - probably not a modem problem, skipping reset."
    fi
fi

# Upload order deliberately puts the small, no-retry-if-missed sources
# (MPPT/thermal/journal - one-shot snapshots; a failed upload here is just
# gone, nothing keeps a copy to retry) ahead of GNSS (large, and already
# self-healing - see STEP 4 below: an unsynced .7z just stays on disk
# and gets picked up again next run, no data actually lost). If this run
# is having a slow/flaky-network day, that ordering spends the good early
# part of its network budget on the things that can't recover from being
# skipped, and risks losing time on the one thing that already tolerates
# being late instead.

echo "$(date '+%Y-%m-%d %H:%M:%S') - Scan and compress new .${receiver_format:-ubx} files in ${datadir} every ${file_rotate_time} hour..."

cd "${datadir}" || exit 1

# ----------------- STEP 1: MPPT STATUS (point-in-time snapshot) -----------------
# MPPT_PORT is empty when no RS485 adapter is plugged in
if [ -n "${MPPT_PORT}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Reading MPPT status from ${MPPT_PORT}..."
    if flock -w 30 /run/lock/rtkbase_epever485.lock \
        "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/mppt_read.py" \
        --port "${MPPT_PORT}" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}" \
        > "${MPPT_TMP}"
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading MPPT snapshot to Google Drive..."
        if _rclone_upload_or_warn "$RCLONE_LOG_MPPT" "MPPT snapshot" copyto "${MPPT_TMP}" "${GDRIVE_MPPT_REMOTE}/${TIMESTAMP}_${HOSTNAME}_mppt.json" \
            --config "${RCLONE_CONF_TMP}" \
            --no-update-modtime \
            --timeout 60s \
            --contimeout 30s \
            --retries 3 \
            --low-level-retries 10 \
            --log-level INFO
        then
            any_upload_succeeded=1
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: MPPT read failed, skipping upload."
    fi
    rm -f "${MPPT_TMP}"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - No MPPT adapter on this station, skipping."
fi

# ----------------- STEP 1b: MPPT LOAD POWER SAMPLES (1-min series) -----------------
# mppt_power_sample.timer appends one load-power reading per minute to this
# tmpfs CSV. Upload the window's accumulation and rotate: mv first so the
# sampler immediately starts a fresh file and no sample written mid-upload
# is lost. Independent of the STEP 1 snapshot - uploads even if that failed.
POWER_SAMPLES="/tmp/rtkbase_mppt_power_${HOSTNAME}.csv"
if [ -s "${POWER_SAMPLES}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading MPPT load power samples..."
    POWER_SAMPLES_SNAP="${POWER_SAMPLES}.uploading"
    mv "${POWER_SAMPLES}" "${POWER_SAMPLES_SNAP}"
    if _rclone_upload_or_warn "$RCLONE_LOG_MPPT" "MPPT load power samples" copyto "${POWER_SAMPLES_SNAP}" "${GDRIVE_MPPT_REMOTE}/${TIMESTAMP}_${HOSTNAME}_mppt_power.csv" \
        --config "${RCLONE_CONF_TMP}" \
        --no-update-modtime \
        --timeout 60s \
        --contimeout 30s \
        --retries 3 \
        --low-level-retries 10 \
        --log-level INFO
    then
        any_upload_succeeded=1
    fi
    rm -f "${POWER_SAMPLES_SNAP}"
fi

# ----------------- STEP 2: THERMAL SENSOR (point-in-time snapshot) -----------------
# Only when a DS18B20 is present; otherwise the MPPT snapshot's
# battery_temperature_c covers this station on the dashboard.
if [ "${thermal_sensor_present:-0}" = "1" ] \
    || find /sys/bus/w1/devices -maxdepth 1 -name '28-*' -print -quit 2>/dev/null | grep -q .
then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Reading thermal sensor..."
    if bash "${BASEDIR}/tools/thermal_read.sh" > "${THERMAL_TMP}"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading thermal snapshot to Google Drive..."
        if _rclone_upload_or_warn "$RCLONE_LOG_THERMAL" "Thermal snapshot" copyto "${THERMAL_TMP}" "${GDRIVE_THERMAL_REMOTE}/${TIMESTAMP}_${HOSTNAME}_thermal.json" \
            --config "${RCLONE_CONF_TMP}" \
            --no-update-modtime \
            --timeout 60s \
            --contimeout 30s \
            --retries 3 \
            --low-level-retries 10 \
            --log-level INFO
        then
            any_upload_succeeded=1
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: thermal sensor read failed, skipping upload."
    fi
    rm -f "${THERMAL_TMP}"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - No DS18B20 thermal sensor on this station, skipping."
fi

# ----------------- STEP 3: SYSTEM JOURNAL (continuous log) -----------------
# Exported after STEP 1/2 have already run and logged their own
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
    if _rclone_upload_or_warn "$RCLONE_LOG_JOURNAL" "Journal log" copyto "${JOURNAL_TMP}" "${GDRIVE_JOURNAL_REMOTE}/${TIMESTAMP}_${HOSTNAME}_journal.log" \
        --config "${RCLONE_CONF_TMP}" \
        --no-update-modtime \
        --timeout 60s \
        --contimeout 30s \
        --retries 3 \
        --low-level-retries 10 \
        --log-level INFO
    then
        any_upload_succeeded=1
    fi
    rm -f "${JOURNAL_TMP}"
fi

# ----------------- STEP 4: COMPRESSION + UPLOAD (GNSS raw data) -----------------
# Deliberately last of the four upload sources - see the module-level
# comment above STEP 1 for why (this is the one source that already
# tolerates being late: an unsynced .7z just stays on disk and is retried
# next run, unlike the point-in-time snapshots above, which have no such
# recovery if this run runs out of time or network).
#
# Closed raw files are compressed and then deleted; the .7z is removed by
# rclone move once it is on Drive. Recording happens in datadir (RAM disk);
# pending archives move to OVERFLOW_DIR on the SD card only when RAM is
# full (STEP 5).
OVERFLOW_DIR="${overflow_dir:-${BASEDIR}/data_overflow}"
mkdir -p "${OVERFLOW_DIR}"

# extension follows receiver_format: ubx (F9P), rtcm3 (UM980), sbf (mosaic-X5)
raw_ext="${receiver_format:-ubx}"

# total size of the .7z archives in a directory, in MB
_archives_mb() {
    find "$1" -maxdepth 1 -name '*.7z' -printf '%s\n' 2>/dev/null | awk '{s += $1} END {print int(s / 1048576)}'
}
# oldest .7z in a directory (mtime = recording time, see -stl below)
_oldest_archive() {
    find "$1" -maxdepth 1 -name '*.7z' -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n 1 | cut -d' ' -f2-
}
_archive_count() {
    find "$1" -maxdepth 1 -name '*.7z' 2>/dev/null | wc -l
}

# OVERFLOW_DIR may hold raw files moved there by mount_tmpfs.sh
for file in "${datadir}"/*."${raw_ext}" "${OVERFLOW_DIR}"/*."${raw_ext}"; do
    [[ -e "$file" ]] || continue

    if [[ $(find "$file" -mmin +1) ]]; then
        echo "Compressing raw data file: $(basename "$file")"
        # -mx=5 -md=16m: -mx=9 -md=128m needs too much RAM for a Pi 3B+.
        # -stl keeps the raw file's mtime on the archive.
        sevenz_name="${file%.*}_${HOSTNAME}.7z"
        # remove a partial archive from an interrupted run
        rm -f "$sevenz_name"
        if compress_output=$(7z a -t7z -m0=lzma2 -mx=5 -md=16m -mmt=2 -stl "$sevenz_name" "$file" 2>&1); then
            rm -f "$file"
        else
            echo "Compression failed for: $file (keeping it for next run)" >&2
            echo "$compress_output" | tail -n 5 | sed 's/^/    /' >&2
            rm -f "$sevenz_name"
        fi
    fi
done

# upload RAM first (lost on power cut), then the SD overflow
pending_ram=$(_archive_count "${datadir}")
pending_sd=$(_archive_count "${OVERFLOW_DIR}")

# A client going through the master's eth0 share must finish before the
# master's LTE window closes; stop a minute early and leave the rest for
# the next cycle. Not applied when the client uses WiFi.
uplink_dev=$(ip route get 8.8.8.8 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
client_via_master=0
[ "$NETWORK_ROLE" = "client" ] && [ "$uplink_dev" = "eth0" ] && client_via_master=1
window_s=$(( (${lte_online_minutes:-10} - ${lte_on_before_minutes:-2} - 1) * 60 ))
# sets gnss_deadline_flags; fails if there's no time left in the window
_set_deadline_flags() {
    gnss_deadline_flags=()
    [ "$client_via_master" -eq 1 ] || return 0
    local remaining_s=$(( window_s - ($(date +%s) - SCRIPT_START) ))
    [ "$remaining_s" -ge 30 ] || return 1
    gnss_deadline_flags=(--max-duration "${remaining_s}s" --cutoff-mode soft)
}

if [ $((pending_ram + pending_sd)) -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading $((pending_ram + pending_sd)) GNSS archive(s) to Google Drive (RAM: ${pending_ram}, SD overflow: ${pending_sd})..."
    for upload_dir in "${datadir}" "${OVERFLOW_DIR}"; do
        [ "$(_archive_count "$upload_dir")" -gt 0 ] || continue
        if ! _set_deadline_flags; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Master's LTE window is about to close, leaving the remaining GNSS archives for the next cycle."
            break
        fi
        # rclone move deletes each .7z once uploaded; failures stay for next run
        if _rclone_upload_or_warn "$RCLONE_LOG_GNSS" "GNSS batch (${upload_dir})" move "${upload_dir}/" "${GDRIVE_GNSS_REMOTE}" \
            --config "${RCLONE_CONF_TMP}" \
            --no-update-modtime \
            --include "*.7z" \
            --transfers 4 \
            --checkers 8 \
            --tpslimit 10 \
            --timeout 60s \
            --contimeout 30s \
            --retries 3 \
            --low-level-retries 10 \
            --log-level INFO \
            "${gnss_deadline_flags[@]}"
        then
            any_upload_succeeded=1
        fi
    done
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - No GNSS archives to upload."
fi

# ----------------- STEP 5: RAM -> SD SPILL, SD CAP -----------------
# Pending archives above ram_pending_max_mb (or RAM disk > 75% full) move
# to the SD overflow, oldest first. The overflow is capped at
# sd_overflow_max_mb and min_free_space MB free; beyond that the oldest
# archives are deleted so the card never fills up.
ram_pending_max="${ram_pending_max_mb:-128}" ; [[ "$ram_pending_max" =~ ^[0-9]+$ ]] || ram_pending_max=128
sd_overflow_max="${sd_overflow_max_mb:-4000}" ; [[ "$sd_overflow_max" =~ ^[0-9]+$ ]] || sd_overflow_max=4000
min_free_mb="${min_free_space:-500}" ; [[ "$min_free_mb" =~ ^[0-9]+$ ]] || min_free_mb=500

while :; do
    ram_archives_mb=$(_archives_mb "${datadir}")
    ram_used_pct=$(df -P "${datadir}" | awk 'NR==2 {sub("%", "", $5); print $5}')
    [ "$ram_archives_mb" -gt "$ram_pending_max" ] || [ "${ram_used_pct:-0}" -gt 75 ] || break
    oldest=$(_oldest_archive "${datadir}")
    [ -n "$oldest" ] || break
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Moving $(basename "$oldest") from RAM to the SD overflow (archives in RAM: ${ram_archives_mb} MB, RAM disk ${ram_used_pct}% used)."
    mv -- "$oldest" "${OVERFLOW_DIR}/" || break
done

while :; do
    overflow_mb=$(_archives_mb "${OVERFLOW_DIR}")
    sd_free_mb=$(df -Pm "${OVERFLOW_DIR}" | awk 'NR==2 {print $4}')
    [ "$overflow_mb" -gt "$sd_overflow_max" ] || [ "${sd_free_mb:-0}" -lt "$min_free_mb" ] || break
    oldest=$(_oldest_archive "${OVERFLOW_DIR}")
    [ -n "$oldest" ] || break
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: deleting un-uploaded archive $(basename "$oldest") (SD overflow ${overflow_mb}/${sd_overflow_max} MB, ${sd_free_mb} MB free on the card)." >&2
    rm -f -- "$oldest"
done

rm -f "$RCLONE_LOG_GNSS" "$RCLONE_LOG_JOURNAL" "$RCLONE_LOG_MPPT" "$RCLONE_LOG_THERMAL"

# ----------------- STEP 5b: FAILURE ACCOUNTING + FORENSIC DUMP -----------------
# any_upload_succeeded is set by STEP 1/1b/2/3/4 above the moment any single
# source gets through - a run that only fails GNSS but still gets its small
# MPPT/journal snapshots out doesn't count as "everything is down" the way
# an all-four-failed run does, and STEP 0 above already only fires on the
# latter case.
if [ "$any_upload_succeeded" -eq 1 ]; then
    if [ "$PRIOR_FAILED_CYCLES" -gt 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads succeeded again after ${PRIOR_FAILED_CYCLES} failed cycle(s)."
    fi
    echo 0 > "$FAILURE_COUNT_FILE"
else
    failed_cycles=$((PRIOR_FAILED_CYCLES + 1))
    echo "$failed_cycles" > "$FAILURE_COUNT_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: every upload source failed this cycle (${failed_cycles} in a row)."

    # Dumps the whole current boot's journal, not just this cycle's own
    # --since window - the point is to capture however this outage actually
    # started, which could be hours or days back, and everything since boot
    # is still sitting in memory regardless (journald only loses it on the
    # *next* reboot, which is usually exactly what someone reaches for once
    # they notice a station has been stuck this long - see LOGS_DIR above).
    # Re-dumps every debug_dump_after_failed_cycles cycles for as long as
    # the outage continues, rather than only once, so a multi-day outage
    # still ends with a recent snapshot instead of just its first few hours.
    dump_every="${debug_dump_after_failed_cycles:-0}"
    if [ "$dump_every" -gt 0 ] 2>/dev/null && [ $((failed_cycles % dump_every)) -eq 0 ]; then
        dump_file="${LOGS_DIR}/stuck_${TIMESTAMP}.log.gz"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Still stuck after ${failed_cycles} cycles - dumping this boot's journal to ${dump_file} in case a reboot is needed before it clears up."
        journalctl -b --no-pager 2>/dev/null | gzip > "$dump_file"
        # Keep this from growing unbounded across repeat/older outages -
        # any single dump is enough forensic value on its own, so age is
        # the only thing that decides which ones are still worth keeping.
        find "${LOGS_DIR}" -maxdepth 1 -name 'stuck_*.log.gz' -mtime +14 -delete
    fi
fi

# ----------------- STEP 6: LTE MODEM POWER-SAVING -----------------
# lte_modem_off.timer always turns the modem off at the fixed
# lte_online_minutes deadline (see settings.conf [lte]) - that's the only
# off-trigger in fixed_window mode, and a safety net here too in case this
# script hangs before reaching this point. In upload_window mode, turn it
# off right now instead of waiting for that deadline, since uploads are
# already done - lte_off.sh already checks the hold flag and no-ops safely
# if called again later by the timer.
#
# Release our hold explicitly here (rather than waiting for the EXIT trap):
# lte_off.sh below checks the same flag and would otherwise refuse to power
# down, defeating upload_window mode's whole point.
#
# A master sharing LTE with a client doesn't switch off early, the client
# may still be uploading. If this run went past the LTE window, the off
# timer was skipped because of our hold, so switch the modem off here.
release_lte_hold
lte_deadline=$(( SCRIPT_START + (${lte_online_minutes:-10} - ${lte_on_before_minutes:-2}) * 60 ))
if [ -n "${MODEM_PORT}" ] && [ "$(date +%s)" -ge "$lte_deadline" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - This run outlasted the LTE online window (lte_online_minutes=${lte_online_minutes:-10}), switching the modem off now..."
    bash "${BASEDIR}/tools/lte_off.sh"
elif [ "${lte_schedule_mode:-fixed_window}" = "upload_window" ]; then
    if [ "$NETWORK_ROLE" = "master" ] && nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx 'lte-share-eth0'; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads done, but LTE is shared with a client Pi - leaving the modem on until the fixed lte_online_minutes deadline."
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads done (upload_window mode), switching LTE modem off..."
        bash "${BASEDIR}/tools/lte_off.sh"
    fi
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Batch job finished."

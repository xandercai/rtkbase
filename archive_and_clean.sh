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

# LOGS_DIR is the one place on this machine that actually survives a
# reboot - /var/log, /tmp and the data dir are all tmpfs (see
# mount_tmpfs.sh), so anything only written there is gone the moment
# someone reboots a stuck machine to fix it, which is exactly the situation
# STEP 0 and STEP 5b below exist to leave a trail through instead.
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
    && [ -n "${modem_at_port}" ]
then
    if [ -f "$MANUAL_HOLD_FLAG" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads have failed ${PRIOR_FAILED_CYCLES} cycles in a row, but a manual SSH hold is active - skipping modem reset."
    elif ! _network_reachable; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads have failed ${PRIOR_FAILED_CYCLES} consecutive cycles and the network is unreachable - power-cycling the LTE modem before retrying..."
        "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/lte_at.py" \
            --port "${modem_at_port}" --baudrate "${modem_baudrate:-115200}" --cmd "AT+CFUN=0"
        sleep 5
        "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/lte_at.py" \
            --port "${modem_at_port}" --baudrate "${modem_baudrate:-115200}" --cmd "AT+CFUN=1"
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
# self-healing - see STEP 4/5 below: an unsynced .ubx just stays on disk
# and gets picked up again next run, no data actually lost). If this run
# is having a slow/flaky-network day, that ordering spends the good early
# part of its network budget on the things that can't recover from being
# skipped, and risks losing time on the one thing that already tolerates
# being late instead.

echo "$(date '+%Y-%m-%d %H:%M:%S') - Scan and compress new .ubx files in ${datadir} every ${file_rotate_time} hour..."

cd "${datadir}" || exit 1

# ----------------- STEP 1: MPPT STATUS (point-in-time snapshot) -----------------
# mppt_port is only set once install.sh --detect-mppt has paired the
# RS485-USB adapter with a udev symlink. Empty means no MPPT hardware here.
if [ -n "${mppt_port}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Reading MPPT status from ${mppt_port}..."
    if "${BASEDIR}/venv/bin/python" "${BASEDIR}/tools/mppt_read.py" \
        --port "${mppt_port}" --baudrate "${mppt_baudrate:-115200}" --slave-id "${mppt_slave_id:-1}" \
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') - MPPT not configured (mppt_port is empty), skipping."
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
# thermal_sensor_present is only '1' once install.sh --detect-thermal has
# confirmed a DS18B20 actually answers on the 1-Wire bus (see
# settings.conf's [thermal] section). Empty/'0' means no sensor wired here -
# don't burn a cycle attempting and warning about a read that will never
# succeed. battery_temperature_c in the MPPT snapshot (STEP 1) covers this
# station on the dashboard instead, at no extra upload cost.
if [ "${thermal_sensor_present:-0}" = "1" ]; then
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Thermal sensor not detected (thermal_sensor_present is not '1'), skipping."
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
# tolerates being late: STEP 5 below leaves an unsynced .ubx on disk to
# retry next run, unlike the point-in-time snapshots above, which have no
# such recovery if this run runs out of time or network).
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
    # Routed through _rclone_upload_or_warn like the other three sources
    # (see its own comment above) rather than a bare `rclone move` - this
    # was the one upload step that stayed silent on failure: STEP 5 below
    # can tell *that* a sync failed (no "Moved"/"Copied" in the log) but
    # never printed *why* (rate limit, auth, timeout...), since nothing
    # tailed this step's own log before it got deleted at the end of this
    # script regardless of outcome. The return value only feeds
    # any_upload_succeeded below (STEP 0/5b's failure accounting) - STEP 5's
    # own log grep is still what decides per-file keep/delete, since a
    # partial "some files moved, some didn't" outcome is still a success
    # here but needs the finer-grained per-file check there.
    if _rclone_upload_or_warn "$RCLONE_LOG_GNSS" "GNSS batch" move "./" "${GDRIVE_GNSS_REMOTE}" \
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
        --log-level INFO
    then
        any_upload_succeeded=1
    fi
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - No GNSS files ready for upload."
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

# ----------------- STEP 6: LTE MODEM POWER-SAVING (upload_window mode) -----------------
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
release_lte_hold
if [ "${lte_schedule_mode:-fixed_window}" = "upload_window" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploads done (upload_window mode), switching LTE modem off..."
    bash "${BASEDIR}/tools/lte_off.sh"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Batch job finished."

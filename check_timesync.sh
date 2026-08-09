#!/bin/bash
#
# script to check if the system date & time is synced.
# It is used to be sure that the logfile name will be correct.

# if you want to use your gnss receiver to set time date and maybe use pps, you need
# to change this script to use ntpstat instead of timedatectl and modifying the str2str_file.service unit file dependencies
# to ntp.service or something else.

# Bounded wait, not an infinite one: if NTP sync never completes (e.g. a
# network blip - which can happen for the same reasons a flaky USB bus
# does, like an undervoltage event knocking out more than just the GNSS
# receiver), this used to loop forever with no way out. run_cast.sh's
# "out_file" case only starts the real str2str process after this
# returns, so a permanent loop here meant str2str never started at all -
# yet the wrapper script (this whole call chain) was still technically
# running, so systemd saw str2str_file.service as active and never
# restarted it. Timing out and returning failure lets run_cast.sh exit
# non-zero instead, which Restart=on-failure can actually act on.
#
# Kept comfortably under systemd's default TimeoutStartSec (90s, and
# str2str_file.service doesn't override it) so this script's own timeout
# fires - with its clearer log message - before systemd's blunter
# "took too long to start" kill does.
MAX_WAIT_SECONDS=${CHECK_TIMESYNC_MAX_WAIT:-60}
waited=0
while ! timedatectl show | grep -q 'NTPSynchronized=yes'; do
    if [ "${waited}" -ge "${MAX_WAIT_SECONDS}" ]; then
        echo "check_timesync.sh: NTP still not synced after ${MAX_WAIT_SECONDS}s, giving up"
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done
exit 0

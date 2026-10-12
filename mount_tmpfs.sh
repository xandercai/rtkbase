#!/bin/bash
# =====================================================================
# RTKBase RAM disk (tmpfs) + persistent journal configuration
# Must be executed as root after installation, then reboot:
#   sudo ./mount_tmpfs.sh && sudo reboot
#
# What goes where:
#   /tmp, /var/tmp   -> tmpfs (scratch files, rclone logs, MPPT samples)
#   GNSS data dir    -> SD card. Data waiting for an LTE window has to
#                       survive a brown-out or a reboot, and a multi-day
#                       outage can need more than any RAM disk could hold.
#   systemd journal  -> SD card, capped at 50 MB, so the reason a station
#                       went dark is still there after it's power-cycled.
#
# Earlier versions also put /var/log on tmpfs (which lost every log at each
# reboot) and tried to put the data dir on a 512 MB tmpfs (which, through a
# bug, ended up mounted on an unused /data instead). Both entries are
# removed from /etc/fstab here if present. Safe to run more than once.
# =====================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo (sudo ./mount_tmpfs.sh)."
  exit 1
fi

# --- 1. drop the legacy /var/log and data-dir tmpfs entries ---------------
if awk '$1=="tmpfs" && ($2=="/var/log" || $2=="/data" || $2 ~ /\/rtkbase\/data\/?$/) {found=1} END {exit !found}' /etc/fstab; then
    cp /etc/fstab /etc/fstab.rtkbase.bak
    awk '!($1=="tmpfs" && ($2=="/var/log" || $2=="/data" || $2 ~ /\/rtkbase\/data\/?$/))' /etc/fstab.rtkbase.bak > /etc/fstab
    echo "Removed legacy /var/log and data-dir tmpfs entries from /etc/fstab (backup: /etc/fstab.rtkbase.bak)."
fi

# --- 2. /tmp and /var/tmp on tmpfs ---------------------------------------
for mount_point in /tmp /var/tmp; do
    if ! awk -v mp="$mount_point" '$1=="tmpfs" && $2==mp {found=1} END {exit !found}' /etc/fstab; then
        echo "tmpfs ${mount_point} tmpfs defaults,noatime,mode=1777,size=100M 0 0" >> /etc/fstab
        echo "Added tmpfs entry for ${mount_point}."
    else
        echo "tmpfs entry for ${mount_point} already present, skipping."
    fi
done

# --- 3. persistent, size-capped systemd journal --------------------------
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/rtkbase.conf << 'EOF'
# Written by rtkbase mount_tmpfs.sh: keep the journal across reboots so a
# station's last hours before going dark can still be read afterwards,
# while bounding SD card usage.
[Journal]
Storage=persistent
SystemMaxUse=50M
SystemMaxFileSize=10M
SystemKeepFree=500M
EOF
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
echo "Persistent journal enabled (max 50 MB) in /etc/systemd/journald.conf.d/rtkbase.conf."

echo "-------------------------------------------------------"
echo " tmpfs entries in /etc/fstab:"
awk '$1=="tmpfs"' /etc/fstab
echo "-------------------------------------------------------"
echo "Configuration completed. Reboot to apply: sudo reboot"

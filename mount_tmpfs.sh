#!/bin/bash
# =====================================================================
# RTKBase RAM disk (tmpfs) + persistent journal configuration
# Must be executed as root after installation, then reboot:
#   sudo ./mount_tmpfs.sh && sudo reboot
#
#   GNSS data dir   -> tmpfs (ram_data_max_mb)
#   overflow_dir    -> SD card, used by archive_and_clean.sh when RAM is full
#   /tmp, /var/tmp  -> tmpfs
#   systemd journal -> SD card, max 50 MB
#
# Also removes the old /var/log and /data tmpfs entries. Safe to re-run,
# e.g. after changing ram_data_max_mb.
# =====================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo (sudo ./mount_tmpfs.sh)."
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
if [ "$TARGET_USER" = "root" ]; then
    echo "Error: The identified user is 'root'."
    echo "Please log in as the rtkbase user and run: sudo ./mount_tmpfs.sh"
    exit 1
fi
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")

RTKBASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="${RTKBASE_DIR}/settings.conf"
[ -f "$SETTINGS_FILE" ] || SETTINGS_FILE="${RTKBASE_DIR}/settings.conf.default"

# datadir may still be '$BASEDIR/data'
BASEDIR="${RTKBASE_DIR}"
source <( grep -v '^#' "$SETTINGS_FILE" | grep -E '^(datadir|overflow_dir|ram_data_max_mb)=' )
DATA_DIR="${datadir:-${RTKBASE_DIR}/data}"
DATA_DIR="${DATA_DIR#file://}"
DATA_DIR="${DATA_DIR%/}"
OVERFLOW_DIR="${overflow_dir:-${RTKBASE_DIR}/data_overflow}"
RAM_MB="${ram_data_max_mb:-256}"
[[ "$RAM_MB" =~ ^[0-9]+$ ]] || { echo "Error: ram_data_max_mb='${RAM_MB}' is not a number."; exit 1; }

echo "======================================================="
echo " User:          $TARGET_USER (UID: $TARGET_UID, GID: $TARGET_GID)"
echo " Data (RAM):    $DATA_DIR  (${RAM_MB} MB tmpfs)"
echo " Overflow (SD): $OVERFLOW_DIR"
echo "======================================================="

cp /etc/fstab /etc/fstab.rtkbase.bak

# --- 1. drop legacy entries and any previous entry for the data dir ------
awk -v dd="$DATA_DIR" '!($1=="tmpfs" && ($2=="/var/log" || $2=="/data" || $2==dd || $2==dd"/"))' \
    /etc/fstab.rtkbase.bak > /etc/fstab

# --- 2. tmpfs entries ------------------------------------------------------
for mount_point in /tmp /var/tmp; do
    if ! awk -v mp="$mount_point" '$1=="tmpfs" && $2==mp {found=1} END {exit !found}' /etc/fstab; then
        echo "tmpfs ${mount_point} tmpfs defaults,noatime,mode=1777,size=100M 0 0" >> /etc/fstab
    fi
done
echo "tmpfs ${DATA_DIR} tmpfs defaults,noatime,mode=0775,size=${RAM_MB}M,uid=${TARGET_UID},gid=${TARGET_GID} 0 0" >> /etc/fstab
echo "fstab updated (backup: /etc/fstab.rtkbase.bak)."

# --- 3. data dir + SD overflow dir ----------------------------------------
mkdir -p "$DATA_DIR" "$OVERFLOW_DIR"
# files already in the data dir on the SD card would be hidden by the
# tmpfs: move them to the overflow dir, they get uploaded from there
if ! mountpoint -q "$DATA_DIR"; then
    shopt -s nullglob
    leftovers=( "$DATA_DIR"/* )
    if [ ${#leftovers[@]} -gt 0 ]; then
        mv -- "${leftovers[@]}" "$OVERFLOW_DIR"/
        echo "Moved ${#leftovers[@]} existing file(s) from ${DATA_DIR} to ${OVERFLOW_DIR} (uploaded from there)."
    fi
fi
chown "${TARGET_UID}:${TARGET_GID}" "$DATA_DIR" "$OVERFLOW_DIR"
chown -R "${TARGET_UID}:${TARGET_GID}" "$OVERFLOW_DIR"
chmod 775 "$DATA_DIR" "$OVERFLOW_DIR"

# --- 4. persistent, size-capped systemd journal ---------------------------
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/rtkbase.conf << 'EOF'
# Written by rtkbase mount_tmpfs.sh
[Journal]
Storage=persistent
SystemMaxUse=50M
SystemMaxFileSize=10M
SystemKeepFree=500M
EOF
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
echo "Persistent journal enabled (max 50 MB)."

echo "-------------------------------------------------------"
echo " tmpfs entries in /etc/fstab:"
awk '$1=="tmpfs"' /etc/fstab
echo "-------------------------------------------------------"
echo "Configuration completed. Reboot to apply: sudo reboot"

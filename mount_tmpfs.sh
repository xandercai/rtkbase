#!/bin/bash
# =====================================================================
# RTKBase Standalone RAM Disk (tmpfs) Configuration Script
# Must be executed as root after installation and before rebooting:
# sudo ./mount_tmpfs.sh
# =====================================================================

# 1. Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo (sudo ./mount_tmpfs.sh)."
  exit 1
fi

# 2. Extract the original user who called sudo
TARGET_USER="${SUDO_USER:-$USER}"

# If the target user is still root, abort the script immediately to avoid path corruption
if [ "$TARGET_USER" = "root" ]; then
    echo "Error: The identified user is 'root'."
    echo "This can happen if you used 'sudo su' or executed the script directly as the root user."
    echo "Please log in as a normal user (e.g., 'pi' or 'base') and run: sudo ./mount_tmpfs.sh"
    exit 1
fi

# 3. Dynamically resolve paths using the parsed normal user
USER_HOME=$(eval echo "~$TARGET_USER")
RTKBASE_DIR="${USER_HOME}/rtkbase"

SETTINGS_FILE="${RTKBASE_DIR}/settings.conf"
DEFAULT_SETTINGS="${RTKBASE_DIR}/settings.conf.default"

# 4. Extract the datadir variable
if [ -f "$SETTINGS_FILE" ]; then
    source <(grep -v '^#' "$SETTINGS_FILE" | grep 'datadir=')
elif [ -f "$DEFAULT_SETTINGS" ]; then
    source <(grep -v '^#' "$DEFAULT_SETTINGS" | grep 'datadir=')
fi

# 5. Handle fallback data paths safely
if [ -z "$datadir" ]; then
    DATA_DIR="${RTKBASE_DIR}/data"
else
    # Remove file:// URI scheme to extract pure local path
    DATA_DIR=$(echo "$datadir" | sed 's|^file://||')
fi

# Extract UID and GID for permissions
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")

echo "======================================================="
echo " Configuring RAM disks (tmpfs) for RTKBase..."
echo " Normal User:       $TARGET_USER (UID: $TARGET_UID, GID: $TARGET_GID)"
echo " Target Data Path:  $DATA_DIR"
echo "======================================================="

# 6. Append standard system caches to /etc/fstab
if ! grep -q "tmpfs /tmp " /etc/fstab; then
    echo "Adding system tmpfs configurations to /etc/fstab..."
    cat << 'EOF' >> /etc/fstab
tmpfs /tmp tmpfs defaults,noatime,mode=1777,size=100M 0 0
tmpfs /var/log tmpfs defaults,noatime,mode=1777,size=100M 0 0
tmpfs /var/tmp tmpfs defaults,noatime,mode=1777,size=100M 0 0
EOF
    echo "System RAM disks appended."
else
    echo "System RAM disks already configured in /etc/fstab. Skipping."
fi

# 7. Create physical directories and set ownership
if [ ! -d "$DATA_DIR" ]; then
    echo "Creating directory: $DATA_DIR"
    mkdir -p "$DATA_DIR"
fi
chown -R "${TARGET_USER}:${TARGET_USER}" "$DATA_DIR"
chmod 775 "$DATA_DIR"

# 8. Add the data directory tmpfs entry to /etc/fstab
if ! grep -q "tmpfs $DATA_DIR " /etc/fstab; then
    echo "Adding data folder tmpfs entry to /etc/fstab..."
    # 512MB RAM storage linked to the exact user's UID and GID
    echo "tmpfs $DATA_DIR tmpfs defaults,noatime,mode=0775,size=512M,uid=${TARGET_UID},gid=${TARGET_GID} 0 0" >> /etc/fstab
    echo "Data directory RAM disk appended."
else
    echo "Data directory RAM disk already configured in /etc/fstab. Skipping."
fi

# 9. Activate mounting instantly
echo "Activating all RAM disks..."
mount -a

# Output the result to verify
echo "-------------------------------------------------------"
echo " Current tmpfs Mounting Verification:"
df -h | grep -E 'tmpfs|/tmp|/var/log|/var/tmp|data'
echo "-------------------------------------------------------"

echo "Configuration completed successfully. You can now type 'sudo reboot'."

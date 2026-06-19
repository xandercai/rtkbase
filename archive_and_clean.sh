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
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
RCLONE_CONF_TMP="/tmp/rclone.conf"

MODEM_PORT="/dev/ttyACM0"

# ============================================================
# 函数：发送 AT 指令到调制解调器
# ============================================================
send_at() {
    local cmd="$1"
    local wait="${2:-3}"  # 默认等待 3 秒
    echo -e "${cmd}\r" > "${MODEM_PORT}"
    sleep "${wait}"
}

# ============================================================
# 函数：唤醒调制解调器（退出飞行模式）
# ============================================================
modem_wake() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 唤醒调制解调器（退出飞行模式）..."
    send_at "AT+CFUN=1" 3

    # 等待 usb0 重新上线，最多等 60 秒
    local waited=0
    while [ $waited -lt 60 ]; do
        if ip link show usb0 2>/dev/null | grep -q "UP"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 调制解调器已上线"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # 等待 NetworkManager 重新建立连接
    sleep 5
    nmcli connection up netplan-eth0 2>/dev/null || true

    # 再等网络可达
    local net_waited=0
    while [ $net_waited -lt 60 ]; do
        if ping -c1 -W3 8.8.8.8 &>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 网络已就绪"
            return 0
        fi
        sleep 3
        net_waited=$((net_waited + 3))
    done

    echo "$(date '+%Y-%m-%d %H:%M:%S') - 警告：网络未能在 60 秒内就绪，继续尝试上传..."
}

# ============================================================
# 函数：进入飞行模式（关闭无线通讯省电）
# ============================================================
modem_sleep() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 调制解调器进入飞行模式（省电）..."
    nmcli connection down netplan-eth0 2>/dev/null || true
    sleep 2
    send_at "AT+CFUN=4" 2
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 飞行模式已启用"
}

# ============================================================
# 主逻辑开始
# ============================================================

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

# ----------------- STEP 1: COMPRESSION ONLY -----------------
processed_files=()
HOSTNAME=$(hostname)

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

if [ ${#processed_files[@]} -eq 0 ]; then
    echo "No files ready for upload."
    exit 0
fi

# ----------------- STEP 2: 唤醒 LTE，准备上传 -----------------
modem_wake

# ----------------- STEP 3: BATCH UPLOAD VIA SINGLE RCLONE CALL -----------------
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting batch upload to Google Drive..."

RCLONE_LOG="/tmp/rclone_upload.log"

rclone move "./" "${GDRIVE_REMOTE}" \
    --config "${RCLONE_CONF_TMP}" \
    --no-update-modtime \
    --include "*.7z" \
    --transfers 4 \
    --checkers 8 \
    --tpslimit 10 \
    --log-level INFO \
    --log-file "$RCLONE_LOG"

# ----------------- STEP 4: SAFE CLEANUP OF ORIGINAL SOURCE FILES -----------------
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

rm -f "$RCLONE_LOG"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Batch job finished."

# ----------------- STEP 5: 上传完毕，进入飞行模式省电 -----------------
modem_sleep
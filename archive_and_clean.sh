#!/bin/bash

# If the target user is still root, abort the script immediately to avoid path corruption
if [ "$HOME" = "/root" ]; then
    echo "Error: The identified user is 'root'."
    echo "This can happen if you used 'sudo su' or executed the script directly as the root user."
    echo "Please log in as a normal user (e.g., 'pi' or 'base') and run: sudo ./mount_tmpfs.sh"
    exit 1
fi

BASEDIR="$(dirname "$0")"
# load config
source <( grep -v '^#' "${BASEDIR}"/settings.conf | grep '=' )

GDRIVE_REMOTE="gdrive:GNSS_IR_Data"  # you may need to change this to your actual rclone remote name and path
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
RCLONE_CONF_TMP="/tmp/rclone.conf"

# Writable RAM copy of rclone.conf to stop Token Refresh Read-Only errors
if [ ! -f "$RCLONE_CONF_TMP" ]; then
    if [ -f "$RCLONE_CONF" ]; then
        cp "$RCLONE_CONF" "$RCLONE_CONF_TMP"
        echo "copy ${RCLONE_CONF} to ${RCLONE_CONF_TMP}"
    else
        echo "Error：${RCLONE_CONF} does not exist, please check your rclone installation and configuration."
        exit 1
    fi
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Scan and upload new .ubx files in ${datadir} before ${buffer_minutes} mins..."

cd "${datadir}" || exit 1

for file in *.ubx; do
    [[ -e "$file" ]] || continue

    # default 5 time in minutes to avoid processing files that are still being written
    if [[ $(find "$file" -mmin +5) ]]; then
        echo "Compressing raw data file: $file"
        # gzip -c "$file" > "${file}.gz"  # backup method: gzip, faster but less compression

        7z a -t7z -m0=lzma2 -mx=9 -md=128m -mfb=273 -ms=on -mhc=on "${file}.7z" "$file" >/dev/null 2>&1
        # -t7z: Forces the 7z archive format, which has a higher compression density than .zip or .gz.
        # -m0=lzma2: Employs the LZMA2 algorithm, which achieves significantly better data-tightness than Deflate (gzip) or Zstd.
        # -mx=9: Sets the compression level to "Ultra".
        # -md=128m: Sets the Dictionary Size to 128 Megabytes. If GNSS file is 15MB, a 128MB dictionary ensures the algorithm analyzes the entire file as a single block, maximizing pattern matching.
        # -mfb=273: Sets the Fast Bytes length to 273 (the maximum possible). This forces the engine to meticulously scan for the longest possible matching strings of data.
        # -ms=on: Enables Solid Archiving. It binds all data into a single continuous stream, which yields massive space savings if you compress multiple files or text blocks.
        # -mhc=on: Compresses the archive headers themselves, shrinking the final file by a few extra kilobytes.

        # upload to Google Drive
        # rclone move "${file}.gz" "${GDRIVE_REMOTE}" --config "${RCLONE_CONF_TMP}" --no-update-modtime
        rclone move "${file}.7z" "${GDRIVE_REMOTE}" --config "${RCLONE_CONF_TMP}" --no-update-modtime

        if [ $? -eq 0 ]; then
            echo "Sync successfully, delete source file: $file"
            rm -f "$file"
        else
            echo "Sync failed, try again later: $file"
            # rm -f "${file}.gz"
            rm -f "${file}.7z"
        fi
    fi
done

#!/bin/bash

# Script to manage initramfs hooks for LVM/Partition root volume resizing.
# WARNING: This performs potentially dangerous operations. Use with extreme caution.
# ALWAYS BACK UP YOUR DATA AND TEST IN A VM FIRST.
# For 'partition' mode, this script will ONLY shrink the FILESYSTEM.
# You will need to resize the PARTITION itself manually afterwards (e.g. GParted).

PREMOUNT_SCRIPT_NAME="zz-resize-root-fs"
HOOK_SCRIPT_NAME="zz-resize-tools"

PREMOUNT_SCRIPT_PATH="/etc/initramfs-tools/scripts/local-premount/${PREMOUNT_SCRIPT_NAME}"
HOOK_SCRIPT_PATH="/etc/initramfs-tools/hooks/${HOOK_SCRIPT_NAME}"

# Log pattern used by the initramfs premount script
INITRAMFS_LOG_PATTERN="INITRAMFS-RESIZE (${PREMOUNT_SCRIPT_NAME})"
# Log pattern used by the initramfs hook script (during update-initramfs)
HOOK_LOG_PATTERN="HOOK_SCRIPT (${HOOK_SCRIPT_NAME})"


if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (except for the 'log' command which can be run by any user with dmesg access)." >&2
  # Allow log command without root if it's the only arg
  if [ "$1" != "log" ] || [ "$#" -ne 1 ]; then
    exit 1
  fi
fi

write_hook_script() {
  echo "Writing hook script to ${HOOK_SCRIPT_PATH}..."
  cat << EOF > "${HOOK_SCRIPT_PATH}"
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\$1" in
    prereqs) prereqs; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

HOST_GNU_DATE_PATH="/bin/date"

log_build_msg() {
    echo "${HOOK_LOG_PATTERN}: \$1" >&2
}

log_build_msg "Copying common utilities..."
copy_exec /usr/bin/numfmt /bin
copy_exec /bin/bash /bin
copy_exec /sbin/e2fsck /sbin
copy_exec /sbin/resize2fs /sbin
copy_exec /sbin/tune2fs /sbin
copy_exec "\$HOST_GNU_DATE_PATH" "/bin"
copy_exec /sbin/blkid /sbin
copy_exec /usr/bin/awk /usr/bin
copy_exec /bin/sed /bin
copy_exec /usr/bin/basename /usr/bin
copy_exec /usr/bin/dirname /usr/bin
copy_exec /bin/cat /bin

if [ "\$INITRAMFS_RESIZE_MODE" = "lvm" ]; then
    log_build_msg "Copying LVM specific utilities (lvm, dmsetup, fsadm)..."
    copy_exec /sbin/lvm /sbin
    copy_exec /sbin/dmsetup /sbin
    copy_exec /sbin/fsadm /sbin
else
    log_build_msg "Skipping LVM specific utilities for partition mode."
fi
exit 0
EOF
  chmod +x "${HOOK_SCRIPT_PATH}"
  echo "Hook script written and made executable."
}

write_premount_script() {
  local mode="$1"
  local target_size="$2"
  echo "Writing premount script to ${PREMOUNT_SCRIPT_PATH} for mode '${mode}' with target size ${target_size}..."

  # Start the heredoc for the generated script
  cat << EOF > "${PREMOUNT_SCRIPT_PATH}"
#!/bin/sh
# Managed by reboot_resize.sh
# Mode for this instance: ${mode}

DO_RESIZE=1
TARGET_SIZE="__TARGET_SIZE__" # Placeholder for FS size or LV size
SCRIPT_MODE="${mode}" # Embed the mode into the initramfs script

log_msg() {
    echo "${INITRAMFS_LOG_PATTERN}: \$1" >&2
    echo "${INITRAMFS_LOG_PATTERN}: \$1" >/dev/kmsg
}

if [ "\$DO_RESIZE" -ne 1 ]; then
    log_msg "DO_RESIZE is not 1. Skipping resize."
    exit 0
fi

if [ -z "\$ROOT" ] || ! [ -b "\$ROOT" ]; then
    log_msg "ERROR: \$ROOT ('\$ROOT') is not set or not a block device. Skipping resize."
    exit 0
fi

ROOT_DEVICE_FOR_FS="\$ROOT"

RESIZED_FLAG_SUFFIX=\$(echo "\${ROOT_DEVICE_FOR_FS##*/}_\${TARGET_SIZE}" | tr -cd '[:alnum:]_-')
RESIZED_FLAG="/run/root_fs_resized_\${RESIZED_FLAG_SUFFIX}"

if [ -f "\$RESIZED_FLAG" ]; then
    log_msg "Resize flag '\$RESIZED_FLAG' exists for '\$ROOT_DEVICE_FOR_FS'. Assuming already resized to \$TARGET_SIZE. Skipping."
    exit 0
fi

REQUIRED_TOOLS_COMMON="e2fsck blkid numfmt resize2fs bash date awk sed basename dirname cat tune2fs"
REQUIRED_TOOLS_LVM="lvm dmsetup fsadm"
# REQUIRED_TOOLS_PARTITION="parted" # If doing partition table ops

MISSING_TOOLS=""
for tool_cmd in \$REQUIRED_TOOLS_COMMON; do
    if ! command -v "\$tool_cmd" >/dev/null 2>&1; then
        MISSING_TOOLS="\${MISSING_TOOLS} \$tool_cmd"
    fi
done

# Conditionally check mode-specific tools INSIDE the initramfs script
if [ "\$SCRIPT_MODE" = "lvm" ]; then
    for tool_cmd in \$REQUIRED_TOOLS_LVM; do
        if ! command -v "\$tool_cmd" >/dev/null 2>&1; then
            MISSING_TOOLS="\${MISSING_TOOLS} \$tool_cmd"
        fi
    done
# elif [ "\$SCRIPT_MODE" = "partition" ]; then
    # if [ -n "\$REQUIRED_TOOLS_PARTITION" ]; then # Check if var is non-empty
    # for tool_cmd in \$REQUIRED_TOOLS_PARTITION; do
        # if ! command -v "\$tool_cmd" >/dev/null 2>&1; then
            # MISSING_TOOLS="\${MISSING_TOOLS} \$tool_cmd"
        # fi
    # done
    # fi
fi

if [ -n "\$MISSING_TOOLS" ]; then
    log_msg "ERROR: Required tools missing in initramfs: \${MISSING_TOOLS} for '\$ROOT_DEVICE_FOR_FS' (mode: \$SCRIPT_MODE). Skipping resize."
    exit 0
fi
log_msg "All required base commands found for '\$ROOT_DEVICE_FOR_FS' (mode: \$SCRIPT_MODE)."

FSTYPE=\$(blkid -s TYPE -o value "\$ROOT_DEVICE_FOR_FS" 2>/dev/null || blkid -p -s TYPE -o value "\$ROOT_DEVICE_FOR_FS" 2>/dev/null)
log_msg "Detected filesystem type: '\$FSTYPE' on '\$ROOT_DEVICE_FOR_FS'"

if ! echo "\$FSTYPE" | grep -qE '^ext[234]\$'; then
    log_msg "ERROR: Unsupported filesystem type '\$FSTYPE' for '\$ROOT_DEVICE_FOR_FS'. Skipping resize."
    touch "\$RESIZED_FLAG" >/dev/null 2>&1
    exit 0
fi

log_msg "Step 1: Filesystem check (e2fsck) on '\$ROOT_DEVICE_FOR_FS' before resize."
e2fsck -fy "\$ROOT_DEVICE_FOR_FS"
E2FSCK_EC=\$?
if [ "\$E2FSCK_EC" -gt 1 ]; then
    log_msg "ERROR: e2fsck on '\$ROOT_DEVICE_FOR_FS' failed (code \$E2FSCK_EC). Skipping resize."
    exit 0
fi
log_msg "e2fsck completed (exit code \$E2FSCK_EC) for '\$ROOT_DEVICE_FOR_FS'."

# --- Main conditional logic based on SCRIPT_MODE ---
if [ "\$SCRIPT_MODE" = "lvm" ]; then
    # --- LVM Mode Logic ---
    log_msg "Executing LVM mode logic for '\$ROOT_DEVICE_FOR_FS' to target size '\$TARGET_SIZE'."
    ROOT_LV_PATH=""
    DM_INFO=\$(dmsetup info -c --noheadings -o LV_NAME,VG_NAME "\$ROOT_DEVICE_FOR_FS" 2>/dev/null)
    if [ -n "\$DM_INFO" ]; then
        LV_NAME=\$(echo "\$DM_INFO" | awk '{print \$1}')
        VG_NAME=\$(echo "\$DM_INFO" | awk '{print \$2}')
        if [ -n "\$LV_NAME" ] && [ -n "\$VG_NAME" ]; then
            ROOT_LV_PATH="/dev/\$VG_NAME/\$LV_NAME"
            log_msg "LVM Mode: Derived ROOT_LV_PATH='\$ROOT_LV_PATH' from '\$ROOT_DEVICE_FOR_FS'."
        fi
    fi
    if [ -z "\$ROOT_LV_PATH" ]; then
        VG_NAME_PARSE=\$(echo "\$ROOT_DEVICE_FOR_FS" | sed -n 's|^/dev/mapper/\\(.*\\)-\\(.*\\)\$|\\1|p')
        LV_NAME_PARSE=\$(echo "\$ROOT_DEVICE_FOR_FS" | sed -n 's|^/dev/mapper/\\(.*\\)-\\(.*\\)\$|\\2|p')
        if [ -n "\$VG_NAME_PARSE" ] && [ -n "\$LV_NAME_PARSE" ]; then
            ROOT_LV_PATH="/dev/\$VG_NAME_PARSE/\$LV_NAME_PARSE"
            log_msg "LVM Mode: Derived ROOT_LV_PATH='\$ROOT_LV_PATH' by parsing mapper name."
        fi
    fi
    if [ -z "\$ROOT_LV_PATH" ]; then
        log_msg "LVM Mode ERROR: Failed to derive LVM path for '\$ROOT_DEVICE_FOR_FS'. Skipping resize."
        exit 0
    fi

    CURRENT_LV_SIZE_BYTES=\$(lvm lvs --noheadings --nosuffix -o lv_size --units b "\$ROOT_LV_PATH" 2>/dev/null | awk '{print \$1}')
    TARGET_LV_SIZE_BYTES=\$(echo "\$TARGET_SIZE" | numfmt --from=iec 2>/dev/null)

    if [ -z "\$CURRENT_LV_SIZE_BYTES" ]; then
        log_msg "LVM Mode ERROR: Could not determine current size of LV '\$ROOT_LV_PATH'. Skipping."
        exit 0
    fi
    if [ -z "\$TARGET_LV_SIZE_BYTES" ]; then
        log_msg "LVM Mode ERROR: Could not convert target size '\$TARGET_SIZE' to bytes for '\$ROOT_LV_PATH'. Skipping."
        exit 0
    fi
    log_msg "LVM Mode: Current LV size for '\$ROOT_LV_PATH': \$CURRENT_LV_SIZE_BYTES bytes. Target: \$TARGET_LV_SIZE_BYTES bytes (\$TARGET_SIZE)."

    if [ "\$CURRENT_LV_SIZE_BYTES" -le "\$TARGET_LV_SIZE_BYTES" ]; then
        log_msg "LVM Mode: LV '\$ROOT_LV_PATH' is already at or below target size. No resize needed."
        # Still touch the flag as the "operation" for this size is complete.
        touch "\$RESIZED_FLAG" >/dev/null 2>&1
        exit 0
    fi

    log_msg "LVM Mode: Starting resize for LV '\$ROOT_LV_PATH' to '\$TARGET_SIZE' using lvresize --resizefs"
    LVM_FORCE_OPT="--yes"
    if ! lvm lvresize --help 2>&1 | grep -q -- '--yes'; then LVM_FORCE_OPT="-f"; fi
    lvm lvresize "\$LVM_FORCE_OPT" --size "\$TARGET_SIZE" --resizefs "\$ROOT_LV_PATH"
    LVRESIZE_EC=\$?
    if [ \$LVRESIZE_EC -ne 0 ]; then
        log_msg "LVM Mode ERROR: 'lvm lvresize --resizefs' failed for '\$ROOT_LV_PATH' (code \$LVRESIZE_EC). CRITICAL!"
        exit 0
    fi
    log_msg "LVM Mode SUCCESS: LV '\$ROOT_LV_PATH' resize to '\$TARGET_SIZE' completed."

elif [ "\$SCRIPT_MODE" = "partition" ]; then
    # --- Partition Mode Logic ---
    log_msg "Executing Partition mode logic for '\$ROOT_DEVICE_FOR_FS' to target FS size '\$TARGET_SIZE'."
    TARGET_FS_SIZE_BYTES=\$(echo "\$TARGET_SIZE" | numfmt --from=iec 2>/dev/null)
    if [ -z "\$TARGET_FS_SIZE_BYTES" ]; then
        log_msg "Partition Mode ERROR: Could not convert target FS size '\$TARGET_SIZE' to bytes. Skipping."
        exit 0
    fi
    CURRENT_FS_SIZE_BYTES_RAW=\$(tune2fs -l "\$ROOT_DEVICE_FOR_FS" | grep 'Block count:' | awk '{print \$3}')
    CURRENT_BLOCK_SIZE_RAW=\$(tune2fs -l "\$ROOT_DEVICE_FOR_FS" | grep 'Block size:' | awk '{print \$3}')

    if [ -z "\$CURRENT_FS_SIZE_BYTES_RAW" ] || [ -z "\$CURRENT_BLOCK_SIZE_RAW" ]; then
        log_msg "Partition Mode ERROR: Could not determine current FS size details via tune2fs for '\$ROOT_DEVICE_FOR_FS'. Skipping."
        exit 0
    fi
    CURRENT_FS_SIZE_BYTES=\$((CURRENT_FS_SIZE_BYTES_RAW * CURRENT_BLOCK_SIZE_RAW))

    log_msg "Partition Mode: Current FS size for '\$ROOT_DEVICE_FOR_FS' is approx \$CURRENT_FS_SIZE_BYTES bytes."
    log_msg "Partition Mode: Target FS size is \$TARGET_FS_SIZE_BYTES bytes (\$TARGET_SIZE)."

    if [ "\$CURRENT_FS_SIZE_BYTES" -le "\$TARGET_FS_SIZE_BYTES" ]; then
        log_msg "Partition Mode: Filesystem on '\$ROOT_DEVICE_FOR_FS' is already at or below target size. No FS shrink needed."
        touch "\$RESIZED_FLAG" >/dev/null 2>&1
        exit 0
    fi
    log_msg "Partition Mode: Shrinking filesystem on '\$ROOT_DEVICE_FOR_FS' to '\$TARGET_SIZE'."
    resize2fs "\$ROOT_DEVICE_FOR_FS" "\$TARGET_SIZE"
    RESIZE2FS_EC=\$?
    if [ \$RESIZE2FS_EC -ne 0 ]; then
        log_msg "Partition Mode ERROR: 'resize2fs \$ROOT_DEVICE_FOR_FS \$TARGET_SIZE' failed (code \$RESIZE2FS_EC)."
        exit 0
    fi
    log_msg "Partition Mode SUCCESS: Filesystem on '\$ROOT_DEVICE_FOR_FS' shrunk to '\$TARGET_SIZE'."
    log_msg "IMPORTANT (Partition Mode): The PARTITION itself was NOT resized. You may need to do this manually using GParted from a live environment."
else
    log_msg "ERROR: Unknown SCRIPT_MODE '\$SCRIPT_MODE' in initramfs script. Skipping operations."
    exit 0
fi

# --- Common successful finish ---
touch "\$RESIZED_FLAG" >/dev/null 2>&1 || log_msg "Warning: Could not touch \$RESIZED_FLAG"
log_msg "Resize script finished for '\$ROOT_DEVICE_FOR_FS'. To prevent re-running, run 'reboot_resize.sh uninstall' after full boot."
exit 0
EOF

  # Replace the placeholder TARGET_SIZE
  sed -i "s|__TARGET_SIZE__|${target_size}|g" "${PREMOUNT_SCRIPT_PATH}"
  chmod +x "${PREMOUNT_SCRIPT_PATH}"
  echo "Premount script written and made executable."
}

do_install() {
  local mode="$1"
  local target_size="$2"

  if [ "$mode" != "lvm" ] && [ "$mode" != "partition" ]; then
    echo "Error: Invalid mode '$mode'. Must be 'lvm' or 'partition'." >&2
    usage; exit 1
  fi
  if [ -z "$target_size" ]; then
    echo "Error: Target size argument is missing for install." >&2
    usage; exit 1
  fi
  if ! echo "$target_size" | grep -qE '^[0-9.]+[GMKTgmk]$'; then
      echo "Error: Invalid target size format '$target_size'. Example: 10G, 500M." >&2
      exit 1
  fi

  echo "---"; echo "Mode: ${mode}"
  if [ "$mode" = "lvm" ]; then
    echo "WARNING: Will attempt to resize LVM root volume to '${target_size}' ON NEXT REBOOT."
  elif [ "$mode" = "partition" ]; then
    echo "WARNING: Will attempt to shrink the FILESYSTEM on the root partition to '${target_size}' ON NEXT REBOOT."
    echo "         The PARTITION ITSELF WILL NOT BE RESIZED by this script."
    echo "         You will need to resize the partition manually afterwards (e.g., with GParted)."
  fi
  echo "This is a DANGEROUS operation. Ensure you have backups."; echo "---"
  read -p "Are you absolutely sure you want to proceed? (yes/no): " confirmation
  if [ "$confirmation" != "yes" ]; then
    echo "Installation aborted by user."; exit 0
  fi

  export INITRAMFS_RESIZE_MODE="$mode"
  write_hook_script
  unset INITRAMFS_RESIZE_MODE

  write_premount_script "$mode" "$target_size"

  echo "Running 'update-initramfs -u' for current kernel..."
  if update-initramfs -u; then
    echo "update-initramfs completed successfully."
    echo ""; echo "Installation complete for mode '${mode}'. Operation scheduled for the next reboot."
    echo "After successful reboot and operation, run 'sudo $0 uninstall' to remove the hooks."
    echo "You can check logs with 'sudo $0 log' after reboot."
  else
    echo "Error: update-initramfs failed. Please check the output."; exit 1
  fi
}

do_uninstall() {
  echo "Uninstalling initramfs resize scripts..."
  rm -v "${PREMOUNT_SCRIPT_PATH}"
  rm -v "${HOOK_SCRIPT_PATH}"
  echo "Running 'update-initramfs -u' for current kernel..."
  if update-initramfs -u; then
    echo "update-initramfs completed successfully."
  else
    echo "Error: update-initramfs failed."; exit 1
  fi
}

do_log() {
  echo "Searching dmesg for initramfs resize script logs ('${INITRAMFS_LOG_PATTERN}')..."
  echo "--- Last 50 lines from dmesg containing the pattern ---"
  if dmesg | grep "${INITRAMFS_LOG_PATTERN}" ; then
    echo "--- End of matching log lines ---"
  else
    echo "No matching log entries found for '${INITRAMFS_LOG_PATTERN}' in dmesg."
  fi
  echo ""
  echo "You might also want to check the output of 'update-initramfs' during install/uninstall for hook script messages ('${HOOK_LOG_PATTERN}')."
}

usage() {
  echo "Usage: $0 <command> [arguments]"
  echo ""
  echo "Commands:"
  echo "  install <mode> <TARGET_SIZE> Install hooks for resize operation."
  echo "                                <mode> can be 'lvm' or 'partition'."
  echo "                                <TARGET_SIZE> e.g., '10G', '500M'."
  echo "  uninstall                     Remove installed hooks."
  echo "  log                           Display relevant log messages from dmesg."
  echo ""
  echo "Example (LVM): $0 install lvm 10G"
  echo "Example (Partition FS): $0 install partition 8G"
  echo ""
  echo "Run 'sudo $0 uninstall' after successful operation and reboot."
}

COMMAND="$1"

case "$COMMAND" in
  install)
    MODE_ARG="$2"
    TARGET_SIZE_ARG="$3"
    do_install "$MODE_ARG" "$TARGET_SIZE_ARG"
    ;;
  uninstall)
    do_uninstall
    ;;
  log)
    do_log
    ;;
  *)
    usage
    exit 1
    ;;
esac

exit 0

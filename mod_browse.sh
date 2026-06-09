#!/bin/bash
#==============================================================================
# mod_browse.sh
# Pre-wipe drive browser.
# Mounts target drive read-only and launches mc for inspection.
# Operator can view files in text or hex mode (F3/F4 in mc).
# No writes possible — mount is enforced read-only at kernel level.
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib_common.sh"

MNT_TARGET="/tmp/wd_target"

#──────────────────────────────────────────────────────────────────────────────
# MOUNT TARGET READ-ONLY
#──────────────────────────────────────────────────────────────────────────────
mount_target_ro() {
    local dev="$1"
    mkdir -p "$MNT_TARGET"

    # Unmount if already mounted
    umount "$MNT_TARGET" 2>/dev/null || true

    # Set kernel-level read-only flag first
    write_protect "$dev"

    # Try to mount first partition — most systems boot from sda1/nvme0n1p1
    local part
    part=$(lsblk -lnpo NAME "$dev" | sed -n '2p')

    if [[ -b "$part" ]]; then
        mount -o ro,noexec,nosuid "$part" "$MNT_TARGET" 2>/dev/null || \
        mount -o ro,noexec,nosuid,noload "$part" "$MNT_TARGET" 2>/dev/null || \
        mount -o ro,noexec,nosuid,force "$part" "$MNT_TARGET" 2>/dev/null || {
            audit_log "WARN" "Could not mount $part — filesystem may be encrypted or damaged"
            msg_box "Mount Failed" \
"Could not mount $part read-only.

Possible causes:
  • BitLocker / encryption active
  • Filesystem corruption
  • Unsupported filesystem type

You can still proceed with wipe/image."
            return 1
        }
    else
        msg_box "No Partitions" "No partitions found on $dev."
        return 1
    fi

    audit_log "INFO" "Mounted read-only: $part → $MNT_TARGET"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# LAUNCH MC (restricted to mount point, both panels)
#──────────────────────────────────────────────────────────────────────────────
launch_browser() {
    local dev="$1"

    info_box "Drive Browser" \
"Launching file browser.

  F3  = View file (text)
  F4  = View file (hex)
  F10 = Exit browser

Drive is READ-ONLY. No writes possible." 4

    # mc launched with both panels pointing to mount — subshell disabled
    # to prevent operator dropping to a shell via Ctrl+O
    mc --nosubshell "$MNT_TARGET" "$MNT_TARGET"

    audit_log "INFO" "Drive browser session ended: $dev"
}

#──────────────────────────────────────────────────────────────────────────────
# HEX VIEW — open a specific file directly in xxd | less
# Useful when mc hex viewer is too basic for binary analysis
#──────────────────────────────────────────────────────────────────────────────
launch_hex_viewer() {
    local dev="$1"

    # Let operator pick a file
    local file
    if ! browse_files "$MNT_TARGET" "Select File for Hex View"; then
        return
    fi
    file="$REPLY_PATH"

    [[ ! -f "$file" ]] && msg_box "Error" "Not a file: $file" && return

    audit_log "INFO" "Hex view: $file"

    # xxd piped to less — full hex dump with ASCII sidebar
    clear
    echo -e "${CYAN}Hex view: $file${NC}"
    echo -e "${DIM}Press q to exit, / to search, g for start, G for end${NC}"
    echo ""
    xxd "$file" | less -S
}

#──────────────────────────────────────────────────────────────────────────────
# SMART DATA — surface health before imaging/wiping
#──────────────────────────────────────────────────────────────────────────────
show_smart() {
    local dev="$1"

    if ! command -v smartctl &>/dev/null; then
        msg_box "SMART" "smartctl not available."
        return
    fi

    local tmpfile="/tmp/wd_smart_$$.txt"
    smartctl -a "$dev" > "$tmpfile" 2>&1
    cp "$tmpfile" "$LOG_DIR/smart_${SESSION_START}_$(basename "$dev").txt" 2>/dev/null || true
    audit_log "INFO" "SMART data collected: $dev"

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "SMART Data — $dev" \
           --textbox "$tmpfile" \
           22 78
    rm -f "$tmpfile"
}

#──────────────────────────────────────────────────────────────────────────────
# PARTITION TABLE
#──────────────────────────────────────────────────────────────────────────────
show_partition_table() {
    local dev="$1"
    local tmpfile="/tmp/wd_ptable_$$.txt"

    {
        echo "=== fdisk -l ==="
        fdisk -l "$dev" 2>&1
        echo ""
        echo "=== lsblk ==="
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev" 2>&1
        echo ""
        echo "=== parted ==="
        parted -s "$dev" print 2>&1
    } > "$tmpfile"

    cp "$tmpfile" "$LOG_DIR/ptable_${SESSION_START}_$(basename "$dev").txt" 2>/dev/null || true
    audit_log "INFO" "Partition table logged: $dev"

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "Partition Table — $dev" \
           --textbox "$tmpfile" \
           22 78
    rm -f "$tmpfile"
}

#──────────────────────────────────────────────────────────────────────────────
# BROWSE MENU
#──────────────────────────────────────────────────────────────────────────────
browse_menu() {
    local dev="$1"
    local serial
    serial=$(get_serial "$dev")
    local model
    model=$(get_drive_model "$dev")
    local dtype
    dtype=$(get_drive_type "$dev")
    local size
    size=$(get_drive_size "$dev")

    # Mount the drive
    if ! mount_target_ro "$dev"; then
        return
    fi

    while true; do
        local choice
        choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                        --title "Drive Browser — $dev" \
                        --menu \
"Target: $dev  |  $dtype  |  $size
Model : $model
Serial: $serial

Select an action:" \
                        18 65 7 \
                        "1" "Browse filesystem (mc)" \
                        "2" "Hex view — select file" \
                        "3" "View SMART data" \
                        "4" "View partition table" \
                        "5" "Back to main menu" \
                        3>&1 1>&2 2>&3)

        [[ $? -ne 0 || "$choice" == "5" ]] && break

        case "$choice" in
            1) launch_browser "$dev" ;;
            2) launch_hex_viewer "$dev" ;;
            3) show_smart "$dev" ;;
            4) show_partition_table "$dev" ;;
        esac
    done

    # Unmount cleanly
    umount "$MNT_TARGET" 2>/dev/null || true
    write_unprotect "$dev"
    audit_log "INFO" "Drive browser complete: $dev"
}
#!/bin/bash
#==============================================================================
# menu.sh
# WipeDeploy Forensic Toolkit — Main TUI
#
# Operator-facing interface. Restricted to this menu — no shell access.
# Auto-launched on TTY1 login via /etc/profile.d/wipedeploy.sh
#
# Flow:
#   1. Mount WDDATA
#   2. Detect system info + serial
#   3. Select target drive
#   4. Operator works through modules in any order
#   5. Wipe → Deploy (optional)
#   6. Report generated
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

# Source all modules
for mod in "$SCRIPT_DIR/modules"/mod_*.sh; do
    source "$mod"
done

# Global state
TARGET_DEV=""
SYS_SERIAL=""
WIPE_DONE=false

#──────────────────────────────────────────────────────────────────────────────
# STARTUP
#──────────────────────────────────────────────────────────────────────────────
startup() {
    banner
    require_dialog
    check_deps

    # Mount WDDATA
    info_box "Starting Up" "Mounting WDDATA partition..." 1
    mount_wddata

    # Get system serial
    SYS_SERIAL=$(get_system_serial)

    # Initialize session log
    session_init "$SYS_SERIAL"

    audit_log "INFO" "Toolkit started. System: $(get_system_model) Serial: $SYS_SERIAL"
}

#──────────────────────────────────────────────────────────────────────────────
# SELECT TARGET DRIVE
#──────────────────────────────────────────────────────────────────────────────
do_select_drive() {
    if ! select_target_drive; then
        msg_box "Cancelled" "No drive selected."
        return 1
    fi
    TARGET_DEV="$REPLY_DEVICE"
    local serial
    serial=$(get_serial "$TARGET_DEV")
    local model
    model=$(get_drive_model "$TARGET_DEV")
    local dtype
    dtype=$(get_drive_type "$TARGET_DEV")
    local size
    size=$(get_drive_size "$TARGET_DEV")

    msg_box "Target Drive Selected" \
"  Device : $TARGET_DEV
  Type   : $dtype
  Size   : $size
  Model  : $model
  Serial : $serial"

    audit_log "INFO" "Target selected: $TARGET_DEV serial=$serial model=$model"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# SYSTEM INFO DISPLAY
#──────────────────────────────────────────────────────────────────────────────
show_system_info() {
    local msdm
    msdm=$(get_msdm_key)
    [[ -n "$msdm" ]] && msdm="${msdm:0:5}XXXXX-XXXXX-XXXXX-XXXXX" || msdm="NOT FOUND"

    local tmpfile="/tmp/wd_sysinfo_$$.txt"
    {
        echo "System Information"
        echo ""
        echo "  Model     : $(get_system_model)"
        echo "  Serial    : $SYS_SERIAL"
        echo "  BIOS      : $(get_bios_version)"
        echo "  Kernel    : $(uname -r)"
        echo "  MSDM Key  : $msdm"
        echo ""
        echo "Target Drive:"
        if [[ -n "$TARGET_DEV" ]]; then
            echo "  Device    : $TARGET_DEV"
            echo "  Type      : $(get_drive_type "$TARGET_DEV")"
            echo "  Size      : $(get_drive_size "$TARGET_DEV")"
            echo "  Model     : $(get_drive_model "$TARGET_DEV")"
            echo "  Serial    : $(get_serial "$TARGET_DEV")"
        else
            echo "  (no drive selected)"
        fi
        echo ""
        echo "Storage:"
        df -h "$DATA_DIR" 2>/dev/null || echo "  WDDATA not mounted"
    } > "$tmpfile"

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "System Information" \
           --textbox "$tmpfile" \
           22 65
    rm -f "$tmpfile"
}

#──────────────────────────────────────────────────────────────────────────────
# REQUIRE TARGET DRIVE
#──────────────────────────────────────────────────────────────────────────────
require_target() {
    if [[ -z "$TARGET_DEV" ]]; then
        msg_box "No Drive Selected" \
"No target drive selected.

Select a target drive first from the main menu."
        return 1
    fi
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# WIPE + DEPLOY SEQUENCE (automated chain)
#──────────────────────────────────────────────────────────────────────────────
do_wipe_and_deploy() {
    require_target || return

    if ! confirm "Wipe + Deploy Sequence" \
"Run full automated sequence:

  1. NIST 800-88 wipe
  2. Partition for Windows
  3. Reboot → Ventoy → Windows install

All operator choices made upfront.
System reboots automatically after wipe.

Continue?"; then
        return
    fi

    # Wipe
    if wipe_drive "$TARGET_DEV"; then
        WIPE_DONE=true
        audit_log "INFO" "Wipe complete — proceeding to deploy"

        # Generate report before reboot
        generate_report "$SYS_SERIAL" "$TARGET_DEV"

        # Deploy
        REPLY_DEVICE="$TARGET_DEV"
        deploy_windows
    else
        msg_box "Wipe Failed" "Wipe did not complete. Deploy aborted."
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# MAIN MENU
#──────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        # Build status line for target drive
        local drive_status
        if [[ -n "$TARGET_DEV" ]]; then
            drive_status="$TARGET_DEV  $(get_drive_type "$TARGET_DEV")  $(get_drive_size "$TARGET_DEV")"
        else
            drive_status="(none selected)"
        fi

        local wipe_status
        $WIPE_DONE && wipe_status="COMPLETE" || wipe_status="pending"

        local choice
        choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                        --title "Main Menu" \
                        --menu \
"System : $(get_system_model)  |  Serial: $SYS_SERIAL
Target : $drive_status
Wipe   : $wipe_status

Select module:" \
                        22 68 14 \
                        "1"  "Select target drive" \
                        "2"  "System information" \
                        "──" "─── FORENSIC TOOLS ──────────────────" \
                        "3"  "Browse drive (mc + hex view)" \
                        "4"  "Forensic image (dcfldd / E01)" \
                        "5"  "Firmware dump (flashrom + CH341A)" \
                        "6"  "AV / YARA malware scan" \
                        "7"  "File carving (foremost/photorec/bulk)" \
                        "8"  "Network scan (nmap / tshark)" \
                        "──" "─── SANITIZE & DEPLOY ───────────────" \
                        "9"  "Wipe drive (NIST 800-88)" \
                        "10" "Deploy Windows (reboot → Ventoy)" \
                        "11" "Wipe + Deploy (automated sequence)" \
                        "──" "─── REPORTS ─────────────────────────" \
                        "12" "Generate / view reports" \
                        "0"  "Exit / shutdown" \
                        3>&1 1>&2 2>&3)

        [[ $? -ne 0 ]] && continue

        # Separator items — no action
        [[ "$choice" == "──" ]] && continue

        case "$choice" in
            1)  do_select_drive ;;
            2)  show_system_info ;;
            3)
                require_target || continue
                browse_menu "$TARGET_DEV"
                ;;
            4)
                require_target || continue
                image_drive "$TARGET_DEV"
                ;;
            5)
                firmware_menu "$SYS_SERIAL"
                ;;
            6)
                require_target || continue
                av_menu "$TARGET_DEV" "$SYS_SERIAL"
                ;;
            7)
                require_target || continue
                carve_menu "$TARGET_DEV" "$SYS_SERIAL"
                ;;
            8)
                network_menu "$SYS_SERIAL"
                ;;
            9)
                require_target || continue
                if wipe_drive "$TARGET_DEV"; then
                    WIPE_DONE=true
                fi
                ;;
            10)
                REPLY_DEVICE="$TARGET_DEV"
                deploy_windows
                ;;
            11)
                do_wipe_and_deploy
                ;;
            12)
                report_menu "$SYS_SERIAL" "$TARGET_DEV"
                ;;
            0)
                if confirm "Exit" "Exit WipeDeploy?\n\nSelect Yes to exit, No to return to menu."; then
                    session_close "OPERATOR_EXIT"
                    clear
                    echo -e "${CYAN}WipeDeploy session ended.${NC}"
                    echo ""
                    exit 0
                fi
                ;;
        esac
    done
}

#──────────────────────────────────────────────────────────────────────────────
# TRAP — clean up on unexpected exit
#──────────────────────────────────────────────────────────────────────────────
trap 'wipedeploy_cleanup; session_close "UNEXPECTED_EXIT"' EXIT INT TERM

#──────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
#──────────────────────────────────────────────────────────────────────────────
startup
main_menu
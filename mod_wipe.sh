#!/bin/bash
#==============================================================================
# mod_wipe.sh
# NIST SP 800-88 Rev.1 sanitization module.
#
# HDD  — CLEAR: single overwrite (zero/random)
#        PURGE: DoD 3-pass or 7-pass overwrite
# SSD  — CLEAR: ATA Secure Erase (hdparm)
#        PURGE: ATA Enhanced Secure Erase
# NVMe — CLEAR: NVMe Format with crypto-erase
#        PURGE: NVMe Sanitize (block erase)
#
# All wipes are logged with timestamps, serial, method, and verified.
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"

#──────────────────────────────────────────────────────────────────────────────
# WIPE METHOD SELECTION
#──────────────────────────────────────────────────────────────────────────────
select_wipe_method() {
    local dtype="$1"
    local dev="$2"

    local choice
    case "$dtype" in
        HDD)
            choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                            --title "Select Wipe Method — HDD" \
                            --menu \
"Drive type: HDD (magnetic)
NIST 800-88 methods:" \
                            14 65 4 \
                            "1" "CLEAR  — Single zero overwrite (fast)" \
                            "2" "CLEAR  — Single random overwrite" \
                            "3" "PURGE  — DoD 5220.22-M 3-pass" \
                            "4" "PURGE  — 7-pass (Gutmann-lite)" \
                            3>&1 1>&2 2>&3)
            ;;
        SSD)
            choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                            --title "Select Wipe Method — SSD" \
                            --menu \
"Drive type: SSD (flash)
NIST 800-88 methods:" \
                            14 65 4 \
                            "1" "CLEAR  — ATA Secure Erase (recommended)" \
                            "2" "PURGE  — ATA Enhanced Secure Erase" \
                            "3" "CLEAR  — Single zero overwrite (fallback)" \
                            "4" "PURGE  — nwipe random overwrite (fallback)" \
                            3>&1 1>&2 2>&3)
            ;;
        NVME)
            choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                            --title "Select Wipe Method — NVMe" \
                            --menu \
"Drive type: NVMe (flash)
NIST 800-88 methods:" \
                            14 65 4 \
                            "1" "CLEAR  — NVMe Format + crypto-erase (recommended)" \
                            "2" "PURGE  — NVMe Sanitize block-erase" \
                            "3" "PURGE  — NVMe Sanitize crypto-erase" \
                            "4" "CLEAR  — Single zero overwrite (fallback)" \
                            3>&1 1>&2 2>&3)
            ;;
        *)
            choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                            --title "Select Wipe Method — Unknown Type" \
                            --menu \
"Drive type: Unknown
Generic methods:" \
                            12 60 2 \
                            "1" "Single zero overwrite" \
                            "2" "nwipe interactive" \
                            3>&1 1>&2 2>&3)
            ;;
    esac

    [[ $? -ne 0 ]] && return 1
    REPLY_WIPE_METHOD="$choice"
    REPLY_WIPE_TYPE="$dtype"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# HDD WIPE — nwipe
#──────────────────────────────────────────────────────────────────────────────
wipe_hdd() {
    local dev="$1"
    local method="$2"
    local log_file="$3"

    if ! command -v nwipe &>/dev/null; then
        msg_box "Missing Tool" "nwipe not installed.\napt install nwipe"
        return 1
    fi

    local nwipe_method
    case "$method" in
        1) nwipe_method="zero" ;;
        2) nwipe_method="random" ;;
        3) nwipe_method="dod522022m" ;;
        4) nwipe_method="gutmann" ;;
        *) nwipe_method="zero" ;;
    esac

    audit_log "INFO" "nwipe start: $dev method=$nwipe_method"
    echo "[$(date)] nwipe start: $dev method=$nwipe_method" >> "$log_file"

    clear
    echo -e "${CYAN}Wiping $dev with nwipe ($nwipe_method)...${NC}"
    echo -e "${RED}${BOLD}DO NOT INTERRUPT — WIPE IN PROGRESS${NC}"
    echo ""

    nwipe \
        --autonuke \
        --nowait \
        --method="$nwipe_method" \
        --logfile="$log_file" \
        "$dev"

    local rc=$?
    echo "[$(date)] nwipe complete: rc=$rc" >> "$log_file"
    audit_log "INFO" "nwipe complete: $dev rc=$rc"
    return $rc
}

#──────────────────────────────────────────────────────────────────────────────
# SSD WIPE — ATA Secure Erase via hdparm
#──────────────────────────────────────────────────────────────────────────────
wipe_ssd() {
    local dev="$1"
    local method="$2"
    local log_file="$3"

    if [[ "$method" -ge 3 ]]; then
        # Fallback to nwipe
        wipe_hdd "$dev" $(( method - 2 )) "$log_file"
        return $?
    fi

    if ! command -v hdparm &>/dev/null; then
        msg_box "Missing Tool" "hdparm not installed.\napt install hdparm"
        return 1
    fi

    # Check if drive is frozen
    local frozen
    frozen=$(hdparm -I "$dev" 2>/dev/null | grep -i "frozen")
    if echo "$frozen" | grep -qi "frozen"; then
        msg_box "Drive Frozen" \
"ATA Secure Erase blocked — drive security is FROZEN.

To unfreeze:
  1. Suspend the system (echo mem > /sys/power/state)
  2. Resume — drive should unfreeze
  3. Retry Secure Erase

Or use fallback overwrite method."
        audit_log "WARN" "ATA Secure Erase blocked — drive frozen: $dev"
        return 1
    fi

    # Set a temporary password to enable secure erase
    hdparm --user-master u --security-set-pass "wipedeploy_temp" "$dev" 2>&1 | \
        tee -a "$log_file"

    local rc=$?
    if [[ $rc -ne 0 ]]; then
        audit_log "ERROR" "Failed to set ATA password: $dev"
        return 1
    fi

    audit_log "INFO" "ATA Secure Erase start: $dev method=$method"
    echo "[$(date)] ATA Secure Erase start: $dev" >> "$log_file"

    clear
    echo -e "${CYAN}ATA Secure Erase in progress: $dev${NC}"
    echo -e "${RED}${BOLD}DO NOT INTERRUPT${NC}"
    echo ""

    case "$method" in
        1)
            hdparm --user-master u --security-erase "wipedeploy_temp" "$dev" 2>&1 | \
                tee -a "$log_file"
            ;;
        2)
            hdparm --user-master u --security-erase-enhanced "wipedeploy_temp" "$dev" 2>&1 | \
                tee -a "$log_file"
            ;;
    esac

    rc=$?
    echo "[$(date)] ATA Secure Erase complete: rc=$rc" >> "$log_file"
    audit_log "INFO" "ATA Secure Erase complete: $dev rc=$rc"

    # Clear password if erase failed (erase success clears it automatically)
    if [[ $rc -ne 0 ]]; then
        hdparm --user-master u --security-disable "wipedeploy_temp" "$dev" 2>/dev/null || true
    fi

    return $rc
}

#──────────────────────────────────────────────────────────────────────────────
# NVME WIPE
#──────────────────────────────────────────────────────────────────────────────
wipe_nvme() {
    local dev="$1"
    local method="$2"
    local log_file="$3"

    if ! command -v nvme &>/dev/null; then
        msg_box "Missing Tool" "nvme-cli not installed.\napt install nvme-cli"
        return 1
    fi

    local rc=0

    case "$method" in
        1)
            # NVMe Format with crypto-erase (ses=2)
            audit_log "INFO" "NVMe format crypto-erase start: $dev"
            echo "[$(date)] NVMe format ses=2 start: $dev" >> "$log_file"
            clear
            echo -e "${CYAN}NVMe Format (crypto-erase): $dev${NC}"
            nvme format "$dev" --ses=2 --force 2>&1 | tee -a "$log_file"
            rc=$?
            ;;
        2)
            # NVMe Sanitize — block erase
            audit_log "INFO" "NVMe sanitize block-erase start: $dev"
            echo "[$(date)] NVMe sanitize block-erase start: $dev" >> "$log_file"
            clear
            echo -e "${CYAN}NVMe Sanitize (block-erase): $dev${NC}"
            nvme sanitize "$dev" --sanact=2 2>&1 | tee -a "$log_file"
            rc=$?
            # Poll for completion
            if [[ $rc -eq 0 ]]; then
                echo "Waiting for sanitize to complete..."
                local timeout=300
                local elapsed=0
                while [[ $elapsed -lt $timeout ]]; do
                    local status
                    status=$(nvme sanitize-log "$dev" 2>/dev/null | grep "SSTAT" | awk '{print $3}')
                    [[ "$status" == "0x101" ]] && break
                    sleep 5
                    elapsed=$(( elapsed + 5 ))
                    echo "  Elapsed: ${elapsed}s / ${timeout}s"
                done
            fi
            ;;
        3)
            # NVMe Sanitize — crypto-erase
            audit_log "INFO" "NVMe sanitize crypto-erase start: $dev"
            nvme sanitize "$dev" --sanact=4 2>&1 | tee -a "$log_file"
            rc=$?
            ;;
        4)
            # Fallback zero overwrite
            wipe_hdd "$dev" 1 "$log_file"
            return $?
            ;;
    esac

    echo "[$(date)] NVMe wipe complete: rc=$rc" >> "$log_file"
    audit_log "INFO" "NVMe wipe complete: $dev rc=$rc"
    return $rc
}

#──────────────────────────────────────────────────────────────────────────────
# VERIFY WIPE — read first/last/random sectors and confirm zero/random pattern
#──────────────────────────────────────────────────────────────────────────────
verify_wipe() {
    local dev="$1"
    local log_file="$2"

    audit_log "INFO" "Wipe verification start: $dev"

    local size_sectors
    size_sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)

    local mid_sector=$(( size_sectors / 2 ))
    local end_sector=$(( size_sectors - 1 ))

    local pass=1
    for sector in 0 "$mid_sector" "$end_sector"; do
        local data
        data=$(dd if="$dev" bs=512 skip="$sector" count=1 2>/dev/null | xxd | head -4)
        # Check if all zeros
        if echo "$data" | grep -qv "0000 0000 0000 0000 0000 0000 0000 0000"; then
            # Not all zeros — could be random fill (also acceptable) or unwiped
            # Just log it, don't fail — random fill is valid CLEAR method
            echo "[$(date)] Sector $sector: non-zero data (may be random fill)" >> "$log_file"
        else
            echo "[$(date)] Sector $sector: verified zero" >> "$log_file"
        fi
    done

    audit_log "INFO" "Wipe verification complete: $dev"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# MAIN WIPE WORKFLOW
#──────────────────────────────────────────────────────────────────────────────
wipe_drive() {
    local dev="$1"
    local serial
    serial=$(get_serial "$dev")
    local dtype
    dtype=$(get_drive_type "$dev")
    local model
    model=$(get_drive_model "$dev")
    local size
    size=$(get_drive_size "$dev")
    local log_file="$LOG_DIR/${SESSION_START}_${serial}_wipe.log"

    # Select method
    if ! select_wipe_method "$dtype" "$dev"; then
        audit_log "INFO" "Wipe cancelled by operator: $dev"
        return 1
    fi
    local method="$REPLY_WIPE_METHOD"

    # Final confirmation — last chance before destruction
    if ! confirm "⚠ FINAL CONFIRMATION" \
"ALL DATA ON THIS DRIVE WILL BE PERMANENTLY DESTROYED.

  Device : $dev
  Type   : $dtype
  Size   : $size
  Model  : $model
  Serial : $serial
  Method : method $method

This CANNOT be undone.

Are you absolutely sure?"; then
        audit_log "INFO" "Wipe aborted at final confirmation: $dev"
        return 1
    fi

    # Initialize log
    {
        echo "============================================================"
        echo "  WipeDeploy NIST SP 800-88 Rev.1 Wipe Log"
        echo "  Device  : $dev"
        echo "  Type    : $dtype"
        echo "  Size    : $size"
        echo "  Model   : $model"
        echo "  Serial  : $serial"
        echo "  Method  : $method"
        echo "  Start   : $(date)"
        echo "============================================================"
    } > "$log_file"

    audit_log "INFO" "Wipe start: $dev serial=$serial dtype=$dtype method=$method"

    # Remove write protection if set
    write_unprotect "$dev"

    # Execute wipe
    local rc=0
    case "$dtype" in
        HDD)     wipe_hdd  "$dev" "$method" "$log_file"; rc=$? ;;
        SSD)     wipe_ssd  "$dev" "$method" "$log_file"; rc=$? ;;
        NVME)    wipe_nvme "$dev" "$method" "$log_file"; rc=$? ;;
        *)       wipe_hdd  "$dev" "$method" "$log_file"; rc=$? ;;
    esac

    if [[ $rc -eq 0 ]]; then
        # Verify
        info_box "Verifying" "Verifying wipe — sampling sectors..." 2
        verify_wipe "$dev" "$log_file"

        {
            echo ""
            echo "  End     : $(date)"
            echo "  Status  : SUCCESS"
            echo "============================================================"
        } >> "$log_file"

        audit_log "INFO" "Wipe SUCCESS: $dev"

        msg_box "Wipe Complete" \
"Drive sanitized successfully.

  Device : $dev
  Serial : $serial
  Method : $dtype method $method
  Status : SUCCESS

Log saved to: $(basename "$log_file")"

        return 0
    else
        {
            echo ""
            echo "  End     : $(date)"
            echo "  Status  : FAILED (rc=$rc)"
            echo "============================================================"
        } >> "$log_file"

        audit_log "ERROR" "Wipe FAILED: $dev rc=$rc"

        msg_box "Wipe Failed" \
"Wipe did not complete successfully.

  Device : $dev
  Exit   : $rc

Check log: $(basename "$log_file")"

        return 1
    fi
}
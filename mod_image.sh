#!/bin/bash
#==============================================================================
# mod_image.sh
# Forensic drive imaging module.
# Supports: dcfldd (raw + hash), ewfacquire (E01 forensic format)
# Destinations: WDDATA partition, external USB/drive, network share (SMB/NFS)
# All images are named: SERIAL_MODEL_DATE.img/.E01
# SHA256 hash logged and verified after acquisition.
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"

MNT_DEST="/tmp/wd_dest"

#──────────────────────────────────────────────────────────────────────────────
# SELECT IMAGE FORMAT
#──────────────────────────────────────────────────────────────────────────────
select_image_format() {
    local choice
    choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "Select Image Format" \
                    --menu "Choose acquisition format:" \
                    14 60 3 \
                    "1" "dcfldd — Raw image + SHA256 hash (fast)" \
                    "2" "E01    — Forensic format, compressed, verified" \
                    "3" "Back" \
                    3>&1 1>&2 2>&3)
    [[ $? -ne 0 || "$choice" == "3" ]] && return 1
    REPLY_FORMAT="$choice"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# SELECT DESTINATION
#──────────────────────────────────────────────────────────────────────────────
select_destination() {
    local target_dev="$1"

    local choice
    choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "Select Destination" \
                    --menu "Where should the image be saved?" \
                    14 60 4 \
                    "1" "WDDATA partition (this USB)" \
                    "2" "External USB / drive" \
                    "3" "Network share (SMB/NFS)" \
                    "4" "Back" \
                    3>&1 1>&2 2>&3)

    [[ $? -ne 0 || "$choice" == "4" ]] && return 1

    case "$choice" in
        1)
            DEST_PATH="$IMAGE_DIR"
            mkdir -p "$DEST_PATH"
            DEST_LABEL="WDDATA"
            ;;
        2)
            if ! select_destination_drive "$target_dev"; then
                return 1
            fi
            local dest_dev="$REPLY_DEVICE"
            mkdir -p "$MNT_DEST"
            umount "$MNT_DEST" 2>/dev/null || true

            # Mount first partition of destination drive
            local dest_part
            dest_part=$(lsblk -lnpo NAME "$dest_dev" | sed -n '2p')
            [[ -z "$dest_part" ]] && dest_part="$dest_dev"

            mount "$dest_part" "$MNT_DEST" || {
                msg_box "Mount Failed" "Could not mount $dest_part as destination."
                return 1
            }
            mkdir -p "$MNT_DEST/WipeDeploy_Images"
            DEST_PATH="$MNT_DEST/WipeDeploy_Images"
            DEST_LABEL="$dest_dev"
            audit_log "INFO" "External destination mounted: $dest_part → $MNT_DEST"
            ;;
        3)
            # Network share
            local share_path
            share_path=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                                --title "Network Share" \
                                --inputbox \
"Enter SMB or NFS share path:
  SMB: //server/share
  NFS: server:/export/path" \
                                10 60 \
                                3>&1 1>&2 2>&3)
            [[ $? -ne 0 || -z "$share_path" ]] && return 1

            mkdir -p "$MNT_DEST"
            umount "$MNT_DEST" 2>/dev/null || true

            # Detect SMB vs NFS
            if [[ "$share_path" == //* ]]; then
                local creds
                creds=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                               --title "SMB Credentials" \
                               --inputbox "Username (or leave blank for guest):" \
                               8 50 \
                               3>&1 1>&2 2>&3)
                if [[ -n "$creds" ]]; then
                    local pass
                    pass=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                                  --title "SMB Password" \
                                  --passwordbox "Password:" \
                                  8 50 \
                                  3>&1 1>&2 2>&3)
                    mount -t cifs "$share_path" "$MNT_DEST" \
                        -o "username=$creds,password=$pass,vers=3.0" || {
                        msg_box "Mount Failed" "Could not mount SMB share: $share_path"
                        return 1
                    }
                else
                    mount -t cifs "$share_path" "$MNT_DEST" \
                        -o "guest,vers=3.0" || {
                        msg_box "Mount Failed" "Could not mount SMB share: $share_path"
                        return 1
                    }
                fi
            else
                mount -t nfs "$share_path" "$MNT_DEST" || {
                    msg_box "Mount Failed" "Could not mount NFS share: $share_path"
                    return 1
                }
            fi

            mkdir -p "$MNT_DEST/WipeDeploy_Images"
            DEST_PATH="$MNT_DEST/WipeDeploy_Images"
            DEST_LABEL="$share_path"
            audit_log "INFO" "Network share mounted: $share_path → $MNT_DEST"
            ;;
    esac
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# BUILD IMAGE FILENAME
#──────────────────────────────────────────────────────────────────────────────
build_image_name() {
    local dev="$1"
    local format="$2"
    local serial
    serial=$(get_serial "$dev")
    local model
    model=$(get_drive_model "$dev" | tr ' /' '__')
    local ts
    ts=$(date +%Y%m%d_%H%M%S)

    case "$format" in
        1) echo "${serial}_${model}_${ts}.img" ;;
        2) echo "${serial}_${model}_${ts}.E01" ;;
    esac
}

#──────────────────────────────────────────────────────────────────────────────
# ACQUIRE — dcfldd raw image
#──────────────────────────────────────────────────────────────────────────────
acquire_dcfldd() {
    local dev="$1"
    local dest_file="$2"
    local hash_file="${dest_file}.sha256"
    local log_file="${dest_file}.log"

    audit_log "INFO" "dcfldd acquisition start: $dev → $dest_file"

    # Write protect source
    write_protect "$dev"

    {
        echo "WipeDeploy dcfldd Acquisition"
        echo "Source  : $dev"
        echo "Output  : $dest_file"
        echo "Start   : $(date)"
        echo "Serial  : $(get_serial "$dev")"
        echo "Model   : $(get_drive_model "$dev")"
        echo "Size    : $(get_drive_size "$dev")"
        echo "Type    : $(get_drive_type "$dev")"
    } > "$log_file"

    # Run dcfldd — hash=sha256, log hash to file, noerror+sync for bad sectors
    # Progress piped to dialog gauge
    (
        dcfldd if="$dev" \
               of="$dest_file" \
               bs=4096 \
               hash=sha256 \
               sha256log="$hash_file" \
               conv=noerror,sync \
               statusinterval=256 2>&1 \
        | while IFS= read -r line; do
            # Extract block count for rough progress
            if [[ "$line" =~ ([0-9]+)\ blocks ]]; then
                local blocks="${BASH_REMATCH[1]}"
                local size_bytes
                size_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 1)
                local done_bytes=$(( blocks * 4096 ))
                local pct=$(( done_bytes * 100 / size_bytes ))
                [[ $pct -gt 100 ]] && pct=100
                echo "$pct"
            fi
        done
    ) | dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
               --title "Acquiring Image" \
               --gauge "Reading $dev → $(basename "$dest_file")
  
  This may take a long time for large drives.
  Do not interrupt." \
               10 65 0

    local exit_code=$?

    {
        echo "End     : $(date)"
        echo "SHA256  : $(cat "$hash_file" 2>/dev/null)"
        echo "Exit    : $exit_code"
    } >> "$log_file"

    if [[ $exit_code -eq 0 ]]; then
        # Verification pass
        info_box "Verifying" "Verifying image integrity...\nThis compares image back to source." 2

        local verify_log="${dest_file}.verify"
        dcfldd if="$dev" vf="$dest_file" \
               verifylog="$verify_log" \
               conv=noerror,sync bs=4096 2>/dev/null

        if grep -q "^Verify complete" "$verify_log" 2>/dev/null; then
            audit_log "INFO" "Verification PASSED: $dest_file"
            msg_box "Acquisition Complete" \
"Image acquired and verified successfully.

  Source : $dev
  Output : $(basename "$dest_file")
  Hash   : $(cat "$hash_file" 2>/dev/null | head -1)
  Verify : PASSED"
        else
            audit_log "WARN" "Verification FAILED or incomplete: $dest_file"
            msg_box "Verification Warning" \
"Image acquired but verification had issues.
Check: $(basename "$verify_log")

Image may still be usable — review logs."
        fi
    else
        audit_log "ERROR" "dcfldd acquisition failed: $dev"
        msg_box "Acquisition Failed" "dcfldd exited with error $exit_code.\nCheck logs."
    fi

    cp "$log_file" "$LOG_DIR/" 2>/dev/null || true
}

#──────────────────────────────────────────────────────────────────────────────
# ACQUIRE — ewfacquire E01 forensic format
#──────────────────────────────────────────────────────────────────────────────
acquire_ewf() {
    local dev="$1"
    local dest_base="$2"   # without extension — ewfacquire adds .E01

    if ! command -v ewfacquire &>/dev/null; then
        msg_box "Not Available" \
"ewfacquire not installed.
Install: apt install libewf-dev ewf-tools

Falling back to dcfldd." 
        acquire_dcfldd "$dev" "${dest_base}.img"
        return
    fi

    audit_log "INFO" "ewfacquire start: $dev → ${dest_base}.E01"
    write_protect "$dev"

    local serial
    serial=$(get_serial "$dev")
    local model
    model=$(get_drive_model "$dev")
    local case_num
    case_num=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                      --title "E01 Case Information" \
                      --inputbox "Case number / asset tag (optional):" \
                      8 50 \
                      3>&1 1>&2 2>&3)

    clear
    echo -e "${CYAN}Starting E01 acquisition: $dev${NC}"
    echo -e "${DIM}ewfacquire will show its own progress output.${NC}"
    echo ""

    ewfacquire \
        -t "$dest_base" \
        -c "deflate" \
        -C "${case_num:-WIPEDEPLOY}" \
        -D "WipeDeploy NIST 800-88 pre-wipe forensic image" \
        -e "WipeDeploy v${WIPEDEPLOY_VERSION}" \
        -E "$serial" \
        -m "removable" \
        -M "logical" \
        -u \
        "$dev"

    local exit_code=$?
    audit_log "INFO" "ewfacquire exit code: $exit_code — $dev"

    if [[ $exit_code -eq 0 ]]; then
        msg_box "E01 Acquisition Complete" \
"E01 image created successfully.

  Source : $dev
  Output : $(basename "${dest_base}").E01
  Model  : $model
  Serial : $serial"
    else
        msg_box "E01 Failed" "ewfacquire exited with error $exit_code."
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# MAIN IMAGE WORKFLOW
#──────────────────────────────────────────────────────────────────────────────
image_drive() {
    local dev="$1"
    local serial
    serial=$(get_serial "$dev")
    local dtype
    dtype=$(get_drive_type "$dev")
    local size
    size=$(get_drive_size "$dev")

    # Confirmation
    if ! confirm "Confirm Imaging" \
"Forensic image of:

  Device : $dev
  Type   : $dtype
  Size   : $size
  Serial : $serial

This may take a long time. Continue?"; then
        audit_log "INFO" "Imaging cancelled by operator: $dev"
        return
    fi

    # Select format
    if ! select_image_format; then return; fi
    local fmt="$REPLY_FORMAT"

    # Select destination
    if ! select_destination "$dev"; then return; fi

    # Build filename
    local img_name
    img_name=$(build_image_name "$dev" "$fmt")
    local dest_file="$DEST_PATH/$img_name"

    audit_log "INFO" "Imaging: $dev → $dest_file (format=$fmt, dest=$DEST_LABEL)"

    case "$fmt" in
        1) acquire_dcfldd "$dev" "$dest_file" ;;
        2) acquire_ewf "$dev" "${DEST_PATH}/$(build_image_name "$dev" 2 | sed 's/\.E01$//')" ;;
    esac

    # Unmount external destination if we mounted one
    if [[ "$DEST_PATH" == "$MNT_DEST"* ]]; then
        sync
        umount "$MNT_DEST" 2>/dev/null || true
        audit_log "INFO" "Destination unmounted: $MNT_DEST"
    fi
}
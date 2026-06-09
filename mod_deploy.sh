#!/bin/bash
#==============================================================================
# mod_deploy.sh
# Post-wipe deployment module.
#
# Sets the selected Windows ISO as Ventoy's default boot entry,
# then reboots the system. Ventoy boots the ISO automatically,
# autounattend.xml is injected, Windows installs unattended,
# MSDM key pulled from UEFI firmware.
#
# After Windows install, firstrun.cmd resets Ventoy default
# back to wipe ISO for the next machine.
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"

VENTOY_JSON="$DATA_DIR/ventoy/ventoy.json"
VENTOY_JSON_BAK="$DATA_DIR/ventoy/ventoy.json.bak"

#──────────────────────────────────────────────────────────────────────────────
# FIND AVAILABLE WINDOWS ISOS ON WDDATA
#──────────────────────────────────────────────────────────────────────────────
find_windows_isos() {
    WIN10_ISO=$(find "$DATA_DIR" -maxdepth 1 -iname "*10*.iso" 2>/dev/null | head -1)
    WIN11_ISO=$(find "$DATA_DIR" -maxdepth 1 -iname "*11*.iso" 2>/dev/null | head -1)
}

#──────────────────────────────────────────────────────────────────────────────
# SELECT WINDOWS VERSION
#──────────────────────────────────────────────────────────────────────────────
select_windows_iso() {
    find_windows_isos

    local menu_items=()
    [[ -n "$WIN10_ISO" ]] && menu_items+=("10" "Windows 10 — $(basename "$WIN10_ISO")")
    [[ -n "$WIN11_ISO" ]] && menu_items+=("11" "Windows 11 — $(basename "$WIN11_ISO")")

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        msg_box "No Windows ISOs" \
"No Windows ISOs found on WDDATA.

Expected naming:
  *10*.iso  — Windows 10
  *11*.iso  — Windows 11

Copy ISOs to the root of the WDDATA partition."
        return 1
    fi

    # Check MSDM key
    local msdm_key
    msdm_key=$(get_msdm_key)
    local msdm_info
    if [[ -n "$msdm_key" ]]; then
        msdm_info="MSDM key: FOUND (key will be used automatically)"
    else
        msdm_info="MSDM key: NOT FOUND (manual activation may be needed)"
    fi

    local choice
    choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "Select Windows Version" \
                    --menu \
"$msdm_info

Select Windows version to install:" \
                    14 65 4 \
                    "${menu_items[@]}" \
                    3>&1 1>&2 2>&3)

    [[ $? -ne 0 ]] && return 1

    case "$choice" in
        10) SELECTED_ISO="$WIN10_ISO" ;;
        11) SELECTED_ISO="$WIN11_ISO" ;;
    esac

    audit_log "INFO" "Windows ISO selected: $SELECTED_ISO"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# UPDATE VENTOY.JSON — set default boot ISO
# Ventoy reads VTOY_DEFAULT_IMAGE on boot and auto-selects that ISO
#──────────────────────────────────────────────────────────────────────────────
set_ventoy_default() {
    local iso_path="$1"
    local iso_name
    iso_name="/$(basename "$iso_path")"

    if [[ ! -f "$VENTOY_JSON" ]]; then
        audit_log "WARN" "ventoy.json not found: $VENTOY_JSON — creating minimal config"
        mkdir -p "$(dirname "$VENTOY_JSON")"
        echo '{}' > "$VENTOY_JSON"
    fi

    # Backup current config
    cp "$VENTOY_JSON" "$VENTOY_JSON_BAK"

    # Use python3 to safely update JSON
    # Falls back to sed if python3 not available
    if command -v python3 &>/dev/null; then
        python3 - <<PYEOF
import json, sys

with open("$VENTOY_JSON", "r") as f:
    try:
        cfg = json.load(f)
    except:
        cfg = {}

# Set default image
if "control" not in cfg:
    cfg["control"] = []

# Remove any existing VTOY_DEFAULT_IMAGE entry
cfg["control"] = [c for c in cfg["control"]
                  if "VTOY_DEFAULT_IMAGE" not in c]

# Add new default
cfg["control"].append({"VTOY_DEFAULT_IMAGE": "$iso_name"})
# Set timeout to 0 for fully automatic boot
cfg["control"] = [c for c in cfg["control"]
                  if "VTOY_MENU_TIMEOUT" not in c]
cfg["control"].append({"VTOY_MENU_TIMEOUT": "0"})

with open("$VENTOY_JSON", "w") as f:
    json.dump(cfg, f, indent=4)

print("ventoy.json updated")
PYEOF
    else
        # Fallback — append control block
        audit_log "WARN" "python3 not available — using sed fallback for ventoy.json"
        sed -i "s|\"VTOY_DEFAULT_IMAGE\".*|\"VTOY_DEFAULT_IMAGE\": \"$iso_name\"|g" \
            "$VENTOY_JSON" 2>/dev/null || true
    fi

    audit_log "INFO" "Ventoy default set to: $iso_name"
}

#──────────────────────────────────────────────────────────────────────────────
# DEPLOY — full workflow
#──────────────────────────────────────────────────────────────────────────────
deploy_windows() {
    # Select ISO
    if ! select_windows_iso; then return 1; fi

    # Partition disk for Windows before reboot
    # GPT: EFI (100MB) + MSR (16MB) + Windows (rest)
    local target_dev="$REPLY_DEVICE"

    if [[ -z "$target_dev" ]]; then
        msg_box "No Target" "No target device set. Run wipe first."
        return 1
    fi

    if ! confirm "Partition for Windows" \
"Prepare $target_dev for Windows installation?

  EFI System Partition : 100MB (FAT32)
  Microsoft Reserved   : 16MB
  Windows              : remaining space (NTFS)

This creates the partition layout Windows setup expects."; then
        return 1
    fi

    info_box "Partitioning" "Creating Windows partition layout on $target_dev..." 2

    parted -s "$target_dev" \
        mklabel gpt \
        mkpart "EFI"     fat32  1MiB    101MiB \
        set 1 esp on \
        mkpart "MSR"     ""     101MiB  117MiB \
        set 2 msftres on \
        mkpart "Windows" ntfs   117MiB  100% 2>/dev/null

    partprobe "$target_dev"

    audit_log "INFO" "Windows partition layout created: $target_dev"

    # Format EFI partition
    local efi_part
    efi_part=$(lsblk -lnpo NAME "$target_dev" | sed -n '2p')
    mkfs.fat -F32 -n "EFI" "$efi_part" 2>/dev/null || true

    # Set Ventoy to boot selected ISO automatically
    set_ventoy_default "$SELECTED_ISO"

    # Final confirmation before reboot
    if ! confirm "Ready to Deploy" \
"System is ready for Windows deployment.

  Target  : $target_dev
  ISO     : $(basename "$SELECTED_ISO")
  Key     : $(get_msdm_key | head -c 5)XXXXX-XXXXX-XXXXX-XXXXX

On reboot:
  1. Ventoy will auto-boot $(basename "$SELECTED_ISO")
  2. Windows setup runs unattended
  3. MSDM key activates automatically

REBOOT NOW?"; then
        # Restore ventoy.json if operator cancels
        [[ -f "$VENTOY_JSON_BAK" ]] && cp "$VENTOY_JSON_BAK" "$VENTOY_JSON"
        audit_log "INFO" "Deploy cancelled at reboot confirmation"
        return 1
    fi

    audit_log "INFO" "Rebooting for Windows deployment: $(basename "$SELECTED_ISO")"
    session_close "DEPLOY_REBOOT"

    sync
    sleep 2
    reboot
}
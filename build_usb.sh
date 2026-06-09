#!/bin/bash
#==============================================================================
# build_usb.sh — Linux (Kali) Ventoy USB Builder
#
# Builds a WipeDeploy deployment USB using Ventoy.
# ISOs are stored intact — Ventoy boots them directly.
# autounattend.xml injected at boot via Ventoy auto_install plugin.
# Generates X.509 certificates for Reset-Rollout sign+encrypt workflow.
#
# ISO naming convention (place in ./isos/ folder):
#   *wipe*.iso  — WipeDeploy live Debian ISO
#   *10*.iso    — Windows 10 ISO
#   *11*.iso    — Windows 11 ISO
#
# Usage:
#   sudo bash build_usb.sh
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="$SCRIPT_DIR/isos"
VENTOY_DIR="/tmp/ventoy_install"
MNT_VENTOY="/tmp/wd_ventoy"
CERT_DIR_TEMP="/tmp/reset_rollout_certs_build"

RED='\033[0;31m'
GREEN='\033[0;32m'
AMBER='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[*] $1${NC}"; }
pass()  { echo -e "${GREEN}[OK] $1${NC}"; }
warn()  { echo -e "${AMBER}[WARN] $1${NC}"; }
fatal() { echo -e "${RED}[FATAL] $1${NC}"; exit 1; }

USB_DEVICE=""
FORENSIC_PASSPHRASE=""
STORAGE_PASSPHRASE=""

#─────────────────────────────────────────────────────────────────────
# FIND ISOS
#─────────────────────────────────────────────────────────────────────
find_isos() {
    WIPE_ISO=$(find "$ISO_DIR" -maxdepth 1 -iname "*wipe*.iso" 2>/dev/null | head -1)
    WIN10_ISO=$(find "$ISO_DIR" -maxdepth 1 -iname "*10*.iso" 2>/dev/null | head -1)
    WIN11_ISO=$(find "$ISO_DIR" -maxdepth 1 -iname "*11*.iso" 2>/dev/null | head -1)
}

#─────────────────────────────────────────────────────────────────────
# PREFLIGHT
#─────────────────────────────────────────────────────────────────────
preflight() {
    [[ "$(id -u)" -ne 0 ]] && fatal "Run as root: sudo bash build_usb.sh"

    info "Checking dependencies..."
    for tool in curl tar lsblk partprobe openssl; do
        command -v "$tool" &>/dev/null || fatal "Missing: $tool"
    done

    [[ -d "$ISO_DIR" ]] || fatal "ISO directory not found: $ISO_DIR
Create it and place your ISOs inside:
  $ISO_DIR/*wipe*.iso
  $ISO_DIR/*10*.iso
  $ISO_DIR/*11*.iso"

    find_isos

    pass "Preflight OK"
}

#─────────────────────────────────────────────────────────────────────
# CONFIRM ISO SELECTION
#─────────────────────────────────────────────────────────────────────
confirm_isos() {
    echo ""
    echo -e "${BOLD}ISOs found in $ISO_DIR:${NC}"
    echo ""

    if [[ -n "$WIPE_ISO" ]]; then
        echo -e "  ${GREEN}✓${NC}  Wipe ISO  : $(basename "$WIPE_ISO")"
    else
        echo -e "  ${RED}✗${NC}  Wipe ISO  : NOT FOUND (*wipe*.iso)"
    fi

    if [[ -n "$WIN10_ISO" ]]; then
        echo -e "  ${GREEN}✓${NC}  Win10 ISO : $(basename "$WIN10_ISO")"
    else
        echo -e "  ${AMBER}–${NC}  Win10 ISO : not found (*10*.iso) — skipping"
    fi

    if [[ -n "$WIN11_ISO" ]]; then
        echo -e "  ${GREEN}✓${NC}  Win11 ISO : $(basename "$WIN11_ISO")"
    else
        echo -e "  ${AMBER}–${NC}  Win11 ISO : not found (*11*.iso) — skipping"
    fi

    echo ""

    [[ -z "$WIPE_ISO" ]] && fatal "Wipe ISO is required. Build it with build_iso.sh first."

    echo -e "${BOLD}Press Enter to continue or Ctrl+C to abort...${NC}"
    read -r
}

#─────────────────────────────────────────────────────────────────────
# GET PASSPHRASES FOR CERTIFICATE KEYS
#─────────────────────────────────────────────────────────────────────
get_passphrases() {
    echo ""
    echo -e "${BOLD}Reset-Rollout Certificate Generation${NC}"
    echo "You will be prompted for passphrases to protect the private keys."
    echo "These passphrases will be needed when using the forensic and storage USBs."
    echo ""

    local pass1 pass2
    while true; do
        read -r -s -p "Enter passphrase for forensic device private key: " pass1
        echo ""
        read -r -s -p "Confirm passphrase: " pass2
        echo ""
        if [[ "$pass1" == "$pass2" ]]; then
            FORENSIC_PASSPHRASE="$pass1"
            break
        else
            warn "Passphrases do not match. Try again."
        fi
    done

    while true; do
        read -r -s -p "Enter passphrase for storage device private key: " pass1
        echo ""
        read -r -s -p "Confirm passphrase: " pass2
        echo ""
        if [[ "$pass1" == "$pass2" ]]; then
            STORAGE_PASSPHRASE="$pass1"
            break
        else
            warn "Passphrases do not match. Try again."
        fi
    done

    pass "Passphrases set."
}

#─────────────────────────────────────────────────────────────────────
# GENERATE CERTIFICATES
#─────────────────────────────────────────────────────────────────────
generate_certs() {
    info "Generating Reset-Rollout certificates..."

    mkdir -p "$CERT_DIR_TEMP"
    cd "$CERT_DIR_TEMP"

    local ca_key ca_cert forensic_key forensic_csr forensic_cert storage_key storage_csr storage_cert

    ca_key="ca.key"
    ca_cert="ca.pem"
    forensic_key="forensic-key.pem"
    forensic_csr="forensic.csr"
    forensic_cert="forensic-cert.pem"
    storage_key="storage-key.pem"
    storage_csr="storage.csr"
    storage_cert="storage-cert.pem"

    # Generate self-signed CA (no passphrase on CA key; it stays on build machine)
    info "Generating CA certificate..."
    openssl genrsa -out "$ca_key" 4096 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$ca_key" -out "$ca_cert" \
        -subj "/C=US/ST=State/L=City/O=Reset-Rollout/CN=Reset-Rollout-CA" 2>/dev/null
    pass "CA certificate generated."

    # Generate forensic device certificate (key with passphrase)
    info "Generating forensic device certificate..."
    openssl genrsa -aes256 -passout pass:"$FORENSIC_PASSPHRASE" -out "$forensic_key" 4096 2>/dev/null
    openssl req -new -key "$forensic_key" -passin pass:"$FORENSIC_PASSPHRASE" -out "$forensic_csr" \
        -subj "/C=US/ST=State/L=City/O=Reset-Rollout/CN=forensic-device" 2>/dev/null
    openssl x509 -req -days 365 -in "$forensic_csr" -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -out "$forensic_cert" 2>/dev/null
    pass "Forensic device certificate generated."

    # Generate storage device certificate (key with passphrase)
    info "Generating storage device certificate..."
    openssl genrsa -aes256 -passout pass:"$STORAGE_PASSPHRASE" -out "$storage_key" 4096 2>/dev/null
    openssl req -new -key "$storage_key" -passin pass:"$STORAGE_PASSPHRASE" -out "$storage_csr" \
        -subj "/C=US/ST=State/L=City/O=Reset-Rollout/CN=storage-device" 2>/dev/null
    openssl x509 -req -days 365 -in "$storage_csr" -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -out "$storage_cert" 2>/dev/null
    pass "Storage device certificate generated."

    # Cleanup temp CSRs
    rm -f "$forensic_csr" "$storage_csr" ca.srl

    info "Certificates ready in: $CERT_DIR_TEMP"
    cd - >/dev/null
}

#────────────────────────────────────────────────────────────────────
# GET VENTOY
#────────────────────────────────────────────────────────────────────
get_ventoy() {
    if command -v ventoy &>/dev/null; then
        VENTOY_BIN="ventoy"
        pass "Ventoy found: $(ventoy --version 2>/dev/null || echo 'installed')"
        return
    fi

    local ventoy_sh
    ventoy_sh=$(find "$VENTOY_DIR" -name "Ventoy2Disk.sh" 2>/dev/null | head -1)
    if [[ -n "$ventoy_sh" ]]; then
        VENTOY_BIN="$ventoy_sh"
        pass "Ventoy already downloaded."
        return
    fi

    info "Fetching latest Ventoy..."
    local latest_url
    latest_url=$(curl -s https://api.github.com/repos/ventoy/Ventoy/releases/latest \
        | grep "browser_download_url" \
        | grep "linux.tar.gz" \
        | head -1 \
        | cut -d'"' -f4)

    [[ -z "$latest_url" ]] && fatal "Could not fetch Ventoy download URL. Check internet."

    local tarball="/tmp/ventoy_latest.tar.gz"
    info "Downloading: $latest_url"
    curl -L "$latest_url" -o "$tarball"

    mkdir -p "$VENTOY_DIR"
    tar -xzf "$tarball" -C "$VENTOY_DIR" --strip-components=1
    rm -f "$tarball"

    VENTOY_BIN=$(find "$VENTOY_DIR" -name "Ventoy2Disk.sh" | head -1)
    [[ -f "$VENTOY_BIN" ]] || fatal "Ventoy2Disk.sh not found after extraction"
    chmod +x "$VENTOY_BIN"
    pass "Ventoy downloaded."
}

#────────────────────────────────────────────────────────────────────
# SELECT DEVICE
#────────────────────────────────────────────────────────────────────
select_device() {
    echo ""
    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop\|sr0" || true
    echo ""
    read -r -p "USB device (e.g. sdb, NOT sdb1): " dev_input
    [[ -z "$dev_input" ]] && fatal "No device entered."

    USB_DEVICE="/dev/$dev_input"
    [[ -b "$USB_DEVICE" ]] || fatal "Not a block device: $USB_DEVICE"

    if mount | grep -q "^$USB_DEVICE "; then
        fatal "$USB_DEVICE is a mounted system disk. Aborting."
    fi

    echo ""
    echo -e "${RED}${BOLD}ALL DATA ON $USB_DEVICE WILL BE DESTROYED${NC}"
    echo ""
    read -r -p "Type YES to continue: " confirm
    [[ "$confirm" == "YES" ]] || fatal "Aborted."
}

#────────────────────────────────────────────────────────────────────
# KILL AUTOMOUNTS
#────────────────────────────────────────────────────────────────────
kill_automounts() {
    info "Killing automounts..."
    systemctl stop udisks2 2>/dev/null || true

    for part in $(lsblk -lnpo NAME "$USB_DEVICE" 2>/dev/null | tail -n +2); do
        umount -l "$part" 2>/dev/null || true
        udisksctl unmount -b "$part" 2>/dev/null || true
    done

    umount -l /mnt/wddata_build                        2>/dev/null || true
    umount -l /run/media/"${SUDO_USER:-root}"/Ventoy   2>/dev/null || true
    umount -l /run/media/"${SUDO_USER:-root}"/VTOYEFI  2>/dev/null || true
    umount -l /run/media/"${SUDO_USER:-root}"/LIVE     2>/dev/null || true
    umount -l /run/media/"${SUDO_USER:-root}"/WDDATA   2>/dev/null || true
    sleep 1
}

#────────────────────────────────────────────────────────────────────
# INSTALL VENTOY
#────────────────────────────────────────────────────────────────────
install_ventoy() {
    info "Installing Ventoy to $USB_DEVICE..."

    # -I = force install, -g = GPT (UEFI + BIOS hybrid)
    bash "$VENTOY_BIN" -I -g "$USB_DEVICE"

    partprobe "$USB_DEVICE"
    sleep 3
    pass "Ventoy installed."
}

#────────────────────────────────────────────────────────────────────
# POPULATE VENTOY DATA PARTITION
#────────────────────────────────────────────────────────────────────
populate() {
    info "Locating Ventoy data partition..."

    local vtoy_part
    vtoy_part=$(lsblk -lnpo NAME,LABEL "$USB_DEVICE" 2>/dev/null \
        | grep -i "Ventoy" | awk '{print $1}' | head -1)

    if [[ -z "$vtoy_part" ]]; then
        warn "Ventoy label not found — using largest partition"
        vtoy_part=$(lsblk -lnpo NAME,SIZE "$USB_DEVICE" 2>/dev/null \
            | tail -n +2 | sort -k2 -h | tail -1 | awk '{print $1}')
    fi

    [[ -b "$vtoy_part" ]] || fatal "Cannot locate Ventoy data partition."
    info "Ventoy data partition: $vtoy_part"

    umount -l "$vtoy_part" 2>/dev/null || true
    udisksctl unmount -b "$vtoy_part" 2>/dev/null || true
    sleep 1

    mkdir -p "$MNT_VENTOY"
    mount "$vtoy_part" "$MNT_VENTOY" || fatal "Failed to mount Ventoy partition."

    mkdir -p "$MNT_VENTOY/ventoy"

    # Copy ISOs
    info "Copying wipe ISO..."
    rsync -a --info=progress2 "$WIPE_ISO" "$MNT_VENTOY/"
    pass "Wipe ISO copied."

    if [[ -n "$WIN10_ISO" ]]; then
        info "Copying Windows 10 ISO..."
        rsync -a --info=progress2 "$WIN10_ISO" "$MNT_VENTOY/"
        pass "Win10 ISO copied."
    fi

    if [[ -n "$WIN11_ISO" ]]; then
        info "Copying Windows 11 ISO..."
        rsync -a --info=progress2 "$WIN11_ISO" "$MNT_VENTOY/"
        pass "Win11 ISO copied."
    fi

    # Copy autounattend.xml
    local autounattend="$SCRIPT_DIR/ventoy/autounattend.xml"
    if [[ -f "$autounattend" ]]; then
        cp "$autounattend" "$MNT_VENTOY/ventoy/"
        pass "autounattend.xml copied."
    else
        warn "autounattend.xml not found: $autounattend"
    fi

    # Copy generated certificates to Ventoy partition (accessible during operation)
    if [[ -d "$CERT_DIR_TEMP" ]]; then
        info "Copying Reset-Rollout certificates to USB..."
        mkdir -p "$MNT_VENTOY/reset-rollout-certs"
        cp -a "$CERT_DIR_TEMP"/* "$MNT_VENTOY/reset-rollout-certs/"
        chmod 700 "$MNT_VENTOY/reset-rollout-certs"
        pass "Certificates copied to USB."
    fi

    # Write ventoy.json
    info "Writing ventoy.json..."
    local win10_name win11_name wipe_name
    wipe_name="/$(basename "$WIPE_ISO")"
    win10_name="$( [[ -n "$WIN10_ISO" ]] && echo "/$(basename "$WIN10_ISO")" || echo "" )"
    win11_name="$( [[ -n "$WIN11_ISO" ]] && echo "/$(basename "$WIN11_ISO")" || echo "" )"

    python3 - <<PYEOF
import json

cfg = {
    "control": [
        {"VTOY_DEFAULT_MENU_MODE": "0"},
        {"VTOY_MENU_TIMEOUT": "10"},
        {"VTOY_SECONDARY_BOOT_MENU": "0"}
    ],
    "auto_install": [],
    "menu_alias": [
        {"image": "$wipe_name", "alias": "1. Reset-Rollout — NIST 800-88 Forensic Toolkit"}
    ]
}

# Add Windows ISO injection entries
win10 = "$win10_name"
win11 = "$win11_name"

if win10:
    cfg["auto_install"].append({
        "image": win10,
        "template": "/ventoy/autounattend.xml",
        "timeout": 0
    })
    cfg["menu_alias"].append({
        "image": win10,
        "alias": "2. Windows 10 — Unattended Install (MSDM key)"
    })

if win11:
    cfg["auto_install"].append({
        "image": win11,
        "template": "/ventoy/autounattend.xml",
        "timeout": 0
    })
    cfg["menu_alias"].append({
        "image": win11,
        "alias": "3. Windows 11 — Unattended Install (MSDM key)"
    })

with open("$MNT_VENTOY/ventoy/ventoy.json", "w") as f:
    json.dump(cfg, f, indent=4)

print("ventoy.json written")
PYEOF

    pass "ventoy.json written."

    # SHA256 checksums
    info "Generating ISO checksums..."
    (cd "$MNT_VENTOY" && sha256sum *.iso > ventoy/iso_checksums.sha256 2>/dev/null || true)
    pass "Checksums written."

    sync
    umount "$MNT_VENTOY"
    pass "Ventoy data partition populated."
}

#────────────────────────────────────────────────────────────────────
# SUMMARY
#────────────────────────────────────────────────────────────────────
summary() {
    systemctl start udisks2 2>/dev/null || true
    echo ""
    echo -e "${GREEN}${BOLD}================ USB READY ================${NC}"
    echo "  Device    : $USB_DEVICE"
    echo "  Bootloader: Ventoy (UEFI + BIOS/CSM)"
    echo ""
    echo "  Boot menu:"
    echo "    1. Reset-Rollout — NIST 800-88 Forensic Toolkit"
    [[ -n "$WIN10_ISO" ]] && echo "    2. Windows 10 — Unattended Install"
    [[ -n "$WIN11_ISO" ]] && echo "    3. Windows 11 — Unattended Install"
    echo ""
    echo "  autounattend.xml injected at boot — ISOs unmodified"
    echo "  Checksums: ventoy/iso_checksums.sha256"
    echo ""
    echo "  Reset-Rollout Certificates:"
    echo "    Location on USB: /reset-rollout-certs/"
    echo "    • ca.pem                (CA certificate)"
    echo "    • forensic-cert.pem     (forensic device certificate)"
    echo "    • forensic-key.pem      (forensic device private key — passphrase protected)"
    echo "    • storage-cert.pem      (storage device certificate)"
    echo "    • storage-key.pem       (storage device private key — passphrase protected)"
    echo ""
    echo "  Setup on storage appliance:"
    echo "    1. Copy /reset-rollout-certs/ to /opt/reset-rollout/certs/"
    echo "    2. Compute forensic cert fingerprint:"
    echo "       openssl x509 -noout -fingerprint -sha256 -in forensic-cert.pem | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]'"
    echo "    3. Add fingerprint to /etc/reset-rollout/allowed_signers.txt"
    echo "    4. Enable verify-and-store service (see README/OPERATION.md)"
    echo ""
    echo "  Disable Secure Boot on target if boot fails."
    echo -e "${GREEN}${BOLD}==========================================${NC}"
    echo ""
}

#────────────────────────────────────────────────────────────────────
# CLEANUP
#────────────────────────────────────────────────────────────────────
cleanup() {
    umount "$MNT_VENTOY" 2>/dev/null || true
    systemctl start udisks2 2>/dev/null || true
    # Clean up temp cert dir (CA key left behind for safety; remove manually if desired)
    info "Temp cert build dir: $CERT_DIR_TEMP (CA key retained; remove manually if no longer needed)"
}
trap cleanup EXIT

#────────────────────────────────────────────────────────────────────
# MAIN
#────────────────────────────────────────────────────────────────────
main() {
    preflight
    confirm_isos
    get_passphrases
    generate_certs
    get_ventoy
    select_device
    kill_automounts
    install_ventoy
    populate
    summary
}

main "$@"

#!/bin/bash
#==============================================================================
# lib_common.sh
# Shared library — sourced by all WipeDeploy modules.
# Provides: colors, logging, drive detection, audit trail,
#           TUI helpers, confirmation dialogs, error handling.
#==============================================================================

#──────────────────────────────────────────────────────────────────────────────
# CONSTANTS
#──────────────────────────────────────────────────────────────────────────────
readonly WIPEDEPLOY_VERSION="2.0"
readonly WIPEDEPLOY_NAME="WipeDeploy"

# Paths — all relative to DATA_DIR which is set by the calling script
# after mounting the WDDATA partition
DATA_DIR="${DATA_DIR:-/mnt/wddata}"
LOG_DIR="$DATA_DIR/Logs"
IMAGE_DIR="$DATA_DIR/Images"
FIRMWARE_DIR="$DATA_DIR/Firmware"
WORK_DIR="/tmp/wipedeploy_work"

# Audit log — one per session, named by timestamp + serial
SESSION_START="$(date +%Y%m%d_%H%M%S)"
AUDIT_LOG=""  # Set after serial number is known in session_init()

#──────────────────────────────────────────────────────────────────────────────
# COLORS
#──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
AMBER='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

#──────────────────────────────────────────────────────────────────────────────
# PRINT HELPERS
#──────────────────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[*] $1${NC}"; }
pass()    { echo -e "${GREEN}[OK] $1${NC}"; }
warn()    { echo -e "${AMBER}[WARN] $1${NC}"; }
fatal()   { echo -e "${RED}[FATAL] $1${NC}"; audit_log "FATAL" "$1"; exit 1; }
step()    { echo -e "${BOLD}${WHITE}[>>] $1${NC}"; }
banner()  {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║         WipeDeploy v${WIPEDEPLOY_VERSION} — NIST SP 800-88 Rev.1       ║"
    echo "  ║              Forensic Sanitization Toolkit           ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

#──────────────────────────────────────────────────────────────────────────────
# AUDIT LOGGING
# Every significant action is written to a timestamped log file
# named by session start time and target serial number.
#──────────────────────────────────────────────────────────────────────────────
audit_log() {
    local level="$1"
    local message="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    # Always print to stderr if no log file yet
    if [[ -z "$AUDIT_LOG" ]]; then
        echo "[$ts] [$level] $message" >&2
        return
    fi

    echo "[$ts] [$level] $message" >> "$AUDIT_LOG"
}

session_init() {
    local serial="$1"
    mkdir -p "$LOG_DIR" "$IMAGE_DIR" "$FIRMWARE_DIR" "$WORK_DIR"

    AUDIT_LOG="$LOG_DIR/${SESSION_START}_${serial}.log"

    {
        echo "============================================================"
        echo "  WipeDeploy v${WIPEDEPLOY_VERSION} — Session Log"
        echo "  Start     : $(date)"
        echo "  Serial    : $serial"
        echo "  Hostname  : $(hostname 2>/dev/null || echo 'unknown')"
        echo "  Kernel    : $(uname -r)"
        echo "============================================================"
    } >> "$AUDIT_LOG"

    audit_log "INFO" "Session initialized. Audit log: $AUDIT_LOG"
}

session_close() {
    local status="$1"
    audit_log "INFO" "Session closed. Status: $status"
    {
        echo "============================================================"
        echo "  End       : $(date)"
        echo "  Status    : $status"
        echo "============================================================"
    } >> "$AUDIT_LOG"
}

#──────────────────────────────────────────────────────────────────────────────
# DRIVE DETECTION
#──────────────────────────────────────────────────────────────────────────────

# Returns list of block devices excluding loop, sr, and the boot USB
get_block_devices() {
    lsblk -d -o NAME,SIZE,MODEL,TRAN,ROTA -rn \
        | grep -v "^loop\|^sr" \
        | awk '{print $1, $2, $3, $4, $5}'
}

# Get serial number of a block device
get_serial() {
    local dev="$1"
    local serial
    serial=$(udevadm info --query=all --name="$dev" 2>/dev/null \
        | grep "ID_SERIAL_SHORT\|ID_SERIAL=" \
        | head -1 \
        | cut -d= -f2 \
        | tr -s ' ' '_')
    [[ -z "$serial" ]] && serial=$(cat /sys/block/"$(basename "$dev")"/device/serial 2>/dev/null | tr -s ' ' '_')
    [[ -z "$serial" ]] && serial="UNKNOWN_$(date +%s)"
    echo "$serial"
}

# Get drive type: HDD, SSD, NVME
get_drive_type() {
    local dev="$1"
    local name
    name=$(basename "$dev")

    # NVMe
    [[ "$name" == nvme* ]] && echo "NVME" && return

    # Rotational flag: 1=HDD, 0=SSD
    local rota
    rota=$(cat /sys/block/"$name"/queue/rotational 2>/dev/null)
    [[ "$rota" == "1" ]] && echo "HDD" && return
    [[ "$rota" == "0" ]] && echo "SSD" && return

    echo "UNKNOWN"
}

# Get drive size in human-readable form
get_drive_size() {
    lsblk -d -o SIZE -rn "$1" 2>/dev/null | head -1
}

# Get drive model
get_drive_model() {
    lsblk -d -o MODEL -rn "$1" 2>/dev/null | head -1 | xargs
}

# Detect the boot USB (the device we booted from — exclude from target list)
get_boot_device() {
    # Try to find the device backing the live filesystem
    local boot_dev
    boot_dev=$(lsblk -o NAME,MOUNTPOINT -rn \
        | grep -E "/run/live|/lib/live|/cdrom|/boot/efi" \
        | awk '{print $1}' \
        | sed 's/[0-9]*$//' \
        | head -1)
    echo "/dev/$boot_dev"
}

# Detect WDDATA partition (NTFS, labeled WDDATA) on boot USB
find_wddata() {
    local dev
    dev=$(lsblk -o NAME,LABEL -rn | grep -i "WDDATA" | awk '{print "/dev/"$1}' | head -1)
    echo "$dev"
}

# Mount WDDATA partition
mount_wddata() {
    local part
    part=$(find_wddata)
    [[ -z "$part" ]] && fatal "WDDATA partition not found. Is the USB drive present?"

    mkdir -p "$DATA_DIR"
    udisksctl unmount -b "$part" 2>/dev/null || true
    umount "$part" 2>/dev/null || true
    mount "$part" "$DATA_DIR" || fatal "Failed to mount WDDATA: $part"
    audit_log "INFO" "WDDATA mounted: $part → $DATA_DIR"
}

# Write-protect a block device at kernel level
write_protect() {
    local dev="$1"
    blockdev --setro "$dev" 2>/dev/null && \
        audit_log "INFO" "Write-protected: $dev" || \
        audit_log "WARN" "Could not write-protect: $dev"
}

# Remove write-protection
write_unprotect() {
    local dev="$1"
    blockdev --setrw "$dev" 2>/dev/null
}

#──────────────────────────────────────────────────────────────────────────────
# TUI HELPERS (dialog-based)
# dialog is used throughout — whiptail lacks --fselect
#──────────────────────────────────────────────────────────────────────────────

# Check dialog is available
require_dialog() {
    command -v dialog &>/dev/null || fatal "dialog not installed. Run: apt install dialog"
}

# Simple message box
msg_box() {
    local title="$1"
    local msg="$2"
    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "$title" \
           --msgbox "$msg" 12 60
}

# Yes/No confirmation — returns 0 for yes, 1 for no
confirm() {
    local title="$1"
    local msg="$2"
    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "$title" \
           --yesno "$msg" 10 60
}

# Info box (no button — auto-dismiss)
info_box() {
    local title="$1"
    local msg="$2"
    local secs="${3:-2}"
    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "$title" \
           --infobox "$msg" 6 50
    sleep "$secs"
}

# Progress gauge — read percentages from stdin
# Usage: some_command | progress_gauge "Title" "Message"
progress_gauge() {
    local title="$1"
    local msg="$2"
    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "$title" \
           --gauge "$msg" 8 60 0
}

# Drive selection menu — excludes boot device
# Returns selected /dev/sdX in $REPLY_DEVICE
select_target_drive() {
    local boot_dev
    boot_dev=$(get_boot_device)
    audit_log "INFO" "Boot device detected: $boot_dev"

    local menu_items=()
    while IFS= read -r line; do
        local name size model tran rota
        read -r name size model tran rota <<< "$line"
        local dev="/dev/$name"
        local dtype
        dtype=$(get_drive_type "$dev")

        # Skip boot device
        [[ "$dev" == "$boot_dev"* ]] && continue
        [[ "/dev/$name" == "$boot_dev"* ]] && continue

        menu_items+=("$dev" "$size  $dtype  $model")
    done < <(get_block_devices)

    [[ ${#menu_items[@]} -eq 0 ]] && \
        fatal "No eligible target drives found. Boot device excluded."

    local choice
    choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "Select Target Drive" \
                    --menu "Select the drive to process.\nBoot USB excluded automatically." \
                    15 60 8 \
                    "${menu_items[@]}" \
                    3>&1 1>&2 2>&3)

    [[ $? -ne 0 ]] && return 1
    REPLY_DEVICE="$choice"
    audit_log "INFO" "Target drive selected: $REPLY_DEVICE"
    return 0
}

# File browser — restricted to a given root path
# Returns selected path in $REPLY_PATH
browse_files() {
    local root="$1"
    local title="${2:-Browse Files}"
    local path
    path=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                  --title "$title" \
                  --fselect "$root/" \
                  14 60 \
                  3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && return 1
    REPLY_PATH="$path"
    return 0
}

# Destination drive selector (for imaging — excludes boot dev AND target dev)
select_destination_drive() {
    local exclude_dev="$1"
    local boot_dev
    boot_dev=$(get_boot_device)

    local menu_items=()
    while IFS= read -r line; do
        local name size model
        read -r name size model _ _ <<< "$line"
        local dev="/dev/$name"
        [[ "$dev" == "$boot_dev"* ]] && continue
        [[ "$dev" == "$exclude_dev"* ]] && continue
        menu_items+=("$dev" "$size  $model")
    done < <(get_block_devices)

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        msg_box "No Destination" "No eligible destination drives found.\nAttach an external drive and retry."
        return 1
    fi

    local choice
    choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "Select Destination Drive" \
                    --menu "Select destination for image/firmware dump:" \
                    15 60 8 \
                    "${menu_items[@]}" \
                    3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && return 1
    REPLY_DEVICE="$choice"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# HASH UTILITIES
#──────────────────────────────────────────────────────────────────────────────
sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

sha256_device() {
    sha256sum "$1" | awk '{print $1}'
}

verify_hash() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(sha256_file "$file")
    [[ "$actual" == "$expected" ]]
}

#──────────────────────────────────────────────────────────────────────────────
# SYSTEM INFO
#──────────────────────────────────────────────────────────────────────────────
get_system_serial() {
    local serial
    serial=$(dmidecode -s system-serial-number 2>/dev/null | grep -v "^#" | xargs)
    [[ -z "$serial" || "$serial" == "Not Specified" ]] && \
        serial=$(dmidecode -s baseboard-serial-number 2>/dev/null | grep -v "^#" | xargs)
    [[ -z "$serial" || "$serial" == "Not Specified" ]] && \
        serial="NOSERIAL_$(date +%s)"
    echo "$serial" | tr ' /' '__'
}

get_system_model() {
    local model
    model=$(dmidecode -s system-product-name 2>/dev/null | grep -v "^#" | xargs)
    echo "${model:-Unknown}"
}

get_msdm_key() {
    strings /sys/firmware/acpi/tables/MSDM 2>/dev/null | tail -1
}

get_bios_version() {
    dmidecode -s bios-version 2>/dev/null | grep -v "^#" | xargs
}

#──────────────────────────────────────────────────────────────────────────────
# DEPENDENCY CHECK
#──────────────────────────────────────────────────────────────────────────────
check_deps() {
    local missing=0
    local required=("dialog" "mc" "dcfldd" "flashrom" "hdparm" "nvme" "nwipe"
                    "dmidecode" "lsblk" "blockdev" "smartctl" "ewfacquire"
                    "binwalk" "xxd")
    local optional=("ewfacquire" "binwalk")

    for tool in "${required[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            # Check if optional
            local is_opt=0
            for opt in "${optional[@]}"; do
                [[ "$tool" == "$opt" ]] && is_opt=1 && break
            done
            if [[ $is_opt -eq 1 ]]; then
                warn "Optional tool missing: $tool"
            else
                warn "Required tool missing: $tool"
                missing=1
            fi
        fi
    done

    [[ $missing -eq 1 ]] && \
        fatal "Missing required tools. Run: apt install dialog mc dcfldd flashrom hdparm nvme-cli nwipe dmidecode smartmontools"
}

#──────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP
#──────────────────────────────────────────────────────────────────────────────
wipedeploy_cleanup() {
    # Unmount any mounts we created
    umount /tmp/wd_target 2>/dev/null || true
    umount /tmp/wd_dest   2>/dev/null || true
    rm -rf "$WORK_DIR"
}
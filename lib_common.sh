#!/usr/bin/env bash
#===============================================================================
# lib_common.sh — Reset‑Rollout shared library
# Provides two-USB staging helpers, safe write/staging, and session init/teardown.
#==============================================================================

set -euo pipefail

# -----------------------
# Constants / Defaults
# -----------------------
readonly RESETROLL_VERSION="1.0"
readonly RESETROLL_NAME="Reset-Rollout"

# Default mount dirs (attempt stable mounts, fallback to tmp)
DEFAULT_WD_MOUNTPOINT="/mnt/wddata"     # read-only forensic USB mountpoint
DEFAULT_WORK_MOUNTPOINT="/mnt/wdwork"  # writable work USB incoming

# Staging area when WDDATA is read-only (on work USB)
STAGE_DIR_BASE="/tmp/reset_rollout_stage"

# Per-session work dir
WORK_DIR="${WORK_DIR:-/tmp/reset_rollout_work}"

# Cert defaults (can be overridden via env)
CERT_DIR_FORensic="/opt/reset-rollout/certs"
CERT_DIR_STORAGE="/opt/reset-rollout/certs"

# Terminal colors
RED='\033[0;31m'; GREEN='\033[0;32m'; AMBER='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

# Globals
DATA_DEVICE=""        # device node backing forensic USB
DATA_MOUNT=""         # mountpoint for forensic USB
WORK_DEVICE=""        # device node of work USB
WORK_MOUNT=""         # mountpoint of work USB
SESSION_START="$(date +%Y%m%d_%H%M%S)"
AUDIT_LOG=""

# -----------------------
# Logging helpers
# -----------------------
info()  { echo -e "${CYAN}[*] $1${NC}"; }
pass()  { echo -e "${GREEN}[OK] $1${NC}"; }
warn()  { echo -e "${AMBER}[WARN] $1${NC}"; }
fatal() { echo -e "${RED}[FATAL] $1${NC}"; audit_log "FATAL" "$1"; exit 1; }

audit_log() {
    local level="$1"; local msg="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -z "$AUDIT_LOG" ]]; then
        echo "[$ts] [$level] $msg" >&2
    else
        echo "[$ts] [$level] $msg" >> "$AUDIT_LOG"
    fi
}

# -----------------------
# Directory & temp helpers
# -----------------------
ensure_work_dirs() {
    mkdir -p "$WORK_DIR" "$STAGE_DIR_BASE"
    chmod 700 "$WORK_DIR" || true
}

mktemp_mountpoint() {
    mktemp -d -p /tmp reset_rollout_mount.XXXXXX
}

safe_rmdir() {
    local d="$1"
    [[ -d "$d" ]] && rmdir "$d" 2>/dev/null || true
}

# -----------------------
# Device / mount detection
# -----------------------
find_wddata_device() {
    local dev
    dev=$(blkid -L WDDATA 2>/dev/null || true)
    if [[ -n "$dev" ]]; then
        echo "$dev"
        return 0
    fi
    dev=$(lsblk -o NAME,LABEL -nr | awk '$2~/[Ww][Dd][Dd][Aa][Tt][Aa]/ {print "/dev/"$1; exit}')
    printf '%s' "${dev:-}"
}

find_work_device() {
    local boot_dev
    boot_dev=$(get_boot_device 2>/dev/null || true)
    local dev
    dev=$(blkid -L WIPETEMP 2>/dev/null || true)
    if [[ -n "$dev" ]]; then
        echo "$dev"
        return 0
    fi
    local candidate
    candidate=$(lsblk -rno NAME,RM,TYPE | awk -v boot="$(basename "$boot_dev")" '$2==1 && $3=="part" {print "/dev/"$1}' | while read -r d; do
        [[ "$d" != "$DATA_DEVICE" && "$d" != "$boot_dev" ]] && echo "$d" && break
    done)
    printf '%s' "${candidate:-}"
}

get_boot_device() {
    local root_src
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ -n "$root_src" ]]; then
        echo "/dev/$(basename "${root_src}" | sed 's/[0-9]*$//')"
    fi
}

# -----------------------
# Mount helpers
# -----------------------
mount_ro() {
    local dev="$1"; local mnt="$2"
    mkdir -p "$mnt"
    mount -o ro,noexec,nodev,nosuid "$dev" "$mnt"
}

mount_rw() {
    local dev="$1"; local mnt="$2"
    mkdir -p "$mnt"
    mount -o rw,nodev,nosuid "$dev" "$mnt"
}

umount_safe() {
    local mnt="$1"
    if mountpoint -q "$mnt"; then
        umount -l "$mnt" 2>/dev/null || true
    fi
}

# -----------------------
# Read-only checks
# -----------------------
is_kernel_ro() {
    local dev="$1"
    if [[ -b "$dev" ]]; then
        blockdev --getro "$dev" 2>/dev/null
        return 0
    fi
    return 1
}

is_mount_ro() {
    local mnt="$1"
    awk -v m="$mnt" '$2==m {print $4; exit}' /proc/mounts | grep -q '\bro\b' 2>/dev/null && return 0 || return 1
}

# -----------------------
# Staging / safe write helpers
# -----------------------
record_staged_mapping() {
    local staged="$1" dest="$2"
    echo "$dest" > "${staged}.meta"
}

safe_stage_file() {
    local dst="$1" src="$2"
    ensure_work_dirs

    local dst_mount
    dst_mount=$(df --output=target "$dst" 2>/dev/null | tail -n1 || echo "")
    [[ -z "$dst_mount" && -n "$DATA_MOUNT" ]] && dst_mount="$DATA_MOUNT"

    if [[ -n "$dst_mount" ]] && is_mount_ro "$dst_mount"; then
        info "Destination mount $dst_mount is read-only — staging to work area."
        local staged_dir
        staged_dir="${WORK_MOUNT:-$STAGE_DIR_BASE}"
        mkdir -p "$staged_dir"
        local staged
        staged="$(mktemp "${staged_dir}/staged.XXXXXX")"
        if [[ "$src" == "-" ]]; then
            cat - > "$staged"
        else
            cp -a "$src" "$staged"
        fi
        chmod 600 "$staged" || true
        record_staged_mapping "$staged" "$dst"
        audit_log "INFO" "Staged write: $staged -> $dst"
        echo "STAGED:$staged"
        return 2
    fi

    local tmp
    tmp="$(mktemp "$(dirname "$dst")/.tmp.XXXXXX")"
    if [[ "$src" == "-" ]]; then
        cat - > "$tmp"
    else
        cp -a "$src" "$tmp"
    fi
    mv -f "$tmp" "$dst"
    audit_log "INFO" "Wrote $dst"
    return 0
}

commit_staged_to_wddata() {
    local staged_meta
    local any=0
    for staged_meta in "${WORK_MOUNT:-$STAGE_DIR_BASE}"/staged.*.meta "${STAGE_DIR_BASE}"/staged.*.meta 2>/dev/null; do
        [[ -f "$staged_meta" ]] || continue
        any=1
        local staged="${staged_meta%.meta}"
        local dst
        dst="$(cat "$staged_meta")"
        local dst_dir
        dst_dir="$(dirname "$dst")"
        if [[ ! -d "$dst_dir" ]]; then
            warn "Target path does not exist: $dst_dir — creating (if possible)."
            mkdir -p "$dst_dir" 2>/dev/null || { warn "Could not create $dst_dir — skipping staged file $staged"; continue; }
        fi
        local dst_mount
        dst_mount=$(df --output=target "$dst" 2>/dev/null | tail -n1 || echo "$DATA_MOUNT")
        if [[ -n "$dst_mount" ]] && is_mount_ro "$dst_mount"; then
            warn "Destination mount $dst_mount still read-only. Cannot commit $staged -> $dst"
            continue
        fi
        mv -f "$staged" "$dst" || { warn "Failed to move $staged -> $dst"; continue; }
        rm -f "$staged_meta" || true
        audit_log "INFO" "Committed staged file -> $dst"
        pass "Committed: $dst"
    done

    if [[ $any -eq 0 ]]; then
        info "No staged files found."
    fi
}

# -----------------------
# Session init / mounts
# -----------------------
session_init() {
    local serial="$1"
    mkdir -p "$WORK_DIR" || fatal "Could not create WORK_DIR: $WORK_DIR"
    AUDIT_LOG="$WORK_DIR/${SESSION_START}_${serial}.log"
    {
        echo "============================================================"
        echo "  Reset-Rollout v${RESETROLL_VERSION} — Session Log"
        echo "  Start     : $(date)"
        echo "  Serial    : $serial"
        echo "  Hostname  : $(hostname 2>/dev/null || echo 'unknown')"
        echo "  Kernel    : $(uname -r)"
        echo "============================================================"
    } >> "$AUDIT_LOG"
    audit_log "INFO" "Session initialized. Audit log: $AUDIT_LOG"

    DATA_DEVICE="$(find_wddata_device || true)"
    if [[ -n "$DATA_DEVICE" ]]; then
        info "WDDATA device found: $DATA_DEVICE"
        if ! mountpoint -q "$DEFAULT_WD_MOUNTPOINT" 2>/dev/null; then
            DATA_MOUNT="$DEFAULT_WD_MOUNTPOINT"
            mkdir -p "$DATA_MOUNT"
            mount_ro "$DATA_DEVICE" "$DATA_MOUNT" || { warn "Failed to mount $DATA_DEVICE at $DATA_MOUNT read-only"; DATA_MOUNT=""; }
        else
            DATA_MOUNT="$DEFAULT_WD_MOUNTPOINT"
        fi
    else
        warn "WDDATA device not found by label. DATA_DEVICE unset."
    fi

    WORK_DEVICE="$(find_work_device || true)"
    if [[ -n "$WORK_DEVICE" ]]; then
        info "Work device candidate: $WORK_DEVICE"
        if ! mountpoint -q "$DEFAULT_WORK_MOUNTPOINT" 2>/dev/null; then
            WORK_MOUNT="$DEFAULT_WORK_MOUNTPOINT"
            mkdir -p "$WORK_MOUNT"
            if mount_rw "$WORK_DEVICE" "$WORK_MOUNT" 2>/dev/null; then
                info "Work device mounted rw: $WORK_DEVICE -> $WORK_MOUNT"
            else
                warn "Could not mount $WORK_DEVICE rw at $WORK_MOUNT; using STAGE_DIR_BASE"
                WORK_MOUNT="$STAGE_DIR_BASE"
            fi
        else
            WORK_MOUNT="$DEFAULT_WORK_MOUNTPOINT"
        fi
    else
        warn "No work device detected; staged writes will use $STAGE_DIR_BASE"
        WORK_MOUNT="$STAGE_DIR_BASE"
    fi

    ensure_work_dirs
}

# -----------------------
# Session close
# -----------------------
session_close() {
    local status="${1:-CLOSED}"
    audit_log "INFO" "Session closed. Status: $status"
    if [[ -n "$WORK_MOUNT" && "$WORK_MOUNT" == "$DEFAULT_WORK_MOUNTPOINT" ]]; then
        umount_safe "$WORK_MOUNT"
    fi
    if [[ -n "$DATA_MOUNT" && "$DATA_MOUNT" == "$DEFAULT_WD_MOUNTPOINT" ]]; then
        umount_safe "$DATA_MOUNT"
    fi
}

# -----------------------
# Utility wrappers
# -----------------------
safe_write_file() {
    safe_stage_file "$@"
}

# End of lib_common.sh

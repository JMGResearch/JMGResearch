#!/bin/bash
#==============================================================================
# build_iso.sh
# Builds a Debian-based bootable Linux live ISO with Reset-Rollout forensic
# tools pre-installed and reset_rollout_init.sh configured to launch at boot.
#
# Run this on any Debian or Ubuntu workstation with internet access.
# Output: reset_rollout_live.iso — write to USB with build_usb.sh
#
# Requirements:
#   sudo apt install live-build debootstrap squashfs-tools xorriso isolinux
#==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
AMBER='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[*] $1${NC}"; }
pass()  { echo -e "${GREEN}[OK] $1${NC}"; }
fatal() { echo -e "${RED}[FATAL] $1${NC}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/opt/rr_livebuild"
OUTPUT_ISO="$SCRIPT_DIR/reset_rollout_live.iso"

#──────────────────────────────────────────────────────────────────────────────
# PREFLIGHT
#──────────────────────────────────────────────────────────────────────────────
preflight() {
    info "Checking build dependencies..."
    local missing=0
    for pkg in live-build debootstrap squashfs-tools xorriso isolinux; do
        if ! dpkg -l "$pkg" &>/dev/null; then
            echo -e "${RED}  Missing package: $pkg${NC}"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Install missing packages with:"
        echo "  sudo apt install live-build debootstrap squashfs-tools xorriso isolinux"
        fatal "Dependencies not met."
    fi
    pass "All build dependencies present."

    [[ "$(id -u)" -ne 0 ]] && fatal "This script must be run as root (sudo)."

    if [[ -d "$BUILD_DIR" ]]; then
        info "Cleaning previous build directory..."
        rm -rf "$BUILD_DIR"
    fi
    mkdir -p "$BUILD_DIR"
}

#──────────────────────────────────────────────────────────────────────────────
# CONFIGURE LIVE-BUILD
#──────────────────────────────────────────────────────────────────────────────
configure() {
    info "Configuring live-build environment..."
    cd "$BUILD_DIR"

    export LB_CACHE="false"
    export LB_APT_RECOMMENDS="false"

    mkdir -p "$BUILD_DIR/config"

    lb config \
        --architecture amd64 \
        --distribution bookworm \
        --debian-installer none \
        --archive-areas "main contrib non-free non-free-firmware" \
        --bootloader grub-efi \
        --binary-images iso-hybrid \
        --memtest none \
        --iso-volume "RESETROLLOUT" \
        --iso-application "Reset-Rollout NIST 800-88" \
        --firmware-chroot true \
        --apt-recommends false
}

#──────────────────────────────────────────────────────────────────────────────
# PACKAGE LIST
#──────────────────────────────────────────────────────────────────────────────
write_packages() {
    info "Writing package list..."
    cat > "$BUILD_DIR/config/package-lists/reset-rollout.list.chroot" << 'EOF'
# Core system
bash
coreutils
util-linux
procps
grep
sed
gawk
findutils
rsync

# Drive detection and identification
hdparm
smartmontools
dmidecode
pciutils
usbutils

# Sanitization tools
nwipe
nvme-cli
secure-delete

# Partitioning and filesystem
parted
gdisk
dosfstools
ntfs-3g
e2fsprogs

# UEFI / boot management
efibootmgr
efivar
acpica-tools

# Cryptography and certificate tools (Reset-Rollout specific)
openssl

# Networking (for future PXE expansion)
iproute2
iputils-ping

# Diagnostics
vim-tiny
less
file
EOF
    pass "Package list written."
}

#──────────────────────────────────────────────────────────────────────────────
# HOOKS — Install Reset-Rollout libraries and configure auto-launch
#──────────────────────────────────────────────────────────────────────────────
write_hooks() {
    info "Writing build hooks..."
    mkdir -p "$BUILD_DIR/config/hooks/live"
    mkdir -p "$BUILD_DIR/config/includes.chroot/opt/reset-rollout"
    mkdir -p "$BUILD_DIR/config/includes.chroot/etc/profile.d"

    # Copy Reset-Rollout core library into the image
    if [[ -f "$SCRIPT_DIR/lib_common.sh" ]]; then
        cp "$SCRIPT_DIR/lib_common.sh" \
           "$BUILD_DIR/config/includes.chroot/opt/reset-rollout/lib_common.sh"
        chmod +x "$BUILD_DIR/config/includes.chroot/opt/reset-rollout/lib_common.sh"
        pass "lib_common.sh copied to image."
    else
        warn "lib_common.sh not found at $SCRIPT_DIR — skipping"
    fi

    # Copy tools directory if it exists
    if [[ -d "$SCRIPT_DIR/tools" ]]; then
        mkdir -p "$BUILD_DIR/config/includes.chroot/opt/reset-rollout/tools"
        cp -a "$SCRIPT_DIR/tools"/* "$BUILD_DIR/config/includes.chroot/opt/reset-rollout/tools/" 2>/dev/null || true
        chmod -R +x "$BUILD_DIR/config/includes.chroot/opt/reset-rollout/tools/" 2>/dev/null || true
        pass "tools/ directory copied to image."
    fi

    # Auto-launch hook — runs Reset-Rollout session init on TTY1 login
    # The live image auto-logs in as root; this triggers the session.
    cat > "$BUILD_DIR/config/includes.chroot/etc/profile.d/reset_rollout.sh" << 'HOOKEOF'
#!/bin/bash
# Auto-launch Reset-Rollout on TTY1 only
if [[ "$(tty)" == "/dev/tty1" ]] && [[ "$(id -u)" -eq 0 ]]; then
    clear
    echo ""
    echo "  Reset-Rollout — NIST SP 800-88 Rev.1 Forensic Staging System"
    echo "  Initializing. Please wait..."
    echo ""
    sleep 2

    # Source Reset-Rollout library
    if [[ -f /opt/reset-rollout/lib_common.sh ]]; then
        source /opt/reset-rollout/lib_common.sh
        
        # Initialize session (will auto-detect and mount WDDATA read-only, WIPETEMP rw)
        local serial
        serial=$(hostname)-$(date +%s)
        session_init "$serial"
        
        # Provide shell with Reset-Rollout helpers pre-loaded
        # Operator can now call safe_stage_file, encrypt_and_stage.sh, etc.
        echo ""
        echo "  Reset-Rollout session initialized."
        echo "  DATA_MOUNT: ${DATA_MOUNT:-(not mounted)}"
        echo "  WORK_MOUNT: ${WORK_MOUNT:-(not mounted)}"
        echo "  AUDIT_LOG: $AUDIT_LOG"
        echo ""
        echo "  Available functions:"
        echo "    safe_stage_file <dst> <src>   — stage files for encryption"
        echo "    session_close [status]        — close session and unmount USBs"
        echo ""
        bash
    else
        echo "ERROR: lib_common.sh not found at /opt/reset-rollout/lib_common.sh"
        bash
    fi
fi
HOOKEOF

    chmod +x "$BUILD_DIR/config/includes.chroot/etc/profile.d/reset_rollout.sh"

    # Build hook — configure auto-login for root on TTY1
    cat > "$BUILD_DIR/config/hooks/live/0010-autologin.hook.chroot" << 'AUTOEOF'
#!/bin/bash
# Configure getty to auto-login root on TTY1
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF
AUTOEOF

    chmod +x "$BUILD_DIR/config/hooks/live/0010-autologin.hook.chroot"

    # Build hook — configure terminal and environment
    cat > "$BUILD_DIR/config/hooks/live/0020-tool-config.hook.chroot" << 'TOOLEOF'
#!/bin/bash
# Set default terminal type for consistent rendering
echo 'TERM=xterm-256color' >> /etc/environment
TOOLEOF

    chmod +x "$BUILD_DIR/config/hooks/live/0020-tool-config.hook.chroot"

    # Build hook — disable display manager and force multi-user (text) target
    # Without this, live-build's default desktop spin starts X/lightdm on boot
    # which steals the display from TTY1 where our session runs.
    cat > "$BUILD_DIR/config/hooks/live/0030-disable-dm.hook.chroot" << 'DMEOF'
#!/bin/bash
# Disable all display managers — this is a forensic tool, no GUI needed
systemctl disable gdm3    2>/dev/null || true
systemctl disable gdm     2>/dev/null || true
systemctl disable lightdm 2>/dev/null || true
systemctl disable sddm    2>/dev/null || true
systemctl disable xdm     2>/dev/null || true
# Boot to multi-user text target, not graphical
systemctl set-default multi-user.target
DMEOF

    chmod +x "$BUILD_DIR/config/hooks/live/0030-disable-dm.hook.chroot"

    # GRUB config — set auto-boot timeout so operator doesn't have to hit Enter
    mkdir -p "$BUILD_DIR/config/includes.binary/boot/grub"
    cat > "$BUILD_DIR/config/includes.binary/boot/grub/grub.cfg" << 'GRUBEOF'
set default=0
set timeout=5
GRUBEOF

    pass "Hooks written."
}

#──────────────────────────────────────────────────────────────────────────────
# BUILD
#──────────────────────────────────────────────────────────────────────────────
build() {
    info "Building live image. This will take 10-20 minutes..."
    cd "$BUILD_DIR"
    lb build 2>&1 | tee /tmp/rr_build.log

    local iso
    iso=$(find "$BUILD_DIR" -name "*.iso" | head -1)
    [[ -z "$iso" ]] && fatal "Build completed but ISO not found. Check /tmp/rr_build.log"

    cp "$iso" "$OUTPUT_ISO"
    pass "ISO built successfully: $OUTPUT_ISO"

    local size
    size=$(du -h "$OUTPUT_ISO" | awk '{print $1}')
    echo ""
    echo -e "${BOLD}  Output : $OUTPUT_ISO${NC}"
    echo -e "${BOLD}  Size   : $size${NC}"
    echo ""
    echo "  Next step: run build_usb.sh to write the ISO, certificates,"
    echo "  and Windows source files to the deployment USB."
    echo ""
}

#──────────────────────────────────────────────────────────────────────────────
# MAIN
#──────────────────────────────────────────────────────────────────────────────
preflight
configure
write_packages
write_hooks
build

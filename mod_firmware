#!/bin/bash
#==============================================================================
# mod_firmware.sh
# Firmware acquisition and analysis module.
#
# Supports:
#   - flashrom internal read (system powered)
#   - flashrom via CH341A/Pomona clip (system off, external)
#   - Double-read verification (read twice, compare hashes)
#   - me_cleaner analysis of Intel ME region
#   - binwalk firmware analysis
#   - strings extraction
#
# Output: SERIAL_DATE_firmware.bin + hash + binwalk report
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"

FIRMWARE_WORK="$WORK_DIR/firmware"

#──────────────────────────────────────────────────────────────────────────────
# DETECT CH341A
#──────────────────────────────────────────────────────────────────────────────
detect_ch341a() {
    lsusb 2>/dev/null | grep -qi "1a86:5512\|1a86:5523" && return 0
    return 1
}

#──────────────────────────────────────────────────────────────────────────────
# BUILD FIRMWARE FILENAME
#──────────────────────────────────────────────────────────────────────────────
build_fw_name() {
    local serial="$1"
    local suffix="$2"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    echo "${serial}_${ts}_${suffix}.bin"
}

#──────────────────────────────────────────────────────────────────────────────
# READ FIRMWARE — INTERNAL
# System must be powered. flashrom reads via /dev/mem or native Linux driver.
#──────────────────────────────────────────────────────────────────────────────
read_internal() {
    local dest_dir="$1"
    local serial="$2"

    if ! command -v flashrom &>/dev/null; then
        msg_box "Missing Tool" "flashrom not installed.\napt install flashrom"
        return 1
    fi

    msg_box "Internal Read" \
"Reading firmware via internal programmer.

  System must remain powered during read.
  This may take 1-5 minutes.
  Do not close the lid or suspend.

Press OK to begin."

    local fw_file="$dest_dir/$(build_fw_name "$serial" "internal_read1")"
    local fw_file2="$dest_dir/$(build_fw_name "$serial" "internal_read2")"
    local log_file="$dest_dir/${serial}_internal_flashrom.log"

    audit_log "INFO" "flashrom internal read start — output: $fw_file"

    clear
    echo -e "${CYAN}Reading firmware (pass 1 of 2)...${NC}"
    flashrom -p internal -r "$fw_file" 2>&1 | tee "$log_file"
    local rc1=$?

    if [[ $rc1 -ne 0 ]]; then
        audit_log "ERROR" "flashrom internal read 1 failed (rc=$rc1)"
        msg_box "Read Failed" \
"flashrom internal read failed.

Common causes:
  • /dev/mem access denied — try: sudo rmmod lpc_ich
  • Chipset not supported
  • Secure Boot blocking access

Check log: $(basename "$log_file")"
        return 1
    fi

    echo -e "${CYAN}Reading firmware (pass 2 of 2 — verification)...${NC}"
    flashrom -p internal -r "$fw_file2" 2>&1 | tee -a "$log_file"
    local rc2=$?

    if [[ $rc2 -ne 0 ]]; then
        audit_log "ERROR" "flashrom internal read 2 failed (rc=$rc2)"
        msg_box "Verify Read Failed" "Second read failed. First read saved but unverified."
        return 1
    fi

    # Compare hashes of both reads
    local hash1 hash2
    hash1=$(sha256_file "$fw_file")
    hash2=$(sha256_file "$fw_file2")

    {
        echo "Read 1 SHA256: $hash1  $(basename "$fw_file")"
        echo "Read 2 SHA256: $hash2  $(basename "$fw_file2")"
    } >> "$log_file"

    if [[ "$hash1" == "$hash2" ]]; then
        audit_log "INFO" "Firmware reads match — verified. SHA256: $hash1"
        # Keep only one verified copy, remove duplicate
        rm -f "$fw_file2"
        echo "$hash1  $(basename "$fw_file")" > "${fw_file}.sha256"

        msg_box "Read Complete" \
"Firmware read and verified.

  File   : $(basename "$fw_file")
  SHA256 : ${hash1:0:32}...
  Verify : PASSED (both reads match)"

        LAST_FW_FILE="$fw_file"
        return 0
    else
        audit_log "WARN" "Firmware reads DO NOT MATCH — possible instability"
        msg_box "Verification Warning" \
"Both reads completed but hashes DIFFER.

  Read 1: ${hash1:0:32}...
  Read 2: ${hash2:0:32}...

Both files saved. System may be unstable.
Recommend: re-read or use external programmer."
        LAST_FW_FILE="$fw_file"
        return 1
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# READ FIRMWARE — EXTERNAL (CH341A + Pomona clip)
#──────────────────────────────────────────────────────────────────────────────
read_external() {
    local dest_dir="$1"
    local serial="$2"

    if ! command -v flashrom &>/dev/null; then
        msg_box "Missing Tool" "flashrom not installed."
        return 1
    fi

    # Check for CH341A
    if ! detect_ch341a; then
        msg_box "CH341A Not Found" \
"CH341A programmer not detected on USB.

  • Connect CH341A to USB port
  • Attach Pomona clip to flash chip
  • System should be POWERED OFF
  • Retry this option"
        return 1
    fi

    msg_box "External Read — CH341A + Pomona" \
"CH341A detected.

Before continuing:
  1. Target system must be POWERED OFF
  2. Pomona clip attached to SPI flash chip
  3. CH341A connected to this machine

flashrom will auto-detect the chip.
Three reads will be taken and compared.

Press OK to begin."

    local fw1="$dest_dir/$(build_fw_name "$serial" "ext_read1")"
    local fw2="$dest_dir/$(build_fw_name "$serial" "ext_read2")"
    local fw3="$dest_dir/$(build_fw_name "$serial" "ext_read3")"
    local log_file="$dest_dir/${serial}_ch341a_flashrom.log"

    audit_log "INFO" "CH341A external read start — $serial"

    clear
    echo -e "${CYAN}CH341A: Detecting flash chip...${NC}"
    flashrom -p ch341a_spi 2>&1 | tee "$log_file"

    echo -e "${CYAN}Read 1 of 3...${NC}"
    flashrom -p ch341a_spi -r "$fw1" 2>&1 | tee -a "$log_file"
    local rc1=$?

    echo -e "${CYAN}Read 2 of 3...${NC}"
    flashrom -p ch341a_spi -r "$fw2" 2>&1 | tee -a "$log_file"
    local rc2=$?

    echo -e "${CYAN}Read 3 of 3...${NC}"
    flashrom -p ch341a_spi -r "$fw3" 2>&1 | tee -a "$log_file"
    local rc3=$?

    if [[ $rc1 -ne 0 || $rc2 -ne 0 || $rc3 -ne 0 ]]; then
        audit_log "ERROR" "One or more CH341A reads failed"
        msg_box "Read Error" "One or more reads failed.\nCheck chip connection and retry."
        return 1
    fi

    # Compare all three hashes
    local h1 h2 h3
    h1=$(sha256_file "$fw1")
    h2=$(sha256_file "$fw2")
    h3=$(sha256_file "$fw3")

    {
        echo "Read 1 SHA256: $h1"
        echo "Read 2 SHA256: $h2"
        echo "Read 3 SHA256: $h3"
    } >> "$log_file"

    if [[ "$h1" == "$h2" && "$h2" == "$h3" ]]; then
        audit_log "INFO" "All 3 reads match — verified. SHA256: $h1"
        # Keep read 1, remove duplicates
        rm -f "$fw2" "$fw3"
        echo "$h1  $(basename "$fw1")" > "${fw1}.sha256"
        LAST_FW_FILE="$fw1"

        msg_box "External Read Complete" \
"All 3 reads match — firmware verified.

  File   : $(basename "$fw1")
  SHA256 : ${h1:0:32}...
  Verify : PASSED"
        return 0
    else
        audit_log "WARN" "CH341A reads do not all match — connection may be unstable"
        msg_box "Verification Warning" \
"Reads do not all match.

  R1: ${h1:0:24}...
  R2: ${h2:0:24}...
  R3: ${h3:0:24}...

All three files saved.
Check Pomona clip connection and retry."
        LAST_FW_FILE="$fw1"
        return 1
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# ME_CLEANER ANALYSIS
# Analyzes Intel ME firmware region — does not modify, analysis only
#──────────────────────────────────────────────────────────────────────────────
analyze_me() {
    local fw_file="$1"
    local dest_dir="$2"

    if ! command -v me_cleaner &>/dev/null; then
        # Try to find it
        local me_cleaner_path
        me_cleaner_path=$(find /opt /usr /home -name "me_cleaner.py" 2>/dev/null | head -1)
        if [[ -z "$me_cleaner_path" ]]; then
            msg_box "me_cleaner Not Found" \
"me_cleaner.py not found.

Install: git clone https://github.com/corna/me_cleaner
Place me_cleaner.py in /opt/wipedeploy/tools/"
            return 1
        fi
        ME_CLEANER_CMD="python3 $me_cleaner_path"
    else
        ME_CLEANER_CMD="me_cleaner"
    fi

    local report="$dest_dir/$(basename "$fw_file" .bin)_me_analysis.txt"

    {
        echo "me_cleaner Analysis Report"
        echo "File    : $fw_file"
        echo "Date    : $(date)"
        echo "SHA256  : $(sha256_file "$fw_file")"
        echo ""
        echo "=== me_cleaner -c (check only, no modification) ==="
        echo ""
        $ME_CLEANER_CMD -c "$fw_file" 2>&1
    } > "$report"

    audit_log "INFO" "me_cleaner analysis complete: $report"

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "Intel ME Analysis — $(basename "$fw_file")" \
           --textbox "$report" \
           22 78
}

#──────────────────────────────────────────────────────────────────────────────
# BINWALK ANALYSIS
#──────────────────────────────────────────────────────────────────────────────
analyze_binwalk() {
    local fw_file="$1"
    local dest_dir="$2"

    if ! command -v binwalk &>/dev/null; then
        msg_box "Missing Tool" "binwalk not installed.\napt install binwalk"
        return 1
    fi

    local report="$dest_dir/$(basename "$fw_file" .bin)_binwalk.txt"

    clear
    echo -e "${CYAN}Running binwalk analysis on $(basename "$fw_file")...${NC}"
    echo ""

    {
        echo "binwalk Analysis Report"
        echo "File   : $fw_file"
        echo "Date   : $(date)"
        echo "SHA256 : $(sha256_file "$fw_file")"
        echo ""
        echo "=== Signature Scan ==="
        binwalk "$fw_file" 2>&1
        echo ""
        echo "=== Entropy Analysis ==="
        binwalk -E "$fw_file" 2>&1
    } > "$report"

    audit_log "INFO" "binwalk analysis complete: $report"

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "binwalk Analysis — $(basename "$fw_file")" \
           --textbox "$report" \
           22 78
}

#──────────────────────────────────────────────────────────────────────────────
# STRINGS EXTRACTION
#──────────────────────────────────────────────────────────────────────────────
analyze_strings() {
    local fw_file="$1"
    local dest_dir="$2"
    local report="$dest_dir/$(basename "$fw_file" .bin)_strings.txt"

    {
        echo "strings Extraction"
        echo "File   : $fw_file"
        echo "Date   : $(date)"
        echo ""
        strings -n 8 "$fw_file" 2>&1
    } > "$report"

    audit_log "INFO" "strings extraction complete: $report"

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "Strings — $(basename "$fw_file")" \
           --textbox "$report" \
           22 78
}

#──────────────────────────────────────────────────────────────────────────────
# FIRMWARE MENU
#──────────────────────────────────────────────────────────────────────────────
firmware_menu() {
    local serial="$1"
    local dest_dir="$FIRMWARE_DIR"
    mkdir -p "$dest_dir"
    LAST_FW_FILE=""

    while true; do
        # Build CH341A status string
        local ch341_status
        detect_ch341a && ch341_status="CH341A: DETECTED" || ch341_status="CH341A: not found"

        local choice
        choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                        --title "Firmware Module" \
                        --menu \
"Serial : $serial
$ch341_status

Select operation:" \
                        18 60 8 \
                        "1" "Read firmware — internal (system on)" \
                        "2" "Read firmware — CH341A/Pomona (system off)" \
                        "3" "Analyze with me_cleaner (Intel ME)" \
                        "4" "Analyze with binwalk" \
                        "5" "Extract strings" \
                        "6" "Select existing firmware file" \
                        "7" "Back to main menu" \
                        3>&1 1>&2 2>&3)

        [[ $? -ne 0 || "$choice" == "7" ]] && break

        case "$choice" in
            1) read_internal "$dest_dir" "$serial" ;;
            2) read_external "$dest_dir" "$serial" ;;
            3)
                if [[ -z "$LAST_FW_FILE" ]]; then
                    browse_files "$dest_dir" "Select firmware .bin file"
                    LAST_FW_FILE="$REPLY_PATH"
                fi
                [[ -f "$LAST_FW_FILE" ]] && analyze_me "$LAST_FW_FILE" "$dest_dir"
                ;;
            4)
                if [[ -z "$LAST_FW_FILE" ]]; then
                    browse_files "$dest_dir" "Select firmware .bin file"
                    LAST_FW_FILE="$REPLY_PATH"
                fi
                [[ -f "$LAST_FW_FILE" ]] && analyze_binwalk "$LAST_FW_FILE" "$dest_dir"
                ;;
            5)
                if [[ -z "$LAST_FW_FILE" ]]; then
                    browse_files "$dest_dir" "Select firmware .bin file"
                    LAST_FW_FILE="$REPLY_PATH"
                fi
                [[ -f "$LAST_FW_FILE" ]] && analyze_strings "$LAST_FW_FILE" "$dest_dir"
                ;;
            6)
                browse_files "$dest_dir" "Select firmware .bin file"
                [[ -n "$REPLY_PATH" ]] && LAST_FW_FILE="$REPLY_PATH"
                ;;
        esac
    done
}
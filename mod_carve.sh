#!/bin/bash
#==============================================================================
# mod_carve.sh
# File carving and artifact extraction module.
#
# foremost      — signature-based file carving from raw device/image
# photorec      — file recovery (interactive TUI)
# bulk_extractor — artifact extraction: emails, URLs, credit cards,
#                  domains, phone numbers, MAC addresses
#
# Output saved to WDDATA/Images/SERIAL_DATE_carve/
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"

#──────────────────────────────────────────────────────────────────────────────
# FOREMOST
#──────────────────────────────────────────────────────────────────────────────
run_foremost() {
    local dev="$1"
    local serial="$2"
    local out_dir="$IMAGE_DIR/${serial}_$(date +%Y%m%d_%H%M%S)_foremost"

    if ! command -v foremost &>/dev/null; then
        msg_box "Missing Tool" "foremost not installed.\napt install foremost"
        return 1
    fi

    # File type selection
    local types
    types=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                   --title "foremost — File Types" \
                   --checklist "Select file types to carve:" \
                   18 55 10 \
                   "jpg"  "JPEG images"       ON \
                   "png"  "PNG images"        ON \
                   "gif"  "GIF images"        ON \
                   "pdf"  "PDF documents"     ON \
                   "doc"  "Word documents"    ON \
                   "zip"  "ZIP archives"      ON \
                   "exe"  "Executables"       ON \
                   "htm"  "HTML files"        OFF \
                   "mp4"  "MP4 video"         OFF \
                   "all"  "All supported types" OFF \
                   3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$types" ]] && return 1

    local type_str
    type_str=$(echo "$types" | tr -d '"' | tr ' ' ',')
    mkdir -p "$out_dir"

    audit_log "INFO" "foremost start: $dev types=$type_str output=$out_dir"

    clear
    echo -e "${CYAN}Running foremost on $dev...${NC}"
    echo -e "${DIM}Output: $out_dir${NC}"
    echo ""

    foremost -t "$type_str" \
             -i "$dev" \
             -o "$out_dir" \
             -v 2>&1

    local rc=$?
    audit_log "INFO" "foremost complete: rc=$rc output=$out_dir"

    local file_count
    file_count=$(find "$out_dir" -type f ! -name "audit.txt" | wc -l)

    msg_box "foremost Complete" \
"Carving complete.

  Source : $dev
  Output : $out_dir
  Files  : $file_count carved
  Exit   : $rc

Review audit.txt in output directory for details."
}

#──────────────────────────────────────────────────────────────────────────────
# PHOTOREC
# photorec is interactive — launches its own TUI
#──────────────────────────────────────────────────────────────────────────────
run_photorec() {
    local dev="$1"
    local serial="$2"
    local out_dir="$IMAGE_DIR/${serial}_$(date +%Y%m%d_%H%M%S)_photorec"

    if ! command -v photorec &>/dev/null; then
        msg_box "Missing Tool" "photorec not installed.\napt install testdisk"
        return 1
    fi

    mkdir -p "$out_dir"
    audit_log "INFO" "photorec start: $dev output=$out_dir"

    msg_box "photorec" \
"Launching photorec interactive recovery.

  Source     : $dev
  Output dir : $out_dir

photorec will open its own interface.
Select the device and partition to scan.
Set output directory to: $out_dir

Press OK to launch."

    clear
    photorec "$dev"

    audit_log "INFO" "photorec session ended: $dev"

    local file_count
    file_count=$(find "$out_dir" -type f 2>/dev/null | wc -l)
    msg_box "photorec Complete" "Session ended.\nFiles in output: $file_count"
}

#──────────────────────────────────────────────────────────────────────────────
# BULK_EXTRACTOR
# Extracts artifacts: emails, URLs, credit cards, phones, MACs, domains
#──────────────────────────────────────────────────────────────────────────────
run_bulk_extractor() {
    local dev="$1"
    local serial="$2"
    local out_dir="$IMAGE_DIR/${serial}_$(date +%Y%m%d_%H%M%S)_bulk"

    if ! command -v bulk_extractor &>/dev/null; then
        msg_box "Missing Tool" "bulk_extractor not installed.\napt install bulk-extractor"
        return 1
    fi

    # Scanner selection
    local scanners
    scanners=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                      --title "bulk_extractor — Scanners" \
                      --checklist "Select artifact types to extract:" \
                      18 60 10 \
                      "email"      "Email addresses"      ON \
                      "url"        "URLs / web addresses" ON \
                      "domain"     "Domain names"         ON \
                      "ccn"        "Credit card numbers"  ON \
                      "telephone"  "Phone numbers"        ON \
                      "ether"      "MAC addresses"        ON \
                      "exif"       "EXIF metadata"        ON \
                      "zip"        "ZIP/archive contents" OFF \
                      "pdf"        "PDF metadata"         OFF \
                      "json"       "JSON data"            OFF \
                      3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$scanners" ]] && return 1

    mkdir -p "$out_dir"

    # Build scanner flags — bulk_extractor uses -E to disable all then -e to enable
    local scanner_args=("-E" "all")
    for s in $scanners; do
        s=$(echo "$s" | tr -d '"')
        scanner_args+=("-e" "$s")
    done

    audit_log "INFO" "bulk_extractor start: $dev scanners=$scanners output=$out_dir"

    clear
    echo -e "${CYAN}Running bulk_extractor on $dev...${NC}"
    echo -e "${DIM}Output: $out_dir${NC}"
    echo ""

    bulk_extractor \
        "${scanner_args[@]}" \
        -o "$out_dir" \
        -j "$(nproc)" \
        "$dev" 2>&1

    local rc=$?
    audit_log "INFO" "bulk_extractor complete: rc=$rc"

    # Build summary of findings
    local summary_file="$out_dir/wipedeploy_summary.txt"
    {
        echo "bulk_extractor Summary"
        echo "Source  : $dev"
        echo "Serial  : $serial"
        echo "Date    : $(date)"
        echo ""
        for f in "$out_dir"/*.txt; do
            [[ -f "$f" ]] || continue
            local count
            count=$(wc -l < "$f" 2>/dev/null || echo 0)
            [[ $count -gt 0 ]] && echo "  $(basename "$f"): $count entries"
        done
    } > "$summary_file"

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "bulk_extractor Complete" \
           --textbox "$summary_file" \
           20 65
}

#──────────────────────────────────────────────────────────────────────────────
# HASHDEEP — recursive hash entire filesystem before wipe
#──────────────────────────────────────────────────────────────────────────────
run_hashdeep() {
    local mount_point="$1"
    local serial="$2"
    local out_file="$IMAGE_DIR/${serial}_$(date +%Y%m%d_%H%M%S)_hashdeep.txt"

    if ! command -v hashdeep &>/dev/null; then
        msg_box "Missing Tool" "hashdeep not installed.\napt install hashdeep"
        return 1
    fi

    if [[ ! -d "$mount_point" ]] || ! mountpoint -q "$mount_point" 2>/dev/null; then
        msg_box "Not Mounted" "Drive not mounted at $mount_point.\nMount it via Browse module first."
        return 1
    fi

    audit_log "INFO" "hashdeep start: $mount_point → $out_file"

    clear
    echo -e "${CYAN}Computing recursive hashes of $mount_point...${NC}"
    echo -e "${DIM}This may take a while for large drives.${NC}"
    echo ""

    hashdeep -r -l -o f "$mount_point" > "$out_file" 2>&1

    local count
    count=$(grep -c "^[0-9]" "$out_file" 2>/dev/null || echo 0)

    audit_log "INFO" "hashdeep complete: $count files hashed → $out_file"

    msg_box "hashdeep Complete" \
"Recursive hash complete.

  Source : $mount_point
  Files  : $count
  Output : $(basename "$out_file")"
}

#──────────────────────────────────────────────────────────────────────────────
# CARVE MODULE MENU
#──────────────────────────────────────────────────────────────────────────────
carve_menu() {
    local dev="$1"
    local serial="$2"

    while true; do
        local choice
        choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                        --title "File Carving / Artifact Extraction" \
                        --menu \
"Target : $dev
Serial : $serial

Select tool:" \
                        17 60 6 \
                        "1" "foremost — file carving by signature" \
                        "2" "photorec — interactive file recovery" \
                        "3" "bulk_extractor — emails/URLs/CCNs/MACs" \
                        "4" "hashdeep — recursive filesystem hash" \
                        "5" "Back to main menu" \
                        3>&1 1>&2 2>&3)

        [[ $? -ne 0 || "$choice" == "5" ]] && break

        case "$choice" in
            1) run_foremost "$dev" "$serial" ;;
            2) run_photorec "$dev" "$serial" ;;
            3) run_bulk_extractor "$dev" "$serial" ;;
            4) run_hashdeep "/tmp/wd_target" "$serial" ;;
        esac
    done
}
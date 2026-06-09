#!/bin/bash
#==============================================================================
# mod_report.sh
# Plain text report generation.
# Compiles audit log, scan results, wipe log, and system info
# into a single formatted .txt report per machine session.
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"

#──────────────────────────────────────────────────────────────────────────────
# GENERATE REPORT
#──────────────────────────────────────────────────────────────────────────────
generate_report() {
    local serial="$1"
    local dev="$2"
    local report_file="$LOG_DIR/${SESSION_START}_${serial}_REPORT.txt"

    audit_log "INFO" "Generating report: $report_file"

    {
        echo "============================================================"
        echo "  WipeDeploy v${WIPEDEPLOY_VERSION} — Session Report"
        echo "  NIST SP 800-88 Rev.1 Sanitization Toolkit"
        echo "============================================================"
        echo ""
        echo "  Generated : $(date)"
        echo "  Session   : $SESSION_START"
        echo ""

        echo "------------------------------------------------------------"
        echo "  SYSTEM INFORMATION"
        echo "------------------------------------------------------------"
        echo "  Serial    : $serial"
        echo "  Model     : $(get_system_model)"
        echo "  BIOS Ver  : $(get_bios_version)"
        echo "  Kernel    : $(uname -r)"
        echo "  Hostname  : $(hostname 2>/dev/null || echo 'unknown')"
        echo ""

        echo "  Drive     : $dev"
        echo "  Type      : $(get_drive_type "$dev")"
        echo "  Size      : $(get_drive_size "$dev")"
        echo "  Model     : $(get_drive_model "$dev")"
        echo "  D.Serial  : $(get_serial "$dev")"
        echo ""

        local msdm
        msdm=$(get_msdm_key)
        if [[ -n "$msdm" ]]; then
            echo "  MSDM Key  : ${msdm:0:5}XXXXX-XXXXX-XXXXX-XXXXX (redacted)"
        else
            echo "  MSDM Key  : NOT FOUND"
        fi
        echo ""

        echo "------------------------------------------------------------"
        echo "  SMART DATA"
        echo "------------------------------------------------------------"
        local smart_log
        smart_log=$(find "$LOG_DIR" -name "smart_${SESSION_START}_*.txt" 2>/dev/null | head -1)
        if [[ -f "$smart_log" ]]; then
            # Extract key SMART attributes only
            grep -E "PASSED|FAILED|Reallocated|Pending|Uncorrectable|Power_On|Temperature" \
                "$smart_log" 2>/dev/null || echo "  (no SMART data)"
        else
            echo "  SMART data not collected this session."
        fi
        echo ""

        echo "------------------------------------------------------------"
        echo "  FORENSIC IMAGING"
        echo "------------------------------------------------------------"
        local image_logs
        image_logs=$(find "$IMAGE_DIR" -name "${serial}_*.log" 2>/dev/null)
        if [[ -n "$image_logs" ]]; then
            while IFS= read -r img_log; do
                echo "  Image log: $(basename "$img_log")"
                grep -E "Source|Output|SHA256|Verify|End" "$img_log" 2>/dev/null | \
                    sed 's/^/    /'
                echo ""
            done <<< "$image_logs"
        else
            echo "  No forensic images taken this session."
        fi

        echo "------------------------------------------------------------"
        echo "  FIRMWARE"
        echo "------------------------------------------------------------"
        local fw_logs
        fw_logs=$(find "$FIRMWARE_DIR" -name "${serial}_*.log" 2>/dev/null)
        if [[ -n "$fw_logs" ]]; then
            while IFS= read -r fw_log; do
                echo "  Firmware log: $(basename "$fw_log")"
                grep -E "SHA256|Verify|Read [0-9]" "$fw_log" 2>/dev/null | \
                    sed 's/^/    /'
                echo ""
            done <<< "$fw_logs"
        else
            echo "  No firmware dumps taken this session."
        fi

        echo "------------------------------------------------------------"
        echo "  AV / MALWARE SCAN"
        echo "------------------------------------------------------------"
        local av_report
        av_report=$(find "$LOG_DIR" -name "${SESSION_START}_${serial}_av_report.txt" 2>/dev/null | head -1)
        if [[ -f "$av_report" ]]; then
            grep -E "Infected|MATCH|Total|Scanned|Rules|Matches" "$av_report" 2>/dev/null | \
                sed 's/^/  /' || echo "  (no findings)"
        else
            echo "  No AV/malware scan performed this session."
        fi
        echo ""

        echo "------------------------------------------------------------"
        echo "  WIPE LOG"
        echo "------------------------------------------------------------"
        local wipe_log
        wipe_log=$(find "$LOG_DIR" -name "${SESSION_START}_${serial}_wipe.log" 2>/dev/null | head -1)
        if [[ -f "$wipe_log" ]]; then
            cat "$wipe_log"
        else
            echo "  No wipe performed this session."
        fi
        echo ""

        echo "------------------------------------------------------------"
        echo "  NETWORK SCAN"
        echo "------------------------------------------------------------"
        local net_log
        net_log=$(find "$LOG_DIR" -name "${SESSION_START}_${serial}_nmap.txt" 2>/dev/null | head -1)
        if [[ -f "$net_log" ]]; then
            head -30 "$net_log" 2>/dev/null | sed 's/^/  /'
            echo "  ... (full report: $(basename "$net_log"))"
        else
            echo "  No network scan performed this session."
        fi
        echo ""

        echo "------------------------------------------------------------"
        echo "  FULL AUDIT LOG"
        echo "------------------------------------------------------------"
        if [[ -f "$AUDIT_LOG" ]]; then
            cat "$AUDIT_LOG"
        else
            echo "  Audit log not found."
        fi
        echo ""

        echo "============================================================"
        echo "  END OF REPORT"
        echo "  $(date)"
        echo "============================================================"

    } > "$report_file"

    audit_log "INFO" "Report generated: $report_file"

    msg_box "Report Generated" \
"Session report saved.

  File: $(basename "$report_file")
  Path: $LOG_DIR"

    # Offer to view
    if confirm "View Report" "View the report now?"; then
        dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
               --title "Session Report — $serial" \
               --textbox "$report_file" \
               22 78
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# VIEW EXISTING REPORTS
#──────────────────────────────────────────────────────────────────────────────
view_reports() {
    local reports
    reports=$(find "$LOG_DIR" -name "*_REPORT.txt" 2>/dev/null | sort -r)

    if [[ -z "$reports" ]]; then
        msg_box "No Reports" "No reports found in $LOG_DIR."
        return
    fi

    local menu_items=()
    while IFS= read -r rpt; do
        menu_items+=("$rpt" "$(basename "$rpt")")
    done <<< "$reports"

    local choice
    choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "View Reports" \
                    --menu "Select report to view:" \
                    18 78 10 \
                    "${menu_items[@]}" \
                    3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$choice" ]] && return

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "Report — $(basename "$choice")" \
           --textbox "$choice" \
           22 78
}

#──────────────────────────────────────────────────────────────────────────────
# REPORT MENU
#──────────────────────────────────────────────────────────────────────────────
report_menu() {
    local serial="$1"
    local dev="$2"

    while true; do
        local choice
        choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                        --title "Reports" \
                        --menu \
"Serial : $serial
Session: $SESSION_START" \
                        12 55 4 \
                        "1" "Generate session report" \
                        "2" "View existing reports" \
                        "3" "Back to main menu" \
                        3>&1 1>&2 2>&3)

        [[ $? -ne 0 || "$choice" == "3" ]] && break

        case "$choice" in
            1) generate_report "$serial" "$dev" ;;
            2) view_reports ;;
        esac
    done
}
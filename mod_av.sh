#!/bin/bash
#==============================================================================
# mod_av.sh
# Antivirus and malware detection module.
#
# ClamAV — signature-based AV scanning
# YARA   — rule-based pattern matching
#
# Rule directories:
#   /opt/wipedeploy/rules/core/     — baked into ISO at build time
#   /opt/wipedeploy/rules/custom/   — loaded from WDDATA at runtime
#   /opt/wipedeploy/rules/community/— placeholder for future rule sets
#
# Target: mounted filesystem, specific directory, or raw device
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"

RULES_BASE="/opt/wipedeploy/rules"
RULES_CORE="$RULES_BASE/core"
RULES_CUSTOM="$RULES_BASE/custom"
RULES_COMMUNITY="$RULES_BASE/community"
RULES_RUNTIME="$DATA_DIR/rules"   # WDDATA rules dir — loaded at scan time

MNT_SCAN="/tmp/wd_scan"

#──────────────────────────────────────────────────────────────────────────────
# RULE MANAGEMENT — merge core + WDDATA custom rules
#──────────────────────────────────────────────────────────────────────────────
build_rule_set() {
    local combined_dir="$WORK_DIR/yara_rules"
    mkdir -p "$combined_dir"

    # Copy core rules
    [[ -d "$RULES_CORE" ]] && \
        find "$RULES_CORE" -name "*.yar" -o -name "*.yara" | \
        xargs -I{} cp {} "$combined_dir/" 2>/dev/null

    # Copy custom rules from ISO
    [[ -d "$RULES_CUSTOM" ]] && \
        find "$RULES_CUSTOM" -name "*.yar" -o -name "*.yara" | \
        xargs -I{} cp {} "$combined_dir/" 2>/dev/null

    # Copy runtime rules from WDDATA (operator-expandable)
    [[ -d "$RULES_RUNTIME" ]] && \
        find "$RULES_RUNTIME" -name "*.yar" -o -name "*.yara" | \
        xargs -I{} cp {} "$combined_dir/" 2>/dev/null

    local count
    count=$(find "$combined_dir" -name "*.yar" -o -name "*.yara" | wc -l)
    audit_log "INFO" "YARA rule set built: $count rules in $combined_dir"
    echo "$combined_dir"
}

show_rule_summary() {
    local core_count custom_count runtime_count
    core_count=$(find "$RULES_CORE" -name "*.yar" -o -name "*.yara" 2>/dev/null | wc -l)
    custom_count=$(find "$RULES_CUSTOM" -name "*.yar" -o -name "*.yara" 2>/dev/null | wc -l)
    runtime_count=$(find "$RULES_RUNTIME" -name "*.yar" -o -name "*.yara" 2>/dev/null | wc -l)

    msg_box "YARA Rule Summary" \
"Loaded rule sets:

  Core rules    : $core_count  (baked into ISO)
  Custom rules  : $custom_count  (ISO /opt/wipedeploy/rules/custom)
  WDDATA rules  : $runtime_count  (WDDATA/rules — operator expandable)

Total: $(( core_count + custom_count + runtime_count )) rules

To add rules: copy .yar/.yara files to
WDDATA/rules/ on this USB drive."
}

#──────────────────────────────────────────────────────────────────────────────
# MOUNT SCAN TARGET
#──────────────────────────────────────────────────────────────────────────────
mount_scan_target() {
    local dev="$1"
    mkdir -p "$MNT_SCAN"
    umount "$MNT_SCAN" 2>/dev/null || true

    local part
    part=$(lsblk -lnpo NAME "$dev" | sed -n '2p')
    [[ -z "$part" ]] && part="$dev"

    write_protect "$dev"
    mount -o ro,noexec,nosuid "$part" "$MNT_SCAN" 2>/dev/null || {
        msg_box "Mount Failed" \
"Could not mount $part for scanning.

Drive may be encrypted or filesystem unsupported.
You can still run raw device scans."
        return 1
    }
    audit_log "INFO" "Scan target mounted: $part → $MNT_SCAN"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# CLAMAV SCAN
#──────────────────────────────────────────────────────────────────────────────
run_clamav() {
    local target="$1"
    local report_file="$2"

    if ! command -v clamscan &>/dev/null; then
        msg_box "ClamAV Not Found" \
"clamscan not installed.
apt install clamav

Note: Virus definitions should be updated before deployment.
Run: freshclam"
        return 1
    fi

    # Check if definitions exist
    if ! find /var/lib/clamav -name "*.cvd" -o -name "*.cld" 2>/dev/null | grep -q .; then
        if ! confirm "No Definitions" \
"ClamAV virus definitions not found.

Scan will run but detection will be minimal.
Run freshclam to update definitions.

Continue anyway?"; then
            return 1
        fi
    fi

    audit_log "INFO" "ClamAV scan start: $target"

    local tmpfile="/tmp/wd_clam_$$.txt"

    (
        clamscan \
            --recursive \
            --infected \
            --bell \
            --log="$tmpfile" \
            --max-filesize=500M \
            --max-scansize=2G \
            "$target" 2>&1
        echo "100"
    ) | dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
               --title "ClamAV Scan" \
               --programbox "Scanning $target..." \
               20 78

    {
        echo "ClamAV Scan Report"
        echo "Target  : $target"
        echo "Date    : $(date)"
        echo ""
        cat "$tmpfile" 2>/dev/null
    } >> "$report_file"

    # Extract summary
    local infected
    infected=$(grep "Infected files:" "$tmpfile" 2>/dev/null | tail -1)
    audit_log "INFO" "ClamAV scan complete: $infected"

    rm -f "$tmpfile"

    if echo "$infected" | grep -qv ": 0$"; then
        msg_box "⚠ ClamAV — Threats Found" \
"$infected

Review full report for details.
Report: $(basename "$report_file")"
    else
        msg_box "ClamAV — Clean" "No threats detected.\n$infected"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# YARA SCAN
#──────────────────────────────────────────────────────────────────────────────
run_yara() {
    local target="$1"
    local report_file="$2"

    if ! command -v yara &>/dev/null; then
        msg_box "YARA Not Found" "yara not installed.\napt install yara"
        return 1
    fi

    local rules_dir
    rules_dir=$(build_rule_set)

    local rule_count
    rule_count=$(find "$rules_dir" -name "*.yar" -o -name "*.yara" | wc -l)

    if [[ $rule_count -eq 0 ]]; then
        msg_box "No Rules" \
"No YARA rules found.

Add .yar or .yara files to:
  /opt/wipedeploy/rules/core/
  /opt/wipedeploy/rules/custom/
  WDDATA/rules/"
        return 1
    fi

    audit_log "INFO" "YARA scan start: $target ($rule_count rules)"

    local tmpfile="/tmp/wd_yara_$$.txt"
    local error_file="/tmp/wd_yara_err_$$.txt"

    (
        find "$target" -type f 2>/dev/null | while IFS= read -r file; do
            for rule_file in "$rules_dir"/*.yar "$rules_dir"/*.yara; do
                [[ -f "$rule_file" ]] || continue
                yara -w "$rule_file" "$file" 2>>"$error_file" && \
                    echo "MATCH: $file" >> "$tmpfile"
            done
        done
        echo "YARA scan complete"
    ) | dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
               --title "YARA Scan ($rule_count rules)" \
               --programbox "Scanning $target..." \
               20 78

    local match_count
    match_count=$(grep -c "^MATCH:" "$tmpfile" 2>/dev/null || echo 0)

    {
        echo "YARA Scan Report"
        echo "Target     : $target"
        echo "Date       : $(date)"
        echo "Rules      : $rule_count"
        echo "Matches    : $match_count"
        echo ""
        echo "=== Matches ==="
        cat "$tmpfile" 2>/dev/null
        echo ""
        echo "=== Errors/Warnings ==="
        cat "$error_file" 2>/dev/null
    } >> "$report_file"

    audit_log "INFO" "YARA scan complete: $match_count matches"

    if [[ $match_count -gt 0 ]]; then
        dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
               --title "⚠ YARA — $match_count Match(es) Found" \
               --textbox "$tmpfile" \
               20 78
    else
        msg_box "YARA — Clean" "No rule matches detected.\n$rule_count rules scanned."
    fi

    rm -f "$tmpfile" "$error_file"
}

#──────────────────────────────────────────────────────────────────────────────
# SELECT SCAN TARGET
#──────────────────────────────────────────────────────────────────────────────
select_scan_target() {
    local dev="$1"

    local choice
    choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "Select Scan Target" \
                    --menu "What to scan?" \
                    12 55 4 \
                    "1" "Mounted filesystem ($MNT_SCAN)" \
                    "2" "Specific directory (browse)" \
                    "3" "Raw device ($dev)" \
                    "4" "Back" \
                    3>&1 1>&2 2>&3)

    [[ $? -ne 0 || "$choice" == "4" ]] && return 1

    case "$choice" in
        1)
            if [[ ! -d "$MNT_SCAN" ]] || ! mountpoint -q "$MNT_SCAN"; then
                mount_scan_target "$dev" || return 1
            fi
            SCAN_TARGET="$MNT_SCAN"
            ;;
        2)
            browse_files "$MNT_SCAN" "Select directory to scan"
            [[ -z "$REPLY_PATH" ]] && return 1
            SCAN_TARGET="$REPLY_PATH"
            ;;
        3)
            SCAN_TARGET="$dev"
            ;;
    esac
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# AV MODULE MENU
#──────────────────────────────────────────────────────────────────────────────
av_menu() {
    local dev="$1"
    local serial="$2"
    local report_file="$LOG_DIR/${SESSION_START}_${serial}_av_report.txt"

    # Mount target if not already mounted
    if ! mountpoint -q "$MNT_SCAN" 2>/dev/null; then
        mount_scan_target "$dev" || true
    fi

    while true; do
        local choice
        choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                        --title "AV / Malware Scanner" \
                        --menu \
"Target : $dev
Serial : $serial
Report : $(basename "$report_file")

Select scanner:" \
                        17 60 6 \
                        "1" "ClamAV scan" \
                        "2" "YARA scan" \
                        "3" "Run both (ClamAV + YARA)" \
                        "4" "View YARA rule summary" \
                        "5" "View scan report" \
                        "6" "Back to main menu" \
                        3>&1 1>&2 2>&3)

        [[ $? -ne 0 || "$choice" == "6" ]] && break

        case "$choice" in
            1)
                select_scan_target "$dev" || continue
                run_clamav "$SCAN_TARGET" "$report_file"
                ;;
            2)
                select_scan_target "$dev" || continue
                run_yara "$SCAN_TARGET" "$report_file"
                ;;
            3)
                select_scan_target "$dev" || continue
                run_clamav "$SCAN_TARGET" "$report_file"
                run_yara "$SCAN_TARGET" "$report_file"
                ;;
            4) show_rule_summary ;;
            5)
                [[ -f "$report_file" ]] && \
                    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                           --title "Scan Report" \
                           --textbox "$report_file" 22 78 || \
                    msg_box "No Report" "No scan report yet for this session."
                ;;
        esac
    done

    # Unmount scan target
    umount "$MNT_SCAN" 2>/dev/null || true
    write_unprotect "$dev"
}
#!/bin/bash
#==============================================================================
# mod_network.sh
# Network scanning and capture module.
#
# nmap    — active host/port/service/OS scanning
# tshark  — packet capture (active traffic analysis)
# arp     — local network discovery
#
# All results saved to WDDATA/Logs/SERIAL_DATE_network.txt
#==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"

#──────────────────────────────────────────────────────────────────────────────
# DETECT NETWORK INTERFACES
#──────────────────────────────────────────────────────────────────────────────
get_interfaces() {
    ip -o link show 2>/dev/null | \
        awk -F': ' '{print $2}' | \
        grep -v "^lo$\|^docker\|^virbr\|^br-" | \
        xargs
}

get_ip_info() {
    ip addr show 2>/dev/null | \
        grep -E "inet [0-9]" | \
        awk '{print $2, $NF}' | \
        grep -v "^127\."
}

detect_local_subnet() {
    ip route show 2>/dev/null | \
        grep -v "^default\|^169\." | \
        awk '{print $1}' | \
        grep "/" | head -1
}

#──────────────────────────────────────────────────────────────────────────────
# INTERFACE SELECTION
#──────────────────────────────────────────────────────────────────────────────
select_interface() {
    local ifaces
    ifaces=$(get_interfaces)
    [[ -z "$ifaces" ]] && msg_box "No Interfaces" "No network interfaces found." && return 1

    local menu_items=()
    for iface in $ifaces; do
        local ip
        ip=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
        ip="${ip:-no IP}"
        menu_items+=("$iface" "$ip")
    done

    local choice
    choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "Select Interface" \
                    --menu "Select network interface:" \
                    12 50 6 \
                    "${menu_items[@]}" \
                    3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && return 1
    REPLY_IFACE="$choice"
    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# NETWORK INFO — show current network state
#──────────────────────────────────────────────────────────────────────────────
show_network_info() {
    local serial="$1"
    local tmpfile="/tmp/wd_netinfo_$$.txt"

    {
        echo "Network Information"
        echo "Serial  : $serial"
        echo "Date    : $(date)"
        echo ""
        echo "=== Interfaces ==="
        ip addr show 2>&1
        echo ""
        echo "=== Routes ==="
        ip route show 2>&1
        echo ""
        echo "=== ARP Table ==="
        arp -n 2>&1
        echo ""
        echo "=== DNS ==="
        cat /etc/resolv.conf 2>&1
    } > "$tmpfile"

    cp "$tmpfile" "$LOG_DIR/${SESSION_START}_${serial}_netinfo.txt" 2>/dev/null || true

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "Network Information" \
           --textbox "$tmpfile" \
           22 78
    rm -f "$tmpfile"
}

#──────────────────────────────────────────────────────────────────────────────
# NMAP SCAN
#──────────────────────────────────────────────────────────────────────────────
run_nmap() {
    local serial="$1"
    local report_file="$LOG_DIR/${SESSION_START}_${serial}_nmap.txt"

    if ! command -v nmap &>/dev/null; then
        msg_box "Missing Tool" "nmap not installed.\napt install nmap"
        return 1
    fi

    # Scan type selection
    local scan_type
    scan_type=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                       --title "nmap — Scan Type" \
                       --menu "Select scan type:" \
                       16 65 7 \
                       "1" "Quick scan — top 100 ports (fast)" \
                       "2" "Full TCP scan — all 65535 ports" \
                       "3" "Service/version detection" \
                       "4" "OS detection (requires root)" \
                       "5" "Comprehensive (OS + service + scripts)" \
                       "6" "ARP host discovery only" \
                       "7" "Custom target / flags" \
                       3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && return 1

    # Target selection
    local target
    local subnet
    subnet=$(detect_local_subnet)

    target=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "nmap — Target" \
                    --inputbox \
"Enter scan target:
  Single host  : 192.168.1.1
  Subnet       : 192.168.1.0/24
  Range        : 192.168.1.1-254

Detected subnet: ${subnet:-none}" \
                    12 60 "${subnet:-}" \
                    3>&1 1>&2 2>&3)
    [[ $? -ne 0 || -z "$target" ]] && return 1

    local nmap_flags=()
    case "$scan_type" in
        1) nmap_flags=("-F" "--open") ;;
        2) nmap_flags=("-p-" "--open") ;;
        3) nmap_flags=("-sV" "-sC" "--open") ;;
        4) nmap_flags=("-O" "--open") ;;
        5) nmap_flags=("-A" "-T4" "--open") ;;
        6) nmap_flags=("-sn" "-PR") ;;
        7)
            local custom_flags
            custom_flags=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                                  --title "Custom nmap Flags" \
                                  --inputbox "Enter nmap flags (target will be appended):" \
                                  8 60 \
                                  3>&1 1>&2 2>&3)
            [[ $? -ne 0 ]] && return 1
            read -ra nmap_flags <<< "$custom_flags"
            ;;
    esac

    audit_log "INFO" "nmap scan: $target flags=${nmap_flags[*]}"

    clear
    echo -e "${CYAN}Running nmap: ${nmap_flags[*]} $target${NC}"
    echo ""

    {
        echo "nmap Scan Report"
        echo "Target  : $target"
        echo "Flags   : ${nmap_flags[*]}"
        echo "Date    : $(date)"
        echo ""
        nmap "${nmap_flags[@]}" "$target" 2>&1
        echo ""
        echo "Scan completed: $(date)"
    } | tee "$report_file"

    audit_log "INFO" "nmap complete: $report_file"

    read -r -p "Press Enter to continue..."

    dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
           --title "nmap Results — $target" \
           --textbox "$report_file" \
           22 78
}

#──────────────────────────────────────────────────────────────────────────────
# TSHARK PACKET CAPTURE
#──────────────────────────────────────────────────────────────────────────────
run_tshark() {
    local serial="$1"

    if ! command -v tshark &>/dev/null; then
        msg_box "Missing Tool" "tshark not installed.\napt install tshark"
        return 1
    fi

    if ! select_interface; then return 1; fi
    local iface="$REPLY_IFACE"

    # Capture options
    local duration
    duration=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                      --title "tshark — Capture Duration" \
                      --inputbox "Capture duration in seconds (0 = until stopped):" \
                      8 50 "60" \
                      3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && return 1

    local filter
    filter=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                    --title "tshark — Display Filter (optional)" \
                    --inputbox \
"Enter BPF capture filter (blank = capture all):
  Examples:
    not arp
    tcp port 80 or tcp port 443
    host 192.168.1.1" \
                    12 60 \
                    3>&1 1>&2 2>&3)

    local pcap_file="$LOG_DIR/${SESSION_START}_${serial}_capture.pcap"
    local txt_file="$LOG_DIR/${SESSION_START}_${serial}_capture.txt"

    local tshark_args=("-i" "$iface" "-w" "$pcap_file")
    [[ -n "$filter" ]] && tshark_args+=("-f" "$filter")
    [[ "$duration" -gt 0 ]] && tshark_args+=("-a" "duration:$duration")

    audit_log "INFO" "tshark capture start: iface=$iface duration=${duration}s filter=$filter"

    clear
    echo -e "${CYAN}Capturing on $iface...${NC}"
    [[ "$duration" -gt 0 ]] && echo -e "${DIM}Duration: ${duration}s${NC}"
    echo -e "${DIM}Press Ctrl+C to stop early${NC}"
    echo ""

    tshark "${tshark_args[@]}" 2>&1

    # Export readable summary
    if [[ -f "$pcap_file" ]]; then
        tshark -r "$pcap_file" -q -z "conv,tcp" > "$txt_file" 2>/dev/null || true
        audit_log "INFO" "tshark capture complete: $pcap_file"

        msg_box "Capture Complete" \
"Packet capture saved.

  PCAP : $(basename "$pcap_file")
  TXT  : $(basename "$txt_file")

Open PCAP in Wireshark for full analysis."
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# NETWORK MODULE MENU
#──────────────────────────────────────────────────────────────────────────────
network_menu() {
    local serial="$1"

    while true; do
        local choice
        choice=$(dialog --backtitle "WipeDeploy v${WIPEDEPLOY_VERSION}" \
                        --title "Network Module" \
                        --menu \
"Serial : $serial

Select tool:" \
                        15 55 5 \
                        "1" "Show network info (IP/routes/ARP)" \
                        "2" "nmap — active scan" \
                        "3" "tshark — packet capture" \
                        "4" "Back to main menu" \
                        3>&1 1>&2 2>&3)

        [[ $? -ne 0 || "$choice" == "4" ]] && break

        case "$choice" in
            1) show_network_info "$serial" ;;
            2) run_nmap "$serial" ;;
            3) run_tshark "$serial" ;;
        esac
    done
}
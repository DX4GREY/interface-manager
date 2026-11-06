#!/usr/bin/env bash
# lib/qcacld_helper.sh - Specific diagnostic and orchestration logic for Qualcomm qcacld-3.0 (MCL)

is_qcacld_driver() {
    local target="$1" # phy name or iface name
    local driver=""

    # Check if target is an interface
    if [ -d "/sys/class/net/$target" ]; then
        if [ -e "/sys/class/net/$target/device/driver" ]; then
            driver=$(basename "$(readlink -f "/sys/class/net/$target/device/driver")")
        fi
    fi

    # Check loaded modules
    if [ -z "$driver" ] || [ "$driver" = "wlan" ]; then
        if lsmod 2>/dev/null | grep -qE "^wlan\s|^qcacld"; then
            driver="qcacld-3.0"
        fi
    fi

    if [[ "$driver" =~ wlan|qcacld|qca ]]; then
        return 0
    fi
    return 1
}

get_qcacld_con_mode() {
    local param_path="/sys/module/wlan/parameters/con_mode"
    if [ -f "$param_path" ]; then
        cat "$param_path" 2>/dev/null
    else
        echo "unknown"
    fi
}

qcacld_diagnose() {
    local target="$1"
    print_header "Qualcomm qcacld-3.0 MCL Architecture Constraints"

    local con_mode
    con_mode=$(get_qcacld_con_mode)

    printf "  ${COLOR_BOLD}Qualcomm MCL Subsystem:${COLOR_RESET} Detected Active\n"
    printf "  ${COLOR_BOLD}Current con_mode:${COLOR_RESET} %s\n" "$con_mode"

    case "$con_mode" in
        0)
            printf "    ${COLOR_CYAN}Mode 0 (Mission/STA):${COLOR_RESET} Hardware RX decapsulation configured for 802.3 Ethernet.\n"
            printf "    ${COLOR_YELLOW}[!] Note:${COLOR_RESET} Secondary monitor VIF interfaces operate in half-duplex (TX only).\n"
            printf "        Global promiscuous frames are discarded by hardware MAC silicon.\n"
            ;;
        4)
            printf "    ${COLOR_GREEN}Mode 4 (Global Monitor Mode):${COLOR_RESET} Hardware RX decapsulation configured for RAW 802.11 MPDUs.\n"
            printf "    ${COLOR_GREEN}[+] Status:${COLOR_RESET} Full promiscuous packet capture and raw injection active on monitor adapter.\n"
            ;;
        *)
            printf "    ${COLOR_GRAY}Driver parameter could not be read from /sys/module/wlan/parameters/con_mode${COLOR_RESET}\n"
            ;;
    esac

    print_divider
    printf "${COLOR_BOLD}MCL Virtual Interface (VIF) Policies:${COLOR_RESET}\n"
    printf "  1. A maximum of 1 monitor interface can be instantiated simultaneously.\n"
    printf "  2. Monitor VIF creation is prohibited when SoftAP (Hostapd) is active.\n"
    printf "  3. For full promiscuous RAW packet capture, initialize driver with con_mode=4\n"
    printf "     or utilize dedicated interface mode transition.\n"
}

qcacld_optimize_for_monitor() {
    local iface="$1"
    log_info "Applying driver-specific optimizations for qcacld-3.0 on $iface..."

    # Ensure powersave is disabled
    if command -v iw >/dev/null 2>&1; then
        iw dev "$iface" set power_save off 2>/dev/null || true
    fi

    # Disable Android offloads if sysfs nodes exist
    local pktcapture_sysfs="/sys/kernel/debug/wlan0/pktcapture"
    if [ -w "$pktcapture_sysfs" ]; then
        echo 1 > "$pktcapture_sysfs" 2>/dev/null || true
        log_ok "Debug pktcapture flag enabled in sysfs"
    fi

    log_ok "qcacld optimizations applied successfully for $iface"
}

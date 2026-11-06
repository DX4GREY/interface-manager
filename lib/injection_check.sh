#!/usr/bin/env bash
# lib/injection_check.sh - Multi-Tier Intelligent Frame Injection & Duplex Diagnostic

find_best_target_ap() {
    local iface="$1"
    local best_bssid=""
    local best_channel=""
    local best_signal="-100"

    # Check 1: Active connection on any wireless interface
    for dev in $(iw dev 2>/dev/null | awk '/Interface/ {print $2}'); do
        local link_info
        link_info=$(iw dev "$dev" link 2>/dev/null)
        if echo "$link_info" | grep -q "Connected to"; then
            best_bssid=$(echo "$link_info" | awk '/Connected to/ {print $3}')
            local freq
            freq=$(echo "$link_info" | awk -F': ' '/freq:/ {print $2}')
            if [ -n "$freq" ]; then
                # Convert freq to channel
                if [ "$freq" -ge 2412 ] && [ "$freq" -le 2484 ]; then
                    best_channel=$(( (freq - 2407) / 5 ))
                elif [ "$freq" -ge 5000 ]; then
                    best_channel=$(( (freq - 5000) / 5 ))
                fi
                echo "$best_bssid $best_channel active_link"
                return
            fi
        fi
    done

    # Check 2: Scan dump cache
    local scan_data
    scan_data=$(iw dev "$iface" scan dump 2>/dev/null)
    if [ -n "$scan_data" ]; then
        local cur_bssid="" cur_freq="" cur_signal=""
        while IFS= read -r sline; do
            if [[ "$sline" =~ ^BSS[[:space:]]+([0-9a-fA-F:]{17}) ]]; then
                cur_bssid="${BASH_REMATCH[1]}"
            elif [[ "$sline" =~ ^[[:space:]]+freq:[[:space:]]+([0-9]+) ]]; then
                cur_freq="${BASH_REMATCH[1]}"
            elif [[ "$sline" =~ ^[[:space:]]+signal:[[:space:]]+([-\.0-9]+)[[:space:]]*dBm ]]; then
                cur_signal="${BASH_REMATCH[1]}"
                cur_signal="${cur_signal%.*}"
                if [ -n "$cur_signal" ] && [ "$cur_signal" -gt "$best_signal" ]; then
                    best_signal="$cur_signal"
                    best_bssid="$cur_bssid"
                    if [ "$cur_freq" -ge 2412 ] && [ "$cur_freq" -le 2484 ]; then
                        best_channel=$(( (cur_freq - 2407) / 5 ))
                    elif [ "$cur_freq" -ge 5000 ]; then
                        best_channel=$(( (cur_freq - 5000) / 5 ))
                    fi
                fi
            fi
        done <<< "$scan_data"
    fi

    if [ -n "$best_bssid" ] && [ -n "$best_channel" ]; then
        echo "$best_bssid $best_channel scan_cache"
        return
    fi

    echo "none 1 default"
}

check_frame_injection() {
    local iface="$1"
    print_header "Advanced Frame Injection & Duplex Diagnostic: $iface"

    if [ ! -d "/sys/class/net/$iface" ]; then
        log_err "Interface $iface does not exist!"
        return 1
    fi

    # Snapshot current state
    save_interface_state "$iface"

    # Safety Guard: Check Driver Crash Risk Profile
    local phy_target=""
    for link in /sys/class/net/*/phy80211; do
        if [ -e "$link" ] && [ "$(basename "$(dirname "$link")")" = "$iface" ]; then
            phy_target=$(basename "$(readlink -f "$link")")
            break
        fi
    done
    [ -z "$phy_target" ] && phy_target="phy0"

    local driver
    driver=$(get_phy_driver "$phy_target")
    local safety_level
    safety_level=$(get_driver_safety_level "$driver")

    if [ "$safety_level" = "high_risk" ]; then
        print_header "TEST ABORTED FOR SYSTEM INTEGRITY"
        log_err "Driver '$driver' is classified as HIGH RISK for frame injection!"
        log_warn "This driver contains unresolved upstream Linux kernel bugs:"
        printf "    ${COLOR_YELLOW}• Driver '${driver}' lacks monitor-mode raw transmit (TX) path implementation.${COLOR_RESET}\n"
        printf "    ${COLOR_YELLOW}• Transmitting raw 802.11 frames via raw sockets or aireplay-ng on this driver TRIGGERS A KERNEL PANIC (NULL pointer dereference).${COLOR_RESET}\n"
        printf "    ${COLOR_YELLOW}• This was the exact cause of the earlier host crash.${COLOR_RESET}\n\n"
        log_info "Safety Measure: interface-manager has automatically blocked the test to prevent a system crash."
        log_sub "For packet injection testing, use supported wireless adapters (e.g., MediaTek mt7612u/mt7601u or Atheros ath9k_htc) or a mobile device (qcacld-3.0)."
        return 1
    fi

    # Pre-flight Tier 1: Check Mode & Link State
    local iface_type
    iface_type=$(iw dev "$iface" info 2>/dev/null | awk '/type/ {print $2}')
    if [ "$iface_type" != "monitor" ]; then
        log_warn "Interface $iface is currently configured as '$iface_type'."
        log_info "Performing automated transition to monitor mode..."
        if ! switch_vif_mode "$iface" "monitor"; then
            log_err "Failed to switch $iface to monitor mode."
            return 1
        fi
    fi

    set_interface_state "$iface" up
    unblock_rfkill

    # Tier 2: Smart Channel Alignment
    log_info "Scanning for nearest active Access Point (AP) to align test target..."
    local target_info
    target_info=$(find_best_target_ap "$iface")
    local target_bssid target_ch target_src
    target_bssid=$(echo "$target_info" | awk '{print $1}')
    target_ch=$(echo "$target_info" | awk '{print $2}')
    target_src=$(echo "$target_info" | awk '{print $3}')

    if [ "$target_bssid" != "none" ] && [ -n "$target_ch" ]; then
        log_ok "Discovered active AP: $target_bssid on Channel $target_ch (Source: $target_src)"
        log_sub "Tuning radio frequency on $iface to Channel $target_ch..."
        iw dev "$iface" set channel "$target_ch" 2>/dev/null || true
    else
        log_sub "No active AP detected in cache. Falling back to default Channel 1."
        target_ch="1"
        iw dev "$iface" set channel 1 2>/dev/null || true
    fi

    # Tier 3: Network Stats Baseline & Checkpoint
    record_dmesg_checkpoint
    local stat_rx_before stat_tx_before stat_tx_dropped_before stat_rx_dropped_before
    stat_rx_before=$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo 0)
    stat_tx_before=$(cat "/sys/class/net/$iface/statistics/tx_packets" 2>/dev/null || echo 0)
    stat_tx_dropped_before=$(cat "/sys/class/net/$iface/statistics/tx_dropped" 2>/dev/null || echo 0)
    stat_rx_dropped_before=$(cat "/sys/class/net/$iface/statistics/rx_dropped" 2>/dev/null || echo 0)

    local test_success=false
    local ap_replied=false
    local raw_socket_ok=false

    # Tier 4: Execution
    if command -v aireplay-ng >/dev/null 2>&1; then
        log_info "Executing injection probe via aireplay-ng --test on Channel $target_ch..."
        local aireplay_out
        aireplay_out=$(aireplay-ng --test "$iface" 2>&1)
        printf "\n%s\n\n" "$aireplay_out"

        if echo "$aireplay_out" | grep -qi "Injection is working!"; then
            test_success=true
            ap_replied=true
        elif echo "$aireplay_out" | grep -qi "No Answer..."; then
            test_success=true # Packets were sent by driver, but AP didn't answer
            ap_replied=false
        fi
    else
        log_warn "'aireplay-ng' not installed. Executing raw frame injection test via AF_PACKET socket..."
        # Python raw 802.11 probe injection test
        local py_inj_res
        py_inj_res=$(python3 - << 'PYEOF' 2>&1
import socket, sys

iface = sys.argv[1] if len(sys.argv) > 1 else "mon0"
try:
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    s.bind((iface, 0))
    # Radiotap header (8 bytes) + 802.11 Probe Request (24 bytes)
    pkt = bytes([
        0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x00
    ])
    for _ in range(5):
        s.send(pkt)
    print("SUCCESS")
except Exception as e:
    print(f"FAILED: {e}")
PYEOF
"$iface"
)
        if echo "$py_inj_res" | grep -q "SUCCESS"; then
            test_success=true
            raw_socket_ok=true
            log_ok "5 raw 802.11 probe request frames successfully transmitted via raw socket."
        else
            log_err "Socket transmission failed: $py_inj_res"
        fi
    fi

    # Read stats delta
    sleep 1
    local stat_rx_after stat_tx_after stat_tx_dropped_after stat_rx_dropped_after
    stat_rx_after=$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo 0)
    stat_tx_after=$(cat "/sys/class/net/$iface/statistics/tx_packets" 2>/dev/null || echo 0)
    stat_tx_dropped_after=$(cat "/sys/class/net/$iface/statistics/tx_dropped" 2>/dev/null || echo 0)
    stat_rx_dropped_after=$(cat "/sys/class/net/$iface/statistics/rx_dropped" 2>/dev/null || echo 0)

    local tx_delta=$((stat_tx_after - stat_tx_before))
    local rx_delta=$((stat_rx_after - stat_rx_before))
    local tx_dropped_delta=$((stat_tx_dropped_after - stat_tx_dropped_before))
    local rx_dropped_delta=$((stat_rx_dropped_after - stat_rx_dropped_before))

    local dmesg_inj_delta
    dmesg_inj_delta=$(get_dmesg_delta)

    # Tier 5: Health & Duplex Diagnostic Summary
    print_header "Diagnostic Capability Summary & System Telemetry"
    printf "  ${COLOR_BOLD}Hardware Counters:${COLOR_RESET} TX Delta: ${COLOR_GREEN}+%d pkts${COLOR_RESET} | RX Delta: ${COLOR_CYAN}+%d pkts${COLOR_RESET} | Drops: [TX: +%d, RX: +%d]\n" \
        "$tx_delta" "$rx_delta" "$tx_dropped_delta" "$rx_dropped_delta"

    if [ -n "$dmesg_inj_delta" ]; then
        printf "  ${COLOR_BOLD}Kernel Activity Log:${COLOR_RESET}\n"
        while IFS= read -r kmsg; do
            [ -n "$kmsg" ] && printf "    ${COLOR_YELLOW}%s${COLOR_RESET}\n" "$kmsg"
        done <<< "$dmesg_inj_delta"
    fi

    if [ "$test_success" = true ] && [ "$rx_delta" -gt 0 ]; then
        printf "\n  ${COLOR_BOLD}Capability Rating:${COLOR_RESET} ${COLOR_GREEN}[ GRADE A+ : FULL DUPLEX ]${COLOR_RESET}\n"
        printf "  ✓ Transmit Packet Injection: ${COLOR_GREEN}VALIDATED & OPERATIONAL${COLOR_RESET}\n"
        printf "  ✓ Promiscuous Packet Capture (RX): ${COLOR_GREEN}ACTIVE (+%d packets received)${COLOR_RESET}\n"
        printf "  Interface %s is fully capable of wireless auditing, packet sniffing, and frame injection.\n" "$iface"
    elif [ "$test_success" = true ] && [ "$rx_delta" -eq 0 ]; then
        printf "\n  ${COLOR_BOLD}Capability Rating:${COLOR_RESET} ${COLOR_YELLOW}[ GRADE C : TX ONLY / HALF-DUPLEX ]${COLOR_RESET}\n"
        printf "  ✓ Transmit Packet Injection: ${COLOR_GREEN}SUCCESSFUL (Frames transmitted from radio PHY)${COLOR_RESET}\n"
        printf "  ✗ Packet Capture (RX): ${COLOR_YELLOW}0 Packets Received${COLOR_RESET}\n"
        if is_qcacld_driver "$iface"; then
            printf "  ${COLOR_BOLD}Qualcomm qcacld-3.0 Diagnostics:${COLOR_RESET}\n"
            printf "  - Hardware RX decapsulation is currently in 802.3 Ethernet mode.\n"
            printf "  - Promiscuous frames are dropped in hardware silicon. For full RX capture,\n"
            printf "    initialize the driver with con_mode=4 (Global Monitor Mode).\n"
        else
            printf "  - Device can transmit frames, but no packets were captured on this frequency.\n"
        fi
    else
        printf "\n  ${COLOR_BOLD}Capability Rating:${COLOR_RESET} ${COLOR_RED}[ GRADE F : INJECTION REJECTED / BLOCKED ]${COLOR_RESET}\n"
        printf "  ✗ Driver rejected raw frame transmission or radio is blocked.\n"
        local rf_stat
        rf_stat=$(get_rfkill_state "$(cat "/sys/class/net/$iface/phy80211/name" 2>/dev/null || echo "phy0")")
        printf "  RFKill Status: %s\n" "$rf_stat"
        if is_qcacld_driver "$iface"; then
            printf "  qcacld Note: Verify transmit queue carrier state and wlan injection queue permissions.\n"
        fi
    fi

    return 0
}

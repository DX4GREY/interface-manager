#!/usr/bin/env bash
# lib/diagnostics.sh - System Truth, Kernel Error Diagnostics, and Telemetry Engine

DMESG_CHECKPOINT_FILE="/tmp/ifm_dmesg_checkpoint"

record_dmesg_checkpoint() {
    if command -v dmesg >/dev/null 2>&1; then
        dmesg 2>/dev/null | tail -n 1 > "$DMESG_CHECKPOINT_FILE" 2>/dev/null || true
    fi
}

get_dmesg_delta() {
    if [ ! -f "$DMESG_CHECKPOINT_FILE" ] || ! command -v dmesg >/dev/null 2>&1; then
        return
    fi

    local last_line
    last_line=$(cat "$DMESG_CHECKPOINT_FILE" 2>/dev/null)
    [ -z "$last_line" ] && return

    local delta
    delta=$(dmesg 2>/dev/null | awk -v ref="$last_line" '
        found {print}
        $0 == ref {found=1}
    ')
    rm -f "$DMESG_CHECKPOINT_FILE" 2>/dev/null
    printf "%s" "$delta"
}

explain_system_error() {
    local cmd="$1"
    local exit_code="$2"
    local raw_output="$3"
    local iface="$4"
    local context="$5"

    local dmesg_delta
    dmesg_delta=$(get_dmesg_delta)

    printf "\n"
    print_header "System Error & Diagnostic Telemetry"
    printf "  ${COLOR_BOLD}Command Executed:${COLOR_RESET}  %s\n" "$cmd"
    printf "  ${COLOR_BOLD}Kernel Exit Code:${COLOR_RESET}  %s\n" "$exit_code"
    printf "  ${COLOR_BOLD}Raw Subsystem Msg:${COLOR_RESET} %s\n" "${raw_output:-None reported by user-space}"

    if [ -n "$dmesg_delta" ]; then
        printf "  ${COLOR_BOLD}Kernel Ring Buffer (dmesg):${COLOR_RESET}\n"
        while IFS= read -r kline; do
            [ -n "$kline" ] && printf "    ${COLOR_YELLOW}%s${COLOR_RESET}\n" "$kline"
        done <<< "$dmesg_delta"
    fi

    print_divider
    printf "${COLOR_BOLD}Root Cause Analysis & System Truth:${COLOR_RESET}\n"

    # Analyze specific error signatures
    if [[ "$raw_output" =~ \(-16\)|Device[[:space:]]or[[:space:]]resource[[:space:]]busy ]]; then
        printf "  ${COLOR_RED}Identified Error:${COLOR_RESET} -EBUSY (Error Code 16 : Device or Resource Busy)\n"
        
        # Check if interface is currently associated
        if [ -n "$iface" ] && [ -d "/sys/class/net/$iface" ]; then
            local link_stat
            link_stat=$(iw dev "$iface" link 2>/dev/null)
            if echo "$link_stat" | grep -q "Connected to"; then
                local bssid freq
                bssid=$(echo "$link_stat" | awk '/Connected to/ {print $3}')
                freq=$(echo "$link_stat" | awk -F': ' '/freq:/ {print $2}')
                printf "  ${COLOR_BOLD}Root Cause:${COLOR_RESET}       Interface '$iface' is actively associated with BSSID $bssid on $freq MHz.\n"
                printf "  ${COLOR_BOLD}Subsystem Truth:${COLOR_RESET}  The kernel nl80211 subsystem enforces hardware channel locking while\n"
                printf "                    an IEEE 802.11 association is active. The mac80211 stack rejects mode or\n"
                printf "                    frequency modifications to prevent ungraceful session drops and hardware desync.\n"
                printf "  ${COLOR_BOLD}Remediation:${COLOR_RESET}      1. Disconnect the active Wi-Fi session, or\n"
                printf "                    2. Bring the interface down ('ip link set dev $iface down') before mode change, or\n"
                printf "                    3. Use dedicated monitor mode transition via interface-manager option 4.\n"
                return
            fi

            # Check if NetworkManager holds a lock
            local nm_con
            nm_con=$(get_interfering_processes "$iface")
            if [ -n "$nm_con" ]; then
                printf "  ${COLOR_BOLD}Root Cause:${COLOR_RESET}       Active network daemon conflict detected:\n"
                while IFS= read -r p; do
                    printf "                    • %s\n" "$p"
                done <<< "$nm_con"
                printf "  ${COLOR_BOLD}Subsystem Truth:${COLOR_RESET}  NetworkManager or wpa_supplicant regularly transmits periodic probe requests\n"
                printf "                    and scans, temporarily locking the netlink socket.\n"
                printf "  ${COLOR_BOLD}Remediation:${COLOR_RESET}      Use automated non-destructive process isolation ('nmcli device set $iface managed no').\n"
                return
            fi
        fi

        printf "  ${COLOR_BOLD}Root Cause:${COLOR_RESET}       The underlying physical radio is currently locked by another concurrent process\n"
        printf "                    or an active virtual interface on the same PHY.\n"
        printf "  ${COLOR_BOLD}Remediation:${COLOR_RESET}      Review active VIFs on this PHY using '--list-vifs' and ensure no other operations are pending.\n"

    elif [[ "$raw_output" =~ \(-22\)|Invalid[[:space:]]argument ]]; then
        printf "  ${COLOR_RED}Identified Error:${COLOR_RESET} -EINVAL (Error Code 22 : Invalid Argument)\n"
        printf "  ${COLOR_BOLD}Root Cause:${COLOR_RESET}       The driver or netlink subsystem rejected the supplied parameters.\n"
        printf "  ${COLOR_BOLD}Subsystem Truth:${COLOR_RESET}  Common causes under wireless kernel subsystems:\n"
        printf "                    1. Requested channel/frequency is disallowed by local regulatory domain (DFS / country rules).\n"
        printf "                    2. Channel width (e.g., HT40+ or 80MHz) extends beyond permitted band boundaries.\n"
        printf "                    3. Under qcacld-3.0, the monitor vdev completion event was not properly initialized.\n"
        printf "  ${COLOR_BOLD}Remediation:${COLOR_RESET}      Verify supported frequencies with '--info' or Channel Manager option 1, and ensure valid channel widths.\n"

    elif [[ "$raw_output" =~ \(-95\)|Operation[[:space:]]not[[:space:]]supported ]]; then
        printf "  ${COLOR_RED}Identified Error:${COLOR_RESET} -EOPNOTSUPP (Error Code 95 : Operation Not Supported)\n"
        printf "  ${COLOR_BOLD}Root Cause:${COLOR_RESET}       Hardware driver lacks the requested capability in its kernel implementation.\n"
        printf "  ${COLOR_BOLD}Subsystem Truth:${COLOR_RESET}  The kernel mac80211 or vendor driver does not provide the corresponding callback\n"
        printf "                    in its 'struct cfg80211_ops' or 'struct net_device_ops'.\n"
        printf "  ${COLOR_BOLD}Remediation:${COLOR_RESET}      This is a hardware/driver architectural limitation. The requested mode or\n"
        printf "                    action cannot be executed on this specific chipset.\n"

    elif [[ "$raw_output" =~ \(-19\)|No[[:space:]]such[[:space:]]device ]]; then
        printf "  ${COLOR_RED}Identified Error:${COLOR_RESET} -ENODEV (Error Code 19 : No Such Device)\n"
        printf "  ${COLOR_BOLD}Root Cause:${COLOR_RESET}       The specified network interface does not exist in the current network namespace.\n"
        printf "  ${COLOR_BOLD}Subsystem Truth:${COLOR_RESET}  The interface may have been renamed by udev, destroyed during Subsystem Restart (SSR),\n"
        printf "                    or uninstantiated during driver reinitialization.\n"
        printf "  ${COLOR_BOLD}Remediation:${COLOR_RESET}      Inspect detected interfaces using '--list-vifs' to identify current system identifiers.\n"

    elif [[ "$raw_output" =~ \(-1\)|Operation[[:space:]]not[[:space:]]permitted ]]; then
        printf "  ${COLOR_RED}Identified Error:${COLOR_RESET} -EPERM (Error Code 1 : Operation Not Permitted)\n"
        printf "  ${COLOR_BOLD}Root Cause:${COLOR_RESET}       Permission boundary or hardware kill-switch constraint.\n"
        printf "  ${COLOR_BOLD}Subsystem Truth:${COLOR_RESET}  The operation was rejected either due to missing Linux capabilities (CAP_NET_ADMIN)\n"
        printf "                    or an active RFKill soft/hard block on the wireless physical layer.\n"
        printf "  ${COLOR_BOLD}Remediation:${COLOR_RESET}      Verify administrative root execution and execute 'rfkill unblock wifi'.\n"

    else
        printf "  ${COLOR_RED}Identified Error:${COLOR_RESET} Generic Subsystem Failure (Exit Code: $exit_code)\n"
        printf "  ${COLOR_BOLD}Root Cause:${COLOR_RESET}       Command execution rejected by kernel or helper utility.\n"
        printf "  ${COLOR_BOLD}Subsystem Truth:${COLOR_RESET}  Please review the raw error output and kernel ring buffer delta above.\n"
    fi
    printf "\n"
}

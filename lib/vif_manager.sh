#!/usr/bin/env bash
# lib/vif_manager.sh - Advanced Virtual Interface (VIF) and Concurrency Orchestration

list_phy_vifs() {
    local phy="$1"
    
    printf "%-12s %-10s %-18s %-8s %-16s %-10s\n" "INTERFACE" "TYPE" "MAC ADDRESS" "STATE" "CHANNEL/FREQ" "MANAGER"
    print_divider

    local current_phy=""
    local iface=""
    local type=""
    local addr=""
    local channel="-"
    local state="DOWN"
    local manager="unmanaged"

    # Search all sysfs interfaces matching phy
    local iface_list=()
    for link in /sys/class/net/*/phy80211; do
        if [ -e "$link" ]; then
            local p_target
            p_target=$(basename "$(readlink -f "$link")")
            if [ "$p_target" = "$phy" ]; then
                iface_list+=("$(basename "$(dirname "$link")")")
            fi
        fi
    done

    # Fallback to iw dev
    if [ ${#iface_list[@]} -eq 0 ]; then
        while IFS= read -r dev_line; do
            if [[ "$dev_line" =~ ^phy#([0-9]+) ]]; then
                current_phy="phy${BASH_REMATCH[1]}"
            elif [ "$current_phy" = "$phy" ] && [[ "$dev_line" =~ ^[[:space:]]+Interface[[:space:]]+([a-zA-Z0-9_\-]+) ]]; then
                iface_list+=("${BASH_REMATCH[1]}")
            fi
        done < <(iw dev 2>/dev/null)
    fi

    # Deduplicate
    local unique_ifaces=($(printf "%s\n" "${iface_list[@]}" | sort -u))

    for iface in "${unique_ifaces[@]}"; do
        [ -z "$iface" ] && continue
        type=$(iw dev "$iface" info 2>/dev/null | awk '/type/ {print $2}')
        [ -z "$type" ] && type="unknown"
        addr=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
        state="DOWN"
        [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" = "up" ] && state="UP"

        local ch_num freq_mhz
        ch_num=$(iw dev "$iface" info 2>/dev/null | awk '/channel/ {print $2}')
        freq_mhz=$(iw dev "$iface" info 2>/dev/null | awk '/channel/ {match($0, /\([0-9]+ MHz\)/); if (RSTART>0) print substr($0, RSTART+1, RLENGTH-5)}')
        if [ -n "$ch_num" ]; then
            channel="ch ${ch_num} (${freq_mhz}M)"
        else
            channel="-"
        fi

        # Detect Manager
        manager="none"
        if command -v nmcli >/dev/null 2>&1 && pgrep -x "NetworkManager" >/dev/null 2>&1; then
            local nm_stat
            nm_stat=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | grep -E "^${iface}:" | cut -d':' -f2)
            [ -n "$nm_stat" ] && manager="NM ($nm_stat)"
        elif pgrep -a "wpa_supplicant" 2>/dev/null | grep -q "$iface"; then
            manager="wpa_supp"
        fi

        printf "%-12s %-10s %-18s %-8s %-16s %-10s\n" "$iface" "$type" "$addr" "$state" "$channel" "$manager"
    done
}

analyze_vif_combinations() {
    local phy="$1"
    print_header "Valid Interface Combinations Analysis: $phy"

    local raw_comb
    raw_comb=$(iw phy "$phy" info 2>/dev/null | awk '
        /valid interface combinations:/ {flag=1; next}
        flag {
            if ($0 ~ /^\t\t/ || $0 ~ /^[ ]{8}/) {
                print
            } else {
                flag=0
            }
        }
    ')

    if [ -z "$raw_comb" ]; then
        log_warn "Driver on $phy does not publish a 'valid interface combinations' table."
        log_sub "Hardware may utilize monolithic legacy constraints or Qualcomm MCL rules."
        if is_qcacld_driver "$phy"; then
            log_info "qcacld-3.0 Rule: Maximum 1 STA + 1 Monitor, or 1 standalone SAP."
        fi
        return
    fi

    printf "${COLOR_BOLD}Kernel Combination Matrix:${COLOR_RESET}\n"
    while IFS= read -r c; do
        printf "  ${COLOR_CYAN}%s${COLOR_RESET}\n" "$c"
    done <<< "$raw_comb"

    print_divider
    printf "${COLOR_BOLD}Concurrency Evaluation:${COLOR_RESET}\n"

    # Check if monitor can be run concurrently
    if echo "$raw_comb" | grep -qi "monitor"; then
        log_ok "Monitor mode is declared supported in concurrent VIF combinations."
    else
        log_warn "Monitor mode is NOT declared in concurrent VIF combination rules."
        log_sub "Monitor VIF typically operates in dedicated mode or requires other VIFs to be disabled."
    fi

    # Check AP + STA
    if echo "$raw_comb" | grep -qi "AP" && echo "$raw_comb" | grep -qi "managed"; then
        log_ok "Station (managed) + Access Point (AP) concurrency is supported."
    fi

    # Channel limits
    local max_ch
    max_ch=$(echo "$raw_comb" | grep -oE "#channels\s*<=\s*[0-9]+" | head -n 1 | awk '{print $NF}')
    if [ -n "$max_ch" ]; then
        printf "  ${COLOR_BOLD}Maximum simultaneous radio channels:${COLOR_RESET} %s\n" "$max_ch"
    fi
}

add_vif() {
    local phy="$1"
    local name="$2"
    local type="$3" # monitor, managed, etc.

    [ -z "$name" ] && name="mon0"
    [ -z "$type" ] && type="monitor"

    log_info "Instantiating new virtual interface: $name (type: $type) on $phy..."

    if [ -d "/sys/class/net/$name" ]; then
        log_err "Interface $name already exists in the system!"
        return 1
    fi

    local driver
    driver=$(get_phy_driver "$phy")
    local safety_level
    safety_level=$(get_driver_safety_level "$driver")

    # Hard Safety Guard 1: High-risk driver prevention
    if [ "$type" = "monitor" ]; then
        if [ "$safety_level" = "high_risk" ]; then
            log_err "Driver '$driver' DOES NOT support concurrent monitor VIF addition!"
            log_warn "Adding a monitor VIF on driver $driver triggers a KERNEL PANIC in Linux (NULL pointer dereference)."
            log_info "Safe Alternative: Use dedicated interface mode switching (switch_vif_mode) on the primary interface."
            return 1
        fi

        # Safety Guard 2: Combination table check
        local raw_comb
        raw_comb=$(iw phy "$phy" info 2>/dev/null | awk '/valid interface combinations:/ {flag=1; next} flag {if ($0 ~ /^\t\t/ || $0 ~ /^[ ]{8}/) print; else flag=0}')
        if [ -n "$raw_comb" ] && ! echo "$raw_comb" | grep -qi "monitor"; then
            log_err "Combination rules on $phy do not permit concurrent monitor mode VIFs!"
            log_warn "Creating undeclared VIFs risks corrupting hardware queue descriptors."
            log_info "Use menu option 4 (Switch Interface Mode) on the primary interface."
            return 1
        fi
    fi

    # Pre-check for monitor concurrency in qcacld
    if [ "$type" = "monitor" ] && is_qcacld_driver "$phy"; then
        local existing_mon
        existing_mon=$(iw dev 2>/dev/null | awk '/type monitor/ {found=1} found && /Interface/ {print $2; exit}')
        if [ -n "$existing_mon" ]; then
            log_warn "qcacld-3.0 strictly limits to 1 monitor interface! Interface '$existing_mon' is already active."
            return 1
        fi
    fi

    # Find an existing interface on this phy to base on
    local base_iface
    for link in /sys/class/net/*/phy80211; do
        if [ -e "$link" ]; then
            local p_target
            p_target=$(basename "$(readlink -f "$link")")
            if [ "$p_target" = "$phy" ]; then
                base_iface=$(basename "$(dirname "$link")")
                break
            fi
        fi
    done

    local success=false

    # Try 1: via base interface
    if [ -n "$base_iface" ]; then
        log_sub "Attempting creation via 'iw dev $base_iface interface add $name type $type'..."
        if iw dev "$base_iface" interface add "$name" type "$type" 2>/dev/null; then
            success=true
        fi
    fi

    # Try 2: via phy directly
    if [ "$success" = false ]; then
        log_sub "Attempting creation via 'iw phy $phy interface add $name type $type'..."
        if iw phy "$phy" interface add "$name" type "$type" 2>/dev/null; then
            success=true
        fi
    fi

    if [ "$success" = true ]; then
        log_ok "Virtual interface $name created successfully!"
        
        # If monitor, isolate from NetworkManager so it stays quiet
        if [ "$type" = "monitor" ]; then
            isolate_interface_from_managers "$name"
        fi

        set_interface_state "$name" up
        if [ "$type" = "monitor" ] && is_qcacld_driver "$phy"; then
            qcacld_optimize_for_monitor "$name"
        fi
        return 0
    else
        log_err "Failed to instantiate virtual interface $name!"
        log_sub "Driver rejected VIF creation under current hardware state."
        return 1
    fi
}

del_vif() {
    local iface="$1"
    log_info "Removing virtual interface $iface..."

    if [ ! -d "/sys/class/net/$iface" ]; then
        log_err "Interface $iface does not exist!"
        return 1
    fi

    set_interface_state "$iface" down
    if iw dev "$iface" del 2>/dev/null; then
        log_ok "Virtual interface $iface removed successfully."
        return 0
    else
        log_err "Failed to delete interface $iface via nl80211."
        return 1
    fi
}

switch_vif_mode() {
    local iface="$1"
    local new_mode="$2" # monitor, managed

    log_info "Transitioning interface $iface operating mode to '$new_mode'..."

    if [ ! -d "/sys/class/net/$iface" ]; then
        log_err "Interface $iface does not exist!"
        return 1
    fi

    # Save snapshot before modifying
    save_interface_state "$iface"

    local current_mode
    current_mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/ {print $2}')
    if [ "$current_mode" = "$new_mode" ]; then
        log_ok "Interface $iface is already configured in '$new_mode' mode."
        return 0
    fi

    # Step 1: Process isolation if going to monitor
    if [ "$new_mode" = "monitor" ]; then
        isolate_interface_from_managers "$iface"
    fi

    # Step 2: Bring down link to avoid EBUSY
    set_interface_state "$iface" down
    unblock_rfkill

    # Step 3: Switch mode
    log_sub "Executing 'iw dev $iface set type $new_mode'..."
    if ! iw dev "$iface" set type "$new_mode" 2>/dev/null; then
        log_warn "Initial attempt rejected. Retrying with link-layer reset..."
        ip link set dev "$iface" down 2>/dev/null
        sleep 0.2
        if ! iw dev "$iface" set type "$new_mode" 2>/dev/null; then
            log_err "Driver rejected direct mode transition on $iface."
            if is_qcacld_driver "$iface"; then
                log_sub "qcacld-3.0 Tip: Use separate 'mon0' VIF allocation or initialize with con_mode=4."
            fi
            set_interface_state "$iface" up
            return 1
        fi
    fi

    # Step 4: Bring link up
    set_interface_state "$iface" up

    # Step 5: Post-switch driver-specific optimizations
    if [ "$new_mode" = "monitor" ]; then
        if is_qcacld_driver "$iface"; then
            qcacld_optimize_for_monitor "$iface"
        fi
    elif [ "$new_mode" = "managed" ]; then
        restore_interface_to_managers "$iface"
    fi

    # Verification
    local verified_mode
    verified_mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/ {print $2}')
    if [ "$verified_mode" = "$new_mode" ]; then
        log_ok "Mode for $iface successfully switched to '$new_mode' (Link State: UP)."
        return 0
    else
        log_err "Mode verification failed: interface reports '$verified_mode'."
        return 1
    fi
}

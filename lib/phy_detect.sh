#!/usr/bin/env bash
# lib/phy_detect.sh - Advanced Hardware & Wireless PHY Discovery

get_all_phys() {
    local phys=()

    # Source 1: iw dev
    while IFS= read -r p; do
        [ -n "$p" ] && phys+=("$p")
    done < <(iw dev 2>/dev/null | grep -oE "phy#[0-9]+" | tr -d '#' | sort -u)

    # Source 2: sysfs phy80211 symlinks
    for f in /sys/class/net/*/phy80211; do
        if [ -e "$f" ]; then
            local target
            target=$(basename "$(readlink -f "$f")")
            [[ "$target" =~ ^phy[0-9]+$ ]] && phys+=("$target")
        fi
    done

    # Source 3: /sys/class/ieee80211 (if exists)
    if [ -d "/sys/class/ieee80211" ]; then
        for d in /sys/class/ieee80211/phy*; do
            if [ -d "$d" ]; then
                phys+=("$(basename "$d")")
            fi
        done
    fi

    # Unique list
    if [ ${#phys[@]} -gt 0 ]; then
        printf "%s\n" "${phys[@]}" | sort -u
    fi
}

get_phy_driver() {
    local phy="$1"
    local driver="unknown"
    local first_iface

    # Map from sysfs directly
    for link in /sys/class/net/*/phy80211; do
        if [ -e "$link" ]; then
            local p_target
            p_target=$(basename "$(readlink -f "$link")")
            if [ "$p_target" = "$phy" ]; then
                first_iface=$(basename "$(dirname "$link")")
                break
            fi
        fi
    done

    if [ -z "$first_iface" ]; then
        first_iface=$(iw dev 2>/dev/null | awk -v p="$phy" '$0 ~ "phy#" substr(p, 4) {found=1; next} found && /Interface/ {print $2; exit} found && /phy#/ {exit}')
    fi
    
    if [ -n "$first_iface" ] && [ -d "/sys/class/net/$first_iface" ]; then
        if [ -e "/sys/class/net/$first_iface/device/driver" ]; then
            driver=$(basename "$(readlink -f "/sys/class/net/$first_iface/device/driver")")
        elif command -v ethtool >/dev/null 2>&1; then
            driver=$(ethtool -i "$first_iface" 2>/dev/null | awk -F': ' '/driver:/ {print $2}')
        fi
    fi

    # Fallback checks for Qualcomm MCL
    if [ "$driver" = "unknown" ] || [ -z "$driver" ]; then
        if is_qcacld_driver "$phy"; then
            driver="qcacld-3.0"
        fi
    fi

    echo "$driver"
}

get_driver_safety_level() {
    local driver="$1"
    case "$driver" in
        rtw89_*|rtw88_*|r8188eu|r8723au|wl)
            echo "high_risk"
            ;;
        iwlwifi)
            echo "no_injection"
            ;;
        qcacld*|wlan)
            echo "qcacld_mcl"
            ;;
        ath9k*|mt76*|carl9170|rt2800*)
            echo "full_support"
            ;;
        *)
            echo "generic"
            ;;
    esac
}

get_phy_chipset_info() {
    local phy="$1"
    local first_iface=""

    for link in /sys/class/net/*/phy80211; do
        if [ -e "$link" ]; then
            local p_target
            p_target=$(basename "$(readlink -f "$link")")
            if [ "$p_target" = "$phy" ]; then
                first_iface=$(basename "$(dirname "$link")")
                break
            fi
        fi
    done

    if [ -n "$first_iface" ] && [ -d "/sys/class/net/$first_iface/device" ]; then
        local dev_path
        dev_path=$(readlink -f "/sys/class/net/$first_iface/device")

        # Check PCI device
        if [[ "$dev_path" =~ /pci[0-9a-fA-F:]+/ ]]; then
            local pci_slot
            pci_slot=$(basename "$dev_path")
            if command -v lspci >/dev/null 2>&1; then
                local lspci_desc
                lspci_desc=$(lspci -s "$pci_slot" -nn 2>/dev/null | sed -E 's/^[0-9a-fA-F:.]+ [^:]+: //')
                if [ -n "$lspci_desc" ]; then
                    echo "PCIe: $lspci_desc"
                    return
                fi
            fi
        fi

        # Check USB device
        if [[ "$dev_path" =~ /usb[0-9]+/ ]]; then
            local id_vendor id_product
            id_vendor=$(cat "$dev_path/idVendor" 2>/dev/null || cat "$dev_path/../idVendor" 2>/dev/null)
            id_product=$(cat "$dev_path/idProduct" 2>/dev/null || cat "$dev_path/../idProduct" 2>/dev/null)
            local usb_prod
            usb_prod=$(cat "$dev_path/product" 2>/dev/null || cat "$dev_path/../product" 2>/dev/null)
            if [ -n "$id_vendor" ] && [ -n "$id_product" ]; then
                echo "USB: ${usb_prod:-Wireless Adapter} [${id_vendor}:${id_product}]"
                return
            fi
        fi

        # Check SoC / Platform (Qualcomm, Broadcom, etc.)
        if [[ "$dev_path" =~ /soc/|/platform/ ]]; then
            if is_qcacld_driver "$phy"; then
                echo "SoC: Qualcomm Integrated Wi-Fi (WCN3990/WCN3980 MCL)"
                return
            fi
            echo "SoC/Platform Integrated Radio"
            return
        fi
    fi

    if is_qcacld_driver "$phy"; then
        echo "Qualcomm WCN3990 / MCL Architecture"
        return
    fi

    echo "Standard Generic nl80211 Wireless Device"
}

get_phy_bus_info() {
    local phy="$1"
    local first_iface

    for link in /sys/class/net/*/phy80211; do
        if [ -e "$link" ]; then
            local p_target
            p_target=$(basename "$(readlink -f "$link")")
            if [ "$p_target" = "$phy" ]; then
                first_iface=$(basename "$(dirname "$link")")
                break
            fi
        fi
    done

    if [ -n "$first_iface" ] && [ -d "/sys/class/net/$first_iface/device" ]; then
        local uevent="/sys/class/net/$first_iface/device/uevent"
        if [ -f "$uevent" ]; then
            local slot
            slot=$(grep -E "^PCI_SLOT_NAME=|^DEVTYPE=" "$uevent" | head -n 1 | cut -d'=' -f2)
            [ -n "$slot" ] && { echo "$slot"; return; }
        fi
        readlink -f "/sys/class/net/$first_iface/device" | awk -F'/' '{print $(NF)}'
        return
    fi
    echo "platform/soc"
}

get_phy_supported_modes() {
    local phy="$1"
    iw phy "$phy" info 2>/dev/null | awk '
        /Supported interface modes:/ {flag=1; next}
        flag && /^\s*\* / {sub(/^\s*\* /, ""); print}
        flag && /^[^\s]/ {flag=0}
    '
}

inspect_phy_details() {
    local phy="$1"
    print_header "Hardware & Radio Capabilities: $phy"

    local driver
    driver=$(get_phy_driver "$phy")
    local bus
    bus=$(get_phy_bus_info "$phy")
    local chipset
    chipset=$(get_phy_chipset_info "$phy")
    local rfkill_stat
    rfkill_stat=$(get_rfkill_state "$phy")

    printf "  ${COLOR_BOLD}PHY Identifier:${COLOR_RESET}   %s\n" "$phy"
    printf "  ${COLOR_BOLD}Kernel Driver:${COLOR_RESET}    ${COLOR_CYAN}%s${COLOR_RESET}\n" "$driver"
    printf "  ${COLOR_BOLD}Chipset & Bus:${COLOR_RESET}    ${COLOR_YELLOW}%s${COLOR_RESET} (${COLOR_GRAY}%s${COLOR_RESET})\n" "$chipset" "$bus"

    local reg_domain
    reg_domain=$(iw reg get 2>/dev/null | awk -F': ' '/country/ {print $2}' | tr -d '\n')
    [ -z "$reg_domain" ] && reg_domain="global/unset"
    printf "  ${COLOR_BOLD}Regulatory Domain:${COLOR_RESET} %s\n" "$reg_domain"
    printf "  ${COLOR_BOLD}RFKill Hardware:${COLOR_RESET}   %s\n" "${rfkill_stat:-unblocked}"

    local safety_level
    safety_level=$(get_driver_safety_level "$driver")
    case "$safety_level" in
        high_risk)
            printf "  ${COLOR_BOLD}Safety Profile:${COLOR_RESET}   ${COLOR_RED}[ HIGH RISK: %s ]${COLOR_RESET}\n" "$driver"
            printf "    ${COLOR_YELLOW}WARNING:${COLOR_RESET} Driver has known upstream kernel vulnerabilities:\n"
            printf "    - Raw 802.11 monitor frame injection is unsupported (causes Kernel Panic / NULL dereference).\n"
            printf "    - Concurrent virtual monitor VIF addition is unstable.\n"
            printf "    - Monitor mode is ONLY safe via dedicated mode transition on the primary interface.\n"
            ;;
        no_injection)
            printf "  ${COLOR_BOLD}Safety Profile:${COLOR_RESET}   ${COLOR_YELLOW}[ INJECTION RESTRICTED: %s ]${COLOR_RESET}\n" "$driver"
            printf "    ${COLOR_GRAY}Note: Firmware restricts/drops raw packet transmission.${COLOR_RESET}\n"
            ;;
        qcacld_mcl)
            printf "  ${COLOR_BOLD}Safety Profile:${COLOR_RESET}   ${COLOR_CYAN}[ QUALCOMM MCL: %s ]${COLOR_RESET}\n" "$driver"
            ;;
        *)
            printf "  ${COLOR_BOLD}Safety Profile:${COLOR_RESET}   ${COLOR_GREEN}[ STABLE / STANDARD ]${COLOR_RESET}\n"
            ;;
    esac

    # Active Link Details if connected
    local active_iface=""
    for link in /sys/class/net/*/phy80211; do
        if [ -e "$link" ]; then
            local p_target
            p_target=$(basename "$(readlink -f "$link")")
            if [ "$p_target" = "$phy" ]; then
                active_iface=$(basename "$(dirname "$link")")
                local link_info
                link_info=$(iw dev "$active_iface" link 2>/dev/null)
                if echo "$link_info" | grep -q "Connected to"; then
                    local ssid bssid signal freq
                    bssid=$(echo "$link_info" | awk '/Connected to/ {print $3}')
                    ssid=$(echo "$link_info" | awk -F': ' '/SSID:/ {print $2}')
                    signal=$(echo "$link_info" | awk -F': ' '/signal:/ {print $2}')
                    freq=$(echo "$link_info" | awk -F': ' '/freq:/ {print $2}')
                    printf "\n  ${COLOR_BOLD}Active Connection (${active_iface}):${COLOR_RESET}\n"
                    printf "    SSID   : ${COLOR_GREEN}%s${COLOR_RESET}\n" "${ssid:-hidden}"
                    printf "    BSSID  : %s\n" "$bssid"
                    printf "    Signal : %s | Freq: %s MHz\n" "$signal" "$freq"
                fi
                break
            fi
        fi
    done

    # Interfering Process Check
    if [ -n "$active_iface" ]; then
        local conflicts
        conflicts=$(get_interfering_processes "$active_iface")
        if [ -n "$conflicts" ]; then
            printf "\n  ${COLOR_YELLOW}[!] Process Conflict Detected on ${active_iface}:${COLOR_RESET}\n"
            while IFS= read -r p; do
                printf "    - %s\n" "$p"
            done <<< "$conflicts"
            printf "    ${COLOR_GRAY}Tip: interface-manager automatically isolates interface from NetworkManager during monitor transitions.${COLOR_RESET}\n"
        fi
    fi

    printf "\n  ${COLOR_BOLD}Supported Interface Modes:${COLOR_RESET}\n"
    local modes
    modes=$(get_phy_supported_modes "$phy")
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        if [ "$m" = "monitor" ]; then
            printf "    - ${COLOR_GREEN}%s (Monitor Mode Supported)${COLOR_RESET}\n" "$m"
        else
            printf "    - %s\n" "$m"
        fi
    done <<< "$modes"

    # Band summary
    printf "\n  ${COLOR_BOLD}Frequency Bands:${COLOR_RESET}\n"
    local has_2ghz=false
    local has_5ghz=false
    local has_6ghz=false

    if iw phy "$phy" info 2>/dev/null | grep -qE "24[0-9]{2}(\.[0-9]+)?\s*MHz"; then
        has_2ghz=true
    fi
    if iw phy "$phy" info 2>/dev/null | grep -qE "5[0-9]{3}(\.[0-9]+)?\s*MHz"; then
        has_5ghz=true
    fi
    if iw phy "$phy" info 2>/dev/null | grep -qE "6[0-9]{3}(\.[0-9]+)?\s*MHz"; then
        has_6ghz=true
    fi

    printf "    2.4 GHz Band : %b\n" "$($has_2ghz && echo "${COLOR_GREEN}Supported${COLOR_RESET}" || echo "${COLOR_GRAY}Unsupported${COLOR_RESET}")"
    printf "    5.0 GHz Band : %b\n" "$($has_5ghz && echo "${COLOR_GREEN}Supported${COLOR_RESET}" || echo "${COLOR_GRAY}Unsupported${COLOR_RESET}")"
    printf "    6.0 GHz Band : %b\n" "$($has_6ghz && echo "${COLOR_GREEN}Supported${COLOR_RESET}" || echo "${COLOR_GRAY}Unsupported${COLOR_RESET}")"

    if is_qcacld_driver "$phy"; then
        printf "\n"
        qcacld_diagnose "$phy"
    fi
}

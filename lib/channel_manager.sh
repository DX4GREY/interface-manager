#!/usr/bin/env bash
# lib/channel_manager.sh - Channel, frequency, and spectral band orchestration

get_phy_channels() {
    local phy="$1"
    # Extract frequencies and convert to channel numbers
    iw phy "$phy" info 2>/dev/null | awk '
        /Frequencies:/ {band=1; next}
        band && /^\s*\* [0-9]+(\.[0-9]+)?\s*MHz/ {
            match($0, /[0-9]+(\.[0-9]+)? MHz/)
            freq = substr($0, RSTART, RLENGTH - 4)
            match($0, /\[[0-9]+\]/)
            if (RSTART > 0) {
                ch = substr($0, RSTART + 1, RLENGTH - 2)
                printf "%s:%s ", ch, freq
            }
        }
        band && /^[^\t ]/ {band=0}
    '
}

list_available_channels() {
    local phy="$1"
    print_header "Supported Channels & Frequencies: $phy"

    local ch_list
    ch_list=$(get_phy_channels "$phy")

    printf "${COLOR_BOLD}2.4 GHz Band (Channels 1 - 14):${COLOR_RESET}\n"
    local count_2g=0
    for item in $ch_list; do
        local ch="${item%%:*}"
        local freq="${item##*:}"
        if [ "$ch" -le 14 ]; then
            printf "  [Ch %2d] %s MHz  " "$ch" "$freq"
            count_2g=$((count_2g + 1))
            [ $((count_2g % 4)) -eq 0 ] && printf "\n"
        fi
    done
    printf "\n\n"

    printf "${COLOR_BOLD}5.0 GHz / U-NII Band:${COLOR_RESET}\n"
    local count_5g=0
    for item in $ch_list; do
        local ch="${item%%:*}"
        local freq="${item##*:}"
        if [ "$ch" -gt 14 ]; then
            printf "  [Ch %3d] %s MHz  " "$ch" "$freq"
            count_5g=$((count_5g + 1))
            [ $((count_5g % 4)) -eq 0 ] && printf "\n"
        fi
    done
    printf "\n"
}

set_vif_channel() {
    local iface="$1"
    local channel="$2"
    local width="${3:-HT20}" # HT20, HT40+, HT40-, 80MHz, NOHT

    if [ ! -d "/sys/class/net/$iface" ]; then
        log_err "Interface $iface does not exist!"
        return 1
    fi

    # Safety Guard: Do not force channel switch on an active connected STA interface
    local cur_mode
    cur_mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/ {print $2}')
    if [ "$cur_mode" = "managed" ]; then
        local link_info
        link_info=$(iw dev "$iface" link 2>/dev/null)
        if echo "$link_info" | grep -q "Connected to"; then
            log_err "Interface $iface is actively associated with an Access Point!"
            log_warn "Forcing a channel change on an active managed interface triggers driver/firmware desync and kernel crash."
            log_info "Please switch $iface to monitor mode or disconnect from Wi-Fi first."
            return 1
        fi
    fi

    log_info "Configuring $iface on Channel $channel ($width)..."

    record_dmesg_checkpoint
    local cmd_res
    local executed_cmd="iw dev $iface set channel $channel"
    if [ "$width" = "NOHT" ] || [ -z "$width" ]; then
        cmd_res=$(iw dev "$iface" set channel "$channel" 2>&1)
    else
        executed_cmd="iw dev $iface set channel $channel $width"
        cmd_res=$(iw dev "$iface" set channel "$channel" "$width" 2>&1)
    fi

    local err=$?
    if [ $err -eq 0 ]; then
        log_ok "$iface successfully configured on Channel $channel!"
        return 0
    else
        # Fallback check for drivers that don't support width parameter
        if iw dev "$iface" set channel "$channel" 2>/dev/null; then
            log_ok "$iface successfully set to Channel $channel (standard fallback)!"
            return 0
        fi

        log_err "Failed to tune channel on $iface."
        explain_system_error "$executed_cmd" "$err" "$cmd_res" "$iface" "channel_set"
        return 1
    fi
}

start_channel_hopper() {
    local iface="$1"
    local interval="${2:-0.5}" # seconds
    local channels=(1 6 11 2 7 12 3 8 13 4 9 5 10)

    log_info "Starting Channel Hopping loop on $iface..."
    log_info "Interval: ${interval}s | Press Ctrl+C to terminate."
    print_divider

    trap 'printf "\n"; log_ok "Channel hopping loop terminated."; return 0' INT TERM

    local idx=0
    local total=${#channels[@]}

    while true; do
        local ch="${channels[$idx]}"
        iw dev "$iface" set channel "$ch" 2>/dev/null
        printf "\r  ${COLOR_CYAN}[HOPPING]${COLOR_RESET} Current Channel: ${COLOR_BOLD}%2d${COLOR_RESET} | Device: %s    " "$ch" "$iface"
        sleep "$interval"
        idx=$(( (idx + 1) % total ))
    done
}

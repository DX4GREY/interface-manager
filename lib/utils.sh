#!/usr/bin/env bash
# lib/utils.sh - Core system utilities, process isolation, and state rollback

STATE_DIR="/tmp/interface_manager_states"
mkdir -p "$STATE_DIR" 2>/dev/null

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "Administrative root privileges (UID 0) are required to execute this command."
        log_info "Please re-run using: sudo $0 $*"
        exit 1
    fi
}

check_dependencies() {
    local missing_required=()
    local missing_optional=()

    local required_tools=("iw" "ip")
    local optional_tools=("aireplay-ng" "airodump-ng" "ethtool" "rfkill" "nmcli")

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_required+=("$tool")
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_optional+=("$tool")
        fi
    done

    if [ ${#missing_required[@]} -gt 0 ]; then
        log_err "Critical utility dependencies missing: ${missing_required[*]}"
        log_info "Please install required packages (e.g., apt install iw iproute2 / pacman -S iw iproute2)"
        exit 1
    fi

    if [ ${#missing_optional[@]} -gt 0 ]; then
        log_warn "Optional tools not found: ${missing_optional[*]}"
        log_sub "Certain frame injection tests or hardware inspection features may have reduced functionality."
    fi
}

unblock_rfkill() {
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi >/dev/null 2>&1 || true
        rfkill unblock all >/dev/null 2>&1 || true
    fi
}

get_rfkill_state() {
    local phy="$1"
    if ! command -v rfkill >/dev/null 2>&1; then
        echo "unknown"
        return
    fi
    rfkill list wifi 2>/dev/null | awk -v p="$phy" '
        $0 ~ p {found=1}
        found && /Soft blocked:/ {sb=$3}
        found && /Hard blocked:/ {hb=$3; print "soft:" sb ", hard:" hb; exit}
    '
}

set_interface_state() {
    local iface="$1"
    local state="$2" # up / down

    if [ "$state" = "up" ]; then
        ip link set dev "$iface" up 2>/dev/null
    else
        ip link set dev "$iface" down 2>/dev/null
    fi
    return $?
}

set_interface_mac() {
    local iface="$1"
    local new_mac="$2"

    log_info "Updating MAC address for $iface to $new_mac..."
    set_interface_state "$iface" down
    if ip link set dev "$iface" address "$new_mac" 2>/dev/null; then
        log_ok "Successfully updated MAC address on $iface to $new_mac"
        set_interface_state "$iface" up
        return 0
    else
        log_err "Failed to assign MAC address $new_mac to $iface"
        set_interface_state "$iface" up
        return 1
    fi
}

# --- Smart Process Isolation (Non-destructive) ---

get_interfering_processes() {
    local iface="$1"
    local procs=()

    # Check NetworkManager
    if pgrep -x "NetworkManager" >/dev/null 2>&1; then
        if command -v nmcli >/dev/null 2>&1; then
            local nm_state
            nm_state=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | grep -E "^${iface}:" | cut -d':' -f2)
            if [ -n "$nm_state" ] && [ "$nm_state" != "unmanaged" ]; then
                procs+=("NetworkManager (status: $nm_state)")
            fi
        fi
    fi

    # Check wpa_supplicant
    if pgrep -x "wpa_supplicant" >/dev/null 2>&1; then
        if pgrep -a "wpa_supplicant" | grep -q "$iface"; then
            procs+=("wpa_supplicant (PID: $(pgrep -f "wpa_supplicant.*$iface" | head -n 1))")
        fi
    fi

    # Check iwd
    if pgrep -x "iwd" >/dev/null 2>&1; then
        procs+=("iwd (PID: $(pgrep -x iwd))")
    fi

    # Check dhclient
    if pgrep -a "dhclient" 2>/dev/null | grep -q "$iface"; then
        procs+=("dhclient (PID: $(pgrep -f "dhclient.*$iface" | head -n 1))")
    fi

    if [ ${#procs[@]} -gt 0 ]; then
        printf "%s\n" "${procs[@]}"
    fi
}

isolate_interface_from_managers() {
    local iface="$1"
    log_info "Evaluating network manager process conflicts for $iface..."

    if command -v nmcli >/dev/null 2>&1 && pgrep -x "NetworkManager" >/dev/null 2>&1; then
        local nm_managed
        nm_managed=$(nmcli -t -f DEVICE,MANAGED dev 2>/dev/null | grep -E "^${iface}:" | cut -d':' -f2)
        if [ "$nm_managed" = "yes" ]; then
            log_warn "NetworkManager is actively managing $iface. Setting device to unmanaged..."
            nmcli device set "$iface" managed no 2>/dev/null || true
            log_ok "Successfully isolated $iface from NetworkManager (non-destructive)."
        fi
    fi
}

restore_interface_to_managers() {
    local iface="$1"
    if command -v nmcli >/dev/null 2>&1 && pgrep -x "NetworkManager" >/dev/null 2>&1; then
        log_info "Restoring $iface management control to NetworkManager..."
        nmcli device set "$iface" managed yes 2>/dev/null || true
        log_ok "$iface is once again managed by NetworkManager."
    fi
}

# --- State Snapshot & Rollback ---

save_interface_state() {
    local iface="$1"
    local state_file="$STATE_DIR/${iface}.state"

    local cur_mode
    cur_mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/ {print $2}')
    local cur_mac
    cur_mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
    local cur_channel
    cur_channel=$(iw dev "$iface" info 2>/dev/null | awk '/channel/ {print $2}')
    local cur_up
    cur_up=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)

    cat << EOF > "$state_file"
ORIGINAL_MODE="${cur_mode:-managed}"
ORIGINAL_MAC="${cur_mac:-}"
ORIGINAL_CHANNEL="${cur_channel:-1}"
ORIGINAL_OPERSTATE="${cur_up:-up}"
EOF
}

rollback_interface_state() {
    local iface="$1"
    local state_file="$STATE_DIR/${iface}.state"

    if [ ! -f "$state_file" ]; then
        log_warn "No prior configuration snapshot located for $iface."
        return 1
    fi

    # shellcheck source=/dev/null
    source "$state_file"

    log_info "Reverting $iface to original configuration snapshot..."
    set_interface_state "$iface" down
    if [ -n "$ORIGINAL_MAC" ]; then
        ip link set dev "$iface" address "$ORIGINAL_MAC" 2>/dev/null || true
    fi
    if [ -n "$ORIGINAL_MODE" ]; then
        iw dev "$iface" set type "$ORIGINAL_MODE" 2>/dev/null || true
    fi
    set_interface_state "$iface" "$ORIGINAL_OPERSTATE"
    restore_interface_to_managers "$iface"
    rm -f "$state_file"
    log_ok "$iface successfully restored to initial state ($ORIGINAL_MODE)."
}

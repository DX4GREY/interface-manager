#!/usr/bin/env bash
# ==============================================================================
# interface-manager.sh - PHY-Level Wireless Hardware & Virtual Interface Manager
# ==============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source modular libraries
# shellcheck source=lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"
# shellcheck source=lib/utils.sh
source "$SCRIPT_DIR/lib/utils.sh"
# shellcheck source=lib/diagnostics.sh
source "$SCRIPT_DIR/lib/diagnostics.sh"
# shellcheck source=lib/qcacld_helper.sh
source "$SCRIPT_DIR/lib/qcacld_helper.sh"
# shellcheck source=lib/phy_detect.sh
source "$SCRIPT_DIR/lib/phy_detect.sh"
# shellcheck source=lib/vif_manager.sh
source "$SCRIPT_DIR/lib/vif_manager.sh"
# shellcheck source=lib/injection_check.sh
source "$SCRIPT_DIR/lib/injection_check.sh"
# shellcheck source=lib/channel_manager.sh
source "$SCRIPT_DIR/lib/channel_manager.sh"

SELECTED_PHY=""
SELECTED_IFACE=""

cleanup() {
    printf "\n${COLOR_GRAY}Exiting interface-manager. Goodbye!${COLOR_RESET}\n"
    exit 0
}

trap cleanup INT TERM

show_help() {
    print_banner
    cat << EOF
Usage: sudo ./interface-manager.sh [OPTIONS]

Command-Line Options:
  -p, --phy <phy>              Specify target PHY device (e.g., phy0)
  -i, --iface <iface>          Specify target network interface (e.g., wlan0, mon0)
      --list-phys              Enumerate all detected wireless PHY radios
      --info                   Display hardware, driver, and chipset telemetry for PHY
      --list-vifs              List all virtual interfaces (VIFs) under selected PHY
      --check-vif              Evaluate kernel valid interface combinations
      --add-vif <name> [type]  Instantiate a new VIF (default type: monitor)
      --del-vif <name>         Remove a virtual interface
      --set-mode <name> <mode> Switch interface mode (monitor / managed)
      --set-mac <name> <mac>   Configure interface MAC address (spoofing)
      --check-injection <name> Run multi-tier frame injection and duplex diagnostic
      --rollback <name>        Revert interface to previous snapshot state
      --set-channel <name> <c> Configure interface channel (e.g., --set-channel mon0 6)
      --hop <name> [interval]  Execute channel hopping loop (default interval: 0.5s)
  -h, --help                   Display this help manual

Executing without options launches the interactive TUI menu.
EOF
}

auto_select_default_phy() {
    if [ -n "$SELECTED_PHY" ]; then
        return
    fi
    local phys=($(get_all_phys))
    if [ ${#phys[@]} -eq 0 ]; then
        log_err "No wireless PHY radios detected on this system!"
        exit 1
    fi
    SELECTED_PHY="${phys[0]}"
}

menu_select_phy() {
    print_header "Select Target Wireless PHY Radio"
    local phys=($(get_all_phys))
    if [ ${#phys[@]} -eq 0 ]; then
        log_err "No wireless PHY devices found!"
        return
    fi

    local i=1
    for p in "${phys[@]}"; do
        local drv
        drv=$(get_phy_driver "$p")
        if [ "$p" = "$SELECTED_PHY" ]; then
            printf "  ${COLOR_GREEN}%d) %s [Driver: %s] (ACTIVE)${COLOR_RESET}\n" "$i" "$p" "$drv"
        else
            printf "  %d) %s [Driver: %s]\n" "$i" "$p" "$drv"
        fi
        i=$((i + 1))
    done

    printf "\nSelect PHY index [1-%d]: " "${#phys[@]}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#phys[@]}" ]; then
        SELECTED_PHY="${phys[$((choice - 1))]}"
        log_ok "Active PHY switched to: $SELECTED_PHY"
    else
        log_warn "Invalid selection."
    fi
}

menu_vif_management() {
    while true; do
        print_header "Virtual Interface (VIF) Management: $SELECTED_PHY"
        list_phy_vifs "$SELECTED_PHY"
        printf "\n"
        printf "  ${COLOR_BOLD}1)${COLOR_RESET} Add new Monitor VIF (e.g., mon0)\n"
        printf "  ${COLOR_BOLD}2)${COLOR_RESET} Add new Managed VIF\n"
        printf "  ${COLOR_BOLD}3)${COLOR_RESET} Delete Virtual Interface\n"
        printf "  ${COLOR_BOLD}4)${COLOR_RESET} Switch Interface Operating Mode (managed <-> monitor)\n"
        printf "  ${COLOR_BOLD}5)${COLOR_RESET} Update Interface MAC Address\n"
        printf "  ${COLOR_BOLD}6)${COLOR_RESET} Set Interface State UP / DOWN\n"
        printf "  ${COLOR_BOLD}7)${COLOR_RESET} Rollback Interface to Original Snapshot State\n"
        printf "  ${COLOR_BOLD}0)${COLOR_RESET} Return to Main Menu\n"
        printf "\nSelection [0-7]: "
        read -r vchoice

        case "$vchoice" in
            1)
                printf "Enter new interface name (default: mon0): "
                read -r vname
                [ -z "$vname" ] && vname="mon0"
                add_vif "$SELECTED_PHY" "$vname" "monitor"
                ;;
            2)
                printf "Enter new interface name (e.g., wlan1): "
                read -r vname
                if [ -n "$vname" ]; then
                    add_vif "$SELECTED_PHY" "$vname" "managed"
                fi
                ;;
            3)
                printf "Enter interface name to delete: "
                read -r vname
                if [ -n "$vname" ]; then
                    del_vif "$vname"
                fi
                ;;
            4)
                printf "Enter interface name: "
                read -r vname
                printf "Select target mode (1: monitor, 2: managed): "
                read -r mchoice
                if [ "$mchoice" = "1" ]; then
                    switch_vif_mode "$vname" "monitor"
                elif [ "$mchoice" = "2" ]; then
                    switch_vif_mode "$vname" "managed"
                fi
                ;;
            5)
                printf "Enter interface name: "
                read -r vname
                printf "Enter new MAC address (e.g., 00:11:22:33:44:55): "
                read -r vmac
                if [ -n "$vname" ] && [ -n "$vmac" ]; then
                    set_interface_mac "$vname" "$vmac"
                fi
                ;;
            6)
                printf "Enter interface name: "
                read -r vname
                printf "Select state (1: UP, 2: DOWN): "
                read -r schoice
                if [ "$schoice" = "1" ]; then
                    set_interface_state "$vname" "up" && log_ok "$vname set to UP"
                elif [ "$schoice" = "2" ]; then
                    set_interface_state "$vname" "down" && log_ok "$vname set to DOWN"
                fi
                ;;
            7)
                printf "Enter interface name to rollback: "
                read -r vname
                if [ -n "$vname" ]; then
                    rollback_interface_state "$vname"
                fi
                ;;
            0)
                break
                ;;
            *)
                log_warn "Invalid selection."
                ;;
        esac
        printf "\nPress [Enter] to continue..."
        read -r
    done
}

menu_channel_management() {
    while true; do
        print_header "Channel & Frequency Manager: $SELECTED_PHY"
        printf "  ${COLOR_BOLD}1)${COLOR_RESET} View Supported Frequency Bands & Channels\n"
        printf "  ${COLOR_BOLD}2)${COLOR_RESET} Configure Operating Channel on Interface\n"
        printf "  ${COLOR_BOLD}3)${COLOR_RESET} Execute Channel Hopping Loop\n"
        printf "  ${COLOR_BOLD}0)${COLOR_RESET} Return to Main Menu\n"
        printf "\nSelection [0-3]: "
        read -r cchoice

        case "$cchoice" in
            1)
                list_available_channels "$SELECTED_PHY"
                ;;
            2)
                printf "Enter interface name: "
                read -r iface
                printf "Enter target channel number (e.g., 1, 6, 11, 36, 149): "
                read -r ch
                printf "Select channel width (1: HT20, 2: HT40+, 3: 80MHz, 4: Standard): "
                read -r wchoice
                local width="HT20"
                [ "$wchoice" = "2" ] && width="HT40+"
                [ "$wchoice" = "3" ] && width="80MHz"
                [ "$wchoice" = "4" ] && width="NOHT"
                if [ -n "$iface" ] && [ -n "$ch" ]; then
                    set_vif_channel "$iface" "$ch" "$width"
                fi
                ;;
            3)
                printf "Enter monitor interface name: "
                read -r iface
                printf "Hop interval in seconds (default: 0.5): "
                read -r hop_int
                [ -z "$hop_int" ] && hop_int="0.5"
                if [ -n "$iface" ]; then
                    start_channel_hopper "$iface" "$hop_int"
                fi
                ;;
            0)
                break
                ;;
            *)
                log_warn "Invalid selection."
                ;;
        esac
        printf "\nPress [Enter] to continue..."
        read -r
    done
}

interactive_main_menu() {
    auto_select_default_phy

    while true; do
        clear
        print_banner
        local cur_drv
        cur_drv=$(get_phy_driver "$SELECTED_PHY")

        printf "\n  ${COLOR_BOLD}Active Target:${COLOR_RESET}  ${COLOR_GREEN}%s${COLOR_RESET} [Driver: ${COLOR_CYAN}%s${COLOR_RESET}]\n" "$SELECTED_PHY" "$cur_drv"
        if is_qcacld_driver "$SELECTED_PHY"; then
            printf "  ${COLOR_YELLOW}[qcacld-3.0 MCL Detected]${COLOR_RESET} Mode con_mode: %s\n" "$(get_qcacld_con_mode)"
        fi
        print_divider

        printf "  ${COLOR_BOLD}1)${COLOR_RESET} Select Target PHY Radio\n"
        printf "  ${COLOR_BOLD}2)${COLOR_RESET} Display Hardware & Radio Telemetry (Chipset & Driver Safety)\n"
        printf "  ${COLOR_BOLD}3)${COLOR_RESET} Evaluate Valid Interface Combinations (Concurrency Matrix)\n"
        printf "  ${COLOR_BOLD}4)${COLOR_RESET} Virtual Interface Management (Add/Del/Mode/MAC/Rollback)\n"
        printf "  ${COLOR_BOLD}5)${COLOR_RESET} Execute Frame Injection & Duplex Diagnostic Test\n"
        printf "  ${COLOR_BOLD}6)${COLOR_RESET} Channel Manager (Frequencies, Tuning, Hopping Loop)\n"
        printf "  ${COLOR_BOLD}0)${COLOR_RESET} Exit\n"
        print_divider
        printf "Selection [0-6]: "
        read -r main_choice

        case "$main_choice" in
            1)
                menu_select_phy
                ;;
            2)
                inspect_phy_details "$SELECTED_PHY"
                ;;
            3)
                analyze_vif_combinations "$SELECTED_PHY"
                ;;
            4)
                menu_vif_management
                ;;
            5)
                printf "Enter interface name to test (e.g., mon0 / wlan0): "
                read -r iface
                if [ -n "$iface" ]; then
                    check_frame_injection "$iface"
                fi
                ;;
            6)
                menu_channel_management
                ;;
            0)
                cleanup
                ;;
            *)
                log_warn "Invalid selection."
                ;;
        esac
        printf "\nPress [Enter] to return to menu..."
        read -r
    done
}

# --- Entry Point & CLI Option Parsing ---
for arg in "$@"; do
    if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        show_help
        exit 0
    fi
done

check_root "$@"
check_dependencies
unblock_rfkill

if [ $# -eq 0 ]; then
    interactive_main_menu
    exit 0
fi

# Parse CLI flags
ACTION=""
ARG_VIF_NAME=""
ARG_VIF_TYPE=""
ARG_VIF_MAC=""
ARG_CHANNEL=""
ARG_WIDTH=""
ARG_INTERVAL=""

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--phy)
            SELECTED_PHY="$2"
            shift 2
            ;;
        -i|--iface)
            SELECTED_IFACE="$2"
            shift 2
            ;;
        --list-phys)
            ACTION="list_phys"
            shift
            ;;
        --info)
            ACTION="info"
            shift
            ;;
        --list-vifs)
            ACTION="list_vifs"
            shift
            ;;
        --check-vif)
            ACTION="check_vif"
            shift
            ;;
        --add-vif)
            ACTION="add_vif"
            ARG_VIF_NAME="$2"
            ARG_VIF_TYPE="${3:-monitor}"
            shift 2
            [[ "$1" =~ ^(monitor|managed|AP)$ ]] && shift
            ;;
        --del-vif)
            ACTION="del_vif"
            ARG_VIF_NAME="$2"
            shift 2
            ;;
        --set-mode)
            ACTION="set_mode"
            ARG_VIF_NAME="$2"
            ARG_VIF_TYPE="$3"
            shift 3
            ;;
        --set-mac)
            ACTION="set_mac"
            ARG_VIF_NAME="$2"
            ARG_VIF_MAC="$3"
            shift 3
            ;;
        --check-injection)
            ACTION="check_injection"
            ARG_VIF_NAME="$2"
            shift 2
            ;;
        --rollback)
            ACTION="rollback"
            ARG_VIF_NAME="$2"
            shift 2
            ;;
        --set-channel)
            ACTION="set_channel"
            ARG_VIF_NAME="$2"
            ARG_CHANNEL="$3"
            ARG_WIDTH="${4:-HT20}"
            shift 3
            [[ "$1" =~ ^(HT20|HT40\+|HT40\-|80MHz|NOHT)$ ]] && shift
            ;;
        --hop)
            ACTION="hop"
            ARG_VIF_NAME="$2"
            ARG_INTERVAL="${3:-0.5}"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_err "Unrecognized argument: $1"
            show_help
            exit 1
            ;;
    esac
done

auto_select_default_phy

case "$ACTION" in
    list_phys)
        print_header "Wireless PHY Device Catalog"
        for p in $(get_all_phys); do
            printf "  - %-8s [Driver: %s] [Bus: %s]\n" "$p" "$(get_phy_driver "$p")" "$(get_phy_bus_info "$p")"
        done
        ;;
    info)
        inspect_phy_details "$SELECTED_PHY"
        ;;
    list_vifs)
        list_phy_vifs "$SELECTED_PHY"
        ;;
    check_vif)
        analyze_vif_combinations "$SELECTED_PHY"
        ;;
    add_vif)
        add_vif "$SELECTED_PHY" "$ARG_VIF_NAME" "$ARG_VIF_TYPE"
        ;;
    del_vif)
        del_vif "$ARG_VIF_NAME"
        ;;
    set_mode)
        switch_vif_mode "$ARG_VIF_NAME" "$ARG_VIF_TYPE"
        ;;
    set_mac)
        set_interface_mac "$ARG_VIF_NAME" "$ARG_VIF_MAC"
        ;;
    check_injection)
        check_frame_injection "$ARG_VIF_NAME"
        ;;
    rollback)
        rollback_interface_state "$ARG_VIF_NAME"
        ;;
    set_channel)
        set_vif_channel "$ARG_VIF_NAME" "$ARG_CHANNEL" "$ARG_WIDTH"
        ;;
    hop)
        start_channel_hopper "$ARG_VIF_NAME" "$ARG_INTERVAL"
        ;;
    *)
        interactive_main_menu
        ;;
esac

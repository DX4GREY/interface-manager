#!/usr/bin/env bash
# lib/colors.sh - ANSI color palettes, banners, and logging utilities

if [ -t 1 ]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_DIM="\033[2m"
    COLOR_RED="\033[38;5;196m"
    COLOR_GREEN="\033[38;5;46m"
    COLOR_YELLOW="\033[38;5;220m"
    COLOR_BLUE="\033[38;5;39m"
    COLOR_MAGENTA="\033[38;5;201m"
    COLOR_CYAN="\033[38;5;51m"
    COLOR_GRAY="\033[38;5;244m"
    COLOR_WHITE="\033[38;5;255m"
    COLOR_BG_DARK="\033[48;5;236m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_DIM=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_CYAN=""
    COLOR_GRAY=""
    COLOR_WHITE=""
    COLOR_BG_DARK=""
fi

log_info() {
    printf "${COLOR_BLUE}[*]${COLOR_RESET} %s\n" "$*"
}

log_ok() {
    printf "${COLOR_GREEN}[+]${COLOR_RESET} %s\n" "$*"
}

log_warn() {
    printf "${COLOR_YELLOW}[!]${COLOR_RESET} %s\n" "$*"
}

log_err() {
    printf "${COLOR_RED}[-]${COLOR_RESET} %s\n" "$*" >&2
}

log_sub() {
    printf "    ${COLOR_GRAY}↳${COLOR_RESET} %s\n" "$*"
}

print_header() {
    local title="$1"
    printf "\n${COLOR_CYAN}${COLOR_BOLD}=== %s ===${COLOR_RESET}\n" "$title"
}

print_divider() {
    printf "${COLOR_GRAY}%s${COLOR_RESET}\n" "------------------------------------------------------------------"
}

print_banner() {
    cat << "EOF"
  ___       _             __                   __  __                                   
 |_ _|_ __ | |_ ___ _ __ / _| __ _  ___ ___   |  \/  | __ _ _ __   __ _  __ _  ___ _ __ 
  | || '_ \| __/ _ \ '__| |_ / _` |/ __/ _ \  | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
  | || | | | ||  __/ |  |  _| (_| | (_|  __/  | |  | | (_| | | | | (_| | (_| |  __/ |   
 |___|_| |_|\__\___|_|  |_|  \__,_|\___\___|  |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|   
                                                                         |___/           
       [ PHY-Level Wireless Hardware & Virtual Interface Orchestrator ]
EOF
}

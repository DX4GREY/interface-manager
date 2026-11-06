# Interface Manager

A professional CLI and TUI utility for managing Linux wireless hardware devices at the **PHY** (Physical Device) layer and **nl80211 / cfg80211** subsystems. It features automated driver risk profiling to safeguard systems against kernel panics, as well as dedicated support for Qualcomm **qcacld-3.0** (MCL) wireless architectures.

---

## Overview

Managing virtual wireless interfaces (VIFs) and monitor mode under modern Linux kernels frequently encounters driver-specific regressions, race conditions with user-space network managers (such as NetworkManager and iwd), and silent kernel panics caused by unimplemented monitor transmit functions.

`interface-manager` provides a unified, hardware-aware abstraction layer to inspect, configure, and diagnose wireless network adapters safely.

---

## Kernel Safety & Crash Prevention

The tool incorporates automated **Driver Risk Profiling** to protect the host operating system from kernel panics caused by known driver limitations:

1. **Concurrent VIF Isolation on High-Risk Drivers:**  
   Drivers such as **`rtw89_*`** (Realtek RTL8852BE/CE) and legacy **`r8188eu`** do not support creating a secondary monitor VIF (`iw dev ... interface add mon0 type monitor`) while the primary managed interface is active. Attempting to add an undeclared VIF corrupts PCIe DMA ring buffers and results in an immediate kernel panic. `interface-manager` inspects the kernel combination matrix and driver profile, blocking unsafe VIF instantiations before they reach the kernel.

2. **Prevention of Unsupported Raw Frame Injection:**  
   In upstream mainline Linux, drivers such as `rtw89` lack a transmit path for raw 802.11 monitor frames. Transmitting raw frames via `AF_PACKET` or `aireplay-ng` causes `rtw89_core_tx()` to dereference a `NULL` pointer, crashing the operating system. `interface-manager` identifies high-risk drivers and halts injection routines prior to socket transmission.

3. **Prevention of Active Station Channel Desynchronization:**  
   Forcing a channel change (`iw dev <iface> set channel <ch>`) while an interface is actively associated with an Access Point causes `mac80211` state desynchronization and driver timeouts. The tool validates association state prior to channel switching.

4. **System Truth & Telemetry Engine (Kernel Diagnostic Explanations):**  
   Whenever an nl80211 or rtnetlink command encounters an error (such as `-EBUSY`, `-EINVAL`, `-EOPNOTSUPP`), the utility automatically captures the kernel ring buffer (`dmesg`) delta and analyzes the root cause in context. Instead of generic exit codes, it explains the exact subsystem behavior and outputs actionable remediation steps.

---

## Key Features

* **Intelligent PHY & Chipset Telemetry:**
  - Auto-discovery across `iw dev`, `/sys/class/net/*/phy80211`, and `/sys/class/ieee80211/`.
  - Chipset identification via PCI subsystem matching (`lspci`), USB vendor/product IDs (`lsusb`), and Qualcomm SoC platform identifiers.
  - Conflict detection for active network managers (`NetworkManager`, `wpa_supplicant`, `iwd`, `dhclient`).
  - Active association metrics (SSID, BSSID, RSSI dBm, and operational frequency).

* **Virtual Interface (VIF) Orchestration:**
  - Dynamic VIF instantiation with combination matrix compliance checks.
  - Non-destructive NetworkManager isolation during monitor mode transitions.
  - MAC address configuration with automated link-layer state management.
  - **State Snapshot & Rollback**: Automatically records interface parameters and allows instant reversion via `--rollback <iface>`.

* **Qualcomm `qcacld-3.0` (MCL) Integration:**
  - Evaluates `/sys/module/wlan/parameters/con_mode`.
  - Explains MCL silicon constraints (single monitor session policy, 802.3 Ethernet vs. RAW 802.11 MPDU hardware decapsulation).
  - Automatically disables power-save and tunes sysfs packet capture hooks upon monitor initialization.

* **Multi-Tier Frame Injection & Duplex Diagnostic:**
  - Automatically scans for the nearest active Access Point to align channel tuning.
  - Duplex capability evaluation:
    - **Grade A+ (Full Duplex)**: Validated frame transmission and active promiscuous packet reception.
    - **Grade C (TX Only / Half-Duplex)**: Injected frames transmit over the air, but RX is dropped (characteristic of Qualcomm MCL in Mission Mode).
    - **Grade F**: Transmission rejected by driver or blocked by rfkill.

* **Channel & Spectral Band Manager:**
  - Enumerates supported channels across 2.4 GHz, 5.0 GHz, and 6.0 GHz bands.
  - Configures channel width (`HT20`, `HT40+`, `HT40-`, `80MHz`, `NOHT`).
  - Automated channel hopping loop with customizable dwell intervals.

---

## Directory Structure

```
~/MyProject/interface-manager/
├── interface-manager.sh      # Main entry point (TUI menu and CLI option parser)
├── lib/
│   ├── colors.sh             # ANSI terminal formatting, palettes, and banner
│   ├── utils.sh              # Privilege validation, process isolation, and rollback
│   ├── phy_detect.sh         # PHY discovery, chipset detection, and safety profiling
│   ├── vif_manager.sh        # Combination matrix parser and VIF lifecycle management
│   ├── injection_check.sh    # Multi-tier frame injection and duplex diagnostic suite
│   ├── channel_manager.sh    # Channel tuning, bandwidth control, and hopping loops
│   └── qcacld_helper.sh      # Qualcomm qcacld-3.0 MCL logic and telemetry
└── README.md                 # Technical documentation
```

---

## Usage Guide

### 1. Interactive TUI Menu

Execute with administrative privileges without parameters:

```bash
cd ~/MyProject/interface-manager
sudo ./interface-manager.sh
```

The menu provides numbered options to select wireless PHYs, review hardware safety profiles, manage virtual interfaces, run diagnostics, and manage channels.

### 2. Command-Line Interface (Automation / Scripting)

The utility supports direct non-interactive CLI flags:

```bash
# Enumerate all detected wireless PHY radios
sudo ./interface-manager.sh --list-phys

# Inspect hardware capabilities and driver safety profile for phy0
sudo ./interface-manager.sh -p phy0 --info

# Evaluate kernel valid interface combinations
sudo ./interface-manager.sh -p phy0 --check-vif

# List all active virtual interfaces under phy0
sudo ./interface-manager.sh -p phy0 --list-vifs

# Create a monitor interface named mon0 (with automated safety validation)
sudo ./interface-manager.sh -p phy0 --add-vif mon0 monitor

# Tune interface mon0 to Channel 6 with HT20 width
sudo ./interface-manager.sh --set-channel mon0 6 HT20

# Run multi-tier frame injection and duplex diagnostic on mon0
sudo ./interface-manager.sh --check-injection mon0

# Execute a channel hopping loop with 0.5s dwell time
sudo ./interface-manager.sh --hop mon0 0.5

# Revert an interface to its pre-test snapshot configuration
sudo ./interface-manager.sh --rollback mon0

# Remove virtual interface mon0
sudo ./interface-manager.sh --del-vif mon0
```

#!/usr/bin/env bash
set -euo pipefail

# One-shot setup script for RoomSense Masterbox
# - Installs prerequisites
# - Installs systemd units
# - Removes saved Wi‑Fi configuration so first boot has no SSIDs
# - Reboots so the RoomSense hotspot/portal comes up

if [ "${EUID}" -ne 0 ]; then
  echo "[roomsense_full_setup_hotspot] Please run as root: sudo bash scripts/roomsense_full_setup_hotspot.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR%/scripts}"

cd "${REPO_ROOT}"

echo "[roomsense_full_setup_hotspot] Running prerequisite installer"
bash "${SCRIPT_DIR}/install_prereqs.sh"

echo "[roomsense_full_setup_hotspot] Installing systemd units"
bash "${SCRIPT_DIR}/install_systemd.sh"

# Clear saved Wi-Fi configurations so there is no previously known SSID
# Handle both NetworkManager (Bookworm default) and legacy wpa_supplicant

echo "[roomsense_full_setup_hotspot] Clearing saved Wi-Fi connections"

if command -v nmcli >/dev/null 2>&1; then
  echo "[roomsense_full_setup_hotspot] Detected NetworkManager; deleting Wi-Fi connections via nmcli"
  # Delete all wifi-type connections
  while IFS= read -r CONN; do
    [ -z "$CONN" ] && continue
    echo "  - Deleting connection: $CONN"
    nmcli connection delete "$CONN" || true
  done < <(nmcli -t -f NAME,TYPE connection show | awk -F: '$2 == "wifi" {print $1}')

  # Also remove any system-connections files that might remain
  if [ -d /etc/NetworkManager/system-connections ]; then
    echo "[roomsense_full_setup_hotspot] Removing /etc/NetworkManager/system-connections/*"
    rm -f /etc/NetworkManager/system-connections/* || true
  fi
else
  echo "[roomsense_full_setup_hotspot] NetworkManager not detected; cleaning wpa_supplicant config"
  if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    cp /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf.backup || true
    # Keep only global config lines, strip out network={} blocks
    awk 'BEGIN{in_net=0} /network=\s*\{/ {in_net=1} in_net && /\}/ {in_net=0; next} !in_net {print}' \
      /etc/wpa_supplicant/wpa_supplicant.conf > /etc/wpa_supplicant/wpa_supplicant.conf.tmp || true
    mv /etc/wpa_supplicant/wpa_supplicant.conf.tmp /etc/wpa_supplicant/wpa_supplicant.conf || true
  fi
fi

# Ensure next boot *always* goes into hotspot/portal once, regardless of internet
STATE_DIR=/opt/roomsense/state
FORCE_PORTAL_FLAG="$STATE_DIR/force_portal_once"
mkdir -p "$STATE_DIR"
touch "$FORCE_PORTAL_FLAG"

echo "[roomsense_full_setup_hotspot] Setup complete. Rebooting now so hotspot/portal can start on clean boot."
sleep 3
reboot

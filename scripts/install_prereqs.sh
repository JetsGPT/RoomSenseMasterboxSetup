#!/usr/bin/env bash
set -euo pipefail

# Install base packages and prepare directories

echo "[install_prereqs] Detecting OS and Wi-Fi stack"
OS=$(grep PRETTY_NAME /etc/os-release || true)
USES_NM=0
if command -v nmcli >/dev/null 2>&1; then
  USES_NM=1
fi

echo "[install_prereqs] Creating directories under /opt/roomsense"
sudo mkdir -p /opt/roomsense/{logs,portal,stack,backend,frontend}
sudo mkdir -p /opt/roomsense/state
sudo chown -R root:root /opt/roomsense

PKGS=(python3 python3-venv python3-pip dnsmasq git curl ca-certificates iptables)
if [ "$USES_NM" -eq 1 ]; then
  PKGS+=(network-manager)
else
  PKGS+=(hostapd iw wpasupplicant)
fi

echo "[install_prereqs] Updating apt and installing: ${PKGS[*]}"
sudo apt-get update
sudo apt-get install -y --no-install-recommends ${PKGS[*]}

# Ensure dnsmasq disabled by default, will be started by our unit with a specific config
sudo systemctl disable --now dnsmasq || true

# Allow IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
sudo sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || true

# Copy dnsmasq config template
sudo mkdir -p /etc/roomsense
sudo cp -f "$(dirname "$0")/../config/dnsmasq-portal.conf" /etc/roomsense/dnsmasq-portal.conf

# Make scripts executable
sudo find "$(dirname "$0")" -type f -name "*.sh" -exec chmod +x {} +

echo "[install_prereqs] Done"

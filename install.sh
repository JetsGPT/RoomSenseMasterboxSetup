#!/bin/bash

# RoomSense WiFi Setup Installer
# Run this as root

set -euo pipefail

if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root"
  exit 1
fi

echo "Starting RoomSense Setup installation..."

# 1. Install Dependencies
echo "Installing system dependencies..."
apt-get update
apt-get install -y python3-venv python3-pip network-manager dnsmasq nodejs npm git nginx docker.io

# Disable and stop nginx immediately so it doesn't take port 80
# The setup app (app.py) needs port 80. Nginx is only for production later.
systemctl disable nginx
systemctl stop nginx

# [FIX 1C] Configure DNS properly without destroying resolv.conf
# This preserves captive portal functionality and local DNS resolution
# We configure fallback DNS via NetworkManager instead of hardcoding resolv.conf
echo "Configuring fallback DNS via NetworkManager..."
mkdir -p /etc/NetworkManager/conf.d
cat <<EOF > /etc/NetworkManager/conf.d/dns-servers.conf
[global-dns-domain-*]
servers=8.8.8.8,1.1.1.1
EOF

# Note: We do NOT disable systemd-resolved entirely - the dns=dnsmasq setting
# in NetworkManager.conf (added below) handles DNS properly for our AP mode

# 2. Setup Directory
INSTALL_DIR="/opt/roomsense/wifi_setup"
GLOBAL_SCRIPTS_DIR="/opt/roomsense/scripts" # Renamed to avoid conflict with local var
SCRIPT_LOCATION="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

echo "Setting up directory at $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$GLOBAL_SCRIPTS_DIR"

if [ -d "$SCRIPT_LOCATION/wifi_setup" ]; then
    cp -r "$SCRIPT_LOCATION/wifi_setup/"* "$INSTALL_DIR/"
else
    echo "Error: wifi_setup directory not found at $SCRIPT_LOCATION/wifi_setup"
    exit 1
fi

# Move scripts to scripts dir
mv "$INSTALL_DIR/provision.sh" "$GLOBAL_SCRIPTS_DIR/"
mv "$INSTALL_DIR/wifi_watchdog.sh" "$GLOBAL_SCRIPTS_DIR/"
chmod +x "$GLOBAL_SCRIPTS_DIR/provision.sh"
chmod +x "$GLOBAL_SCRIPTS_DIR/wifi_watchdog.sh"

# 3. Setup Python Environment
echo "Setting up Python virtual environment..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install flask

# 4. Configure NetworkManager & Dnsmasq for Captive Portal
echo "Configuring NetworkManager..."
# Ensure NetworkManager is managing everything
if ! grep -q "dns=dnsmasq" /etc/NetworkManager/NetworkManager.conf; then
    echo "Enabling dnsmasq in NetworkManager..."
    cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.bak
    # Basic sed to append if not present (simplified for robustness)
    # Ideally should use a proper config parser, but this works for most default installs
    sed -i '/\[main\]/a dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf
fi

mkdir -p /etc/NetworkManager/dnsmasq-shared.d/
cp "$INSTALL_DIR/dnsmasq.conf" /etc/NetworkManager/dnsmasq-shared.d/roomsense.conf

# 5. Signal Factory Reset for Next Boot
echo "Signaling factory reset..."
touch "$INSTALL_DIR/.factory_reset"

# 6. Install Systemd Services
echo "Installing systemd services..."
cp "$INSTALL_DIR/roomsense-setup.service" /etc/systemd/system/
cp "$INSTALL_DIR/roomsense-provision.service" /etc/systemd/system/

# Create Watchdog Service & Timer
cat <<EOF > /etc/systemd/system/wifi-watchdog.service
[Unit]
Description=RoomSense WiFi Watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=$GLOBAL_SCRIPTS_DIR/wifi_watchdog.sh
EOF

cat <<EOF > /etc/systemd/system/wifi-watchdog.timer
[Unit]
Description=Run WiFi Watchdog periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=wifi-watchdog.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable roomsense-setup.service
# Enable watchdog timer immediately so monitoring starts after first boot
systemctl enable wifi-watchdog.timer

echo "Installation Complete!"
echo "Rebooting in 5 seconds..."
sleep 5
reboot

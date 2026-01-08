#!/bin/bash

# RoomSense WiFi Setup Installer
# Run this as root

if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root"
  exit 1
fi

echo "Starting RoomSense Setup installation..."

# 1. Install Dependencies
echo "Installing system dependencies..."
apt-get update
apt-get install -y python3-venv python3-pip network-manager dnsmasq nodejs npm git nginx docker.io

# 2. Setup Directory
INSTALL_DIR="/opt/roomsense/wifi_setup"
SCRIPTS_DIR="/opt/roomsense/scripts"
echo "Setting up directory at $INSTALL_DIR..."
mkdir -p $INSTALL_DIR
mkdir -p $SCRIPTS_DIR

cp -r wifi_setup/* $INSTALL_DIR/
# Move scripts to scripts dir
mv $INSTALL_DIR/provision.sh $SCRIPTS_DIR/
mv $INSTALL_DIR/wifi_watchdog.sh $SCRIPTS_DIR/
chmod +x $SCRIPTS_DIR/provision.sh
chmod +x $SCRIPTS_DIR/wifi_watchdog.sh

# 3. Setup Python Environment
echo "Setting up Python virtual environment..."
python3 -m venv $INSTALL_DIR/venv
$INSTALL_DIR/venv/bin/pip install flask

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
cp $INSTALL_DIR/dnsmasq.conf /etc/NetworkManager/dnsmasq-shared.d/roomsense.conf

# 5. Signal Factory Reset for Next Boot
echo "Signaling factory reset..."
touch $INSTALL_DIR/.factory_reset

# 6. Install Systemd Services
echo "Installing systemd services..."
cp $INSTALL_DIR/roomsense-setup.service /etc/systemd/system/

# Create Watchdog Service & Timer
cat <<EOF > /etc/systemd/system/wifi-watchdog.service
[Unit]
Description=RoomSense WiFi Watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPTS_DIR/wifi_watchdog.sh
EOF

cat <<EOF > /etc/systemd/system/wifi-watchdog.timer
[Unit]
Description=Run WiFi Watchdog periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=wifi-watchdog.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable roomsense-setup.service
# Watchdog timer is NOT enabled by default, it is enabled by provision.sh

echo "Installation Complete!"
echo "Rebooting in 5 seconds..."
sleep 5
reboot

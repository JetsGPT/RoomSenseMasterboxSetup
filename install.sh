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
apt-get install -y python3-venv python3-pip network-manager dnsmasq

# 2. Setup Directory
INSTALL_DIR="/opt/roomsense/wifi_setup"
echo "Setting up directory at $INSTALL_DIR..."
mkdir -p $INSTALL_DIR
cp -r wifi_setup/* $INSTALL_DIR/

# 3. Setup Python Environment
echo "Setting up Python virtual environment..."
python3 -m venv $INSTALL_DIR/venv
$INSTALL_DIR/venv/bin/pip install flask

# 4. Configure NetworkManager & Dnsmasq for Captive Portal
echo "Configuring NetworkManager..."
# Ensure NetworkManager is managing everything
# We need to enable dnsmasq in NetworkManager if not already
if ! grep -q "dns=dnsmasq" /etc/NetworkManager/NetworkManager.conf; then
    echo "Enabling dnsmasq in NetworkManager..."
    # Backup
    cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.bak
    # Add [main] dns=dnsmasq if [main] exists, else append. 
    # Simplest way for now:
    # sed -i '/\[main\]/a dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf
    # But let's be safer. 
    # Actually, for the "Shared" connection, NM spawns a separate dnsmasq instance.
    # We can drop our config in /etc/NetworkManager/dnsmasq-shared.d/
    :
fi

mkdir -p /etc/NetworkManager/dnsmasq-shared.d/
cp $INSTALL_DIR/dnsmasq.conf /etc/NetworkManager/dnsmasq-shared.d/roomsense.conf

# 5. Clear Existing WiFi Connections (As requested)
echo "Clearing existing WiFi connections..."
nmcli --fields UUID,TYPE connection show | grep wifi | awk '{print $1}' | while read uuid; do
    nmcli connection delete "$uuid"
done

# 6. Create Initial Hotspot (if not exists)
# The python script handles this logic on startup usually, but we can pre-create it.
# However, the requirement says "If no wifi connection is saved... it should create its own hotspot".
# Since we just deleted all connections, the python script will see no connections and create the hotspot.
# So we don't need to do it here explicitly, but we can to be sure.

# 7. Install Systemd Service
echo "Installing systemd service..."
cp $INSTALL_DIR/roomsense-setup.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable roomsense-setup.service
systemctl start roomsense-setup.service

echo "Installation Complete! The system will now manage WiFi connections."
echo "Rebooting in 5 seconds to apply all changes..."
sleep 5
reboot

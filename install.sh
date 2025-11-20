#!/bin/bash
# Installation script for RoomSense Pi Onboarding
# Run this script to set up the entire system

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}RoomSense Pi Onboarding Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root (sudo ./install.sh)${NC}"
    exit 1
fi
echo -e "${YELLOW}Step 0: Setting hostname to 'roomsense'...${NC}"
hostnamectl set-hostname roomsense
sed -i 's/127.0.1.1.*/127.0.1.1\troomsense/g' /etc/hosts
echo "roomsense" > /etc/hostname

echo -e "${YELLOW}Step 1: Setting up Access Point configuration...${NC}"
chmod +x "${SCRIPT_DIR}/setup_access_point.sh"
"${SCRIPT_DIR}/setup_access_point.sh"

echo -e "${YELLOW}Step 2: Installing systemd service for Wi-Fi check...${NC}"
cat > /etc/systemd/system/roomsense-wifi-setup.service <<EOF
[Unit]
Description=RoomSense Wi-Fi Setup Check
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/check_wifi_setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable roomsense-wifi-setup.service

echo -e "${YELLOW}Step 3: Making scripts executable...${NC}"
chmod +x "${SCRIPT_DIR}/start_access_point.sh"
chmod +x "${SCRIPT_DIR}/check_wifi_setup.sh"
chmod +x "${SCRIPT_DIR}/post_wifi_connection.sh"
chmod +x "${SCRIPT_DIR}/captive_portal.py"

echo -e "${YELLOW}Step 4: Creating log directories...${NC}"
mkdir -p /var/log
touch /var/log/wifi_setup.log
touch /var/log/post_wifi_setup.log
touch /var/log/captive_portal.log

echo -e "${YELLOW}Step 5: Clearing existing Wi-Fi credentials...${NC}"
# Backup existing config if it exists
if [ -f "/etc/wpa_supplicant/wpa_supplicant.conf" ]; then
    cp /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf.backup.$(date +%Y%m%d_%H%M%S)
    echo -e "${YELLOW}Backed up existing Wi-Fi config${NC}"
fi

# Create minimal wpa_supplicant.conf with no networks
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

EOF

chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
echo -e "${GREEN}Wi-Fi credentials cleared${NC}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Wi-Fi credentials have been cleared.${NC}"
echo -e "${YELLOW}On reboot, the system will start an access point named 'RoomSense-Setup'.${NC}"
echo ""
echo -e "${BLUE}Rebooting in 5 seconds...${NC}"
echo -e "${BLUE}(Press Ctrl+C to cancel)${NC}"
sleep 5

echo -e "${YELLOW}Rebooting now...${NC}"
reboot


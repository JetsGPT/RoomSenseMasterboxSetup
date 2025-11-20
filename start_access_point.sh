#!/bin/bash
# Start Access Point and Captive Portal
# This script activates the AP and starts the captive portal server

set -e

INTERFACE="wlan0"
AP_IP="192.168.4.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Starting Access Point and Captive Portal...${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Stop existing network services
echo -e "${YELLOW}Stopping network services...${NC}"
systemctl stop wpa_supplicant 2>/dev/null || true
systemctl stop dhcpcd 2>/dev/null || true
systemctl stop NetworkManager 2>/dev/null || true

# Kill any existing processes on wlan0
pkill -f wpa_supplicant || true
pkill -f dhcpcd || true

# Bring down interface
ip link set ${INTERFACE} down 2>/dev/null || true
sleep 1

# Configure static IP
echo -e "${YELLOW}Configuring static IP...${NC}"
ip addr flush dev ${INTERFACE} 2>/dev/null || true
ip addr add ${AP_IP}/24 dev ${INTERFACE}
ip link set ${INTERFACE} up

# Start hostapd
echo -e "${YELLOW}Starting hostapd...${NC}"
systemctl unmask hostapd
systemctl enable hostapd
systemctl start hostapd
sleep 2

# Start dnsmasq
echo -e "${YELLOW}Starting dnsmasq...${NC}"
systemctl enable dnsmasq
systemctl start dnsmasq
sleep 2

# Start captive portal server
echo -e "${YELLOW}Starting captive portal server...${NC}"
cd "${SCRIPT_DIR}"


# Kill any existing captive portal
pkill -f captive_portal.py || true
sleep 1

# Start captive portal in background
# Note: Running on port 80 requires root privileges
cd "${SCRIPT_DIR}"
nohup python3 "${SCRIPT_DIR}/captive_portal.py" > /var/log/captive_portal.log 2>&1 &
sleep 2

# Verify it's running
if pgrep -f captive_portal.py > /dev/null; then
    echo -e "${GREEN}Captive portal server is running${NC}"
else
    echo -e "${RED}Warning: Captive portal server may not have started${NC}"
    echo -e "${YELLOW}Check logs: tail -f /var/log/captive_portal.log${NC}"
fi

echo -e "${GREEN}Access Point and Captive Portal started!${NC}"
echo -e "${YELLOW}Connect to 'RoomSense-Setup' network and navigate to any website${NC}"


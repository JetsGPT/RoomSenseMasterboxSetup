#!/bin/bash
# Uninstall script for RoomSense Pi Onboarding
# This script removes the onboarding system and restores original network configuration

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Uninstalling RoomSense Pi Onboarding...${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root (sudo ./uninstall.sh)${NC}"
    exit 1
fi

# Stop services
echo -e "${YELLOW}Stopping services...${NC}"
systemctl stop roomsense-wifi-setup.service 2>/dev/null || true
systemctl stop roomsense-backend.service 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# Kill captive portal
pkill -f captive_portal.py || true

# Disable services
echo -e "${YELLOW}Disabling services...${NC}"
systemctl disable roomsense-wifi-setup.service 2>/dev/null || true
systemctl disable roomsense-backend.service 2>/dev/null || true

# Remove systemd service files
echo -e "${YELLOW}Removing systemd services...${NC}"
rm -f /etc/systemd/system/roomsense-wifi-setup.service
rm -f /etc/systemd/system/roomsense-backend.service
systemctl daemon-reload

# Restore original dnsmasq config if backup exists
if [ -f /etc/dnsmasq.conf.orig ]; then
    echo -e "${YELLOW}Restoring original dnsmasq configuration...${NC}"
    cp /etc/dnsmasq.conf.orig /etc/dnsmasq.conf
fi

# Remove hostapd configuration
echo -e "${YELLOW}Removing hostapd configuration...${NC}"
rm -f /etc/hostapd/hostapd.conf
sed -i 's/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/#DAEMON_CONF=""/' /etc/default/hostapd 2>/dev/null || true

# Remove dhcpcd AP config
rm -f /etc/dhcpcd.conf.ap

echo -e "${GREEN}Uninstallation complete!${NC}"
echo -e "${YELLOW}Note: Wi-Fi credentials in /etc/wpa_supplicant/wpa_supplicant.conf are preserved.${NC}"
echo -e "${YELLOW}Note: Backend and frontend in /opt/roomsense/ are preserved.${NC}"


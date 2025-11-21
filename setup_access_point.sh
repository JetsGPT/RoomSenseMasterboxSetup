#!/bin/bash
# Setup Access Point for Captive Portal
# This script configures hostapd and dnsmasq for the onboarding access point

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INTERFACE="wlan0"
AP_SSID="RoomSense-Setup"
AP_PASSWORD="roomsense123"
AP_CHANNEL="6"
AP_IP="192.168.4.1"
DHCP_RANGE_START="192.168.4.2"
DHCP_RANGE_END="192.168.4.20"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up Access Point for RoomSense onboarding...${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Install required packages
echo -e "${YELLOW}Installing required packages...${NC}"
apt-get update
apt-get install -y hostapd dnsmasq iptables-persistent python3 python3-pip python3-venv iw avahi-daemon

# Stop services if running
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# Configure hostapd
echo -e "${YELLOW}Configuring hostapd...${NC}"
cat > /etc/hostapd/hostapd.conf <<EOF
interface=${INTERFACE}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
country_code=AT
ieee80211n=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

# Configure hostapd daemon
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

# Backup original dnsmasq config if it exists (Issue 1 Fix)
if [ ! -f /etc/dnsmasq.conf.orig ]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
fi
cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup

# Configure dnsmasq
echo -e "${YELLOW}Configuring dnsmasq...${NC}"
cat > /etc/dnsmasq.conf <<EOF
interface=${INTERFACE}
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},255.255.255.0,24h
dhcp-option=3,${AP_IP}
dhcp-option=6,${AP_IP}
server=8.8.8.8
log-queries
log-dhcp
address=/#/${AP_IP}
# Captive Portal Triggers (Issue 4 Fix)
address=/connectivitycheck.gstatic.com/${AP_IP}
address=/msftconnecttest.com/${AP_IP}
address=/apple.com/${AP_IP}
EOF

# Configure static IP for wlan0 (Issue 2 Re-Fix: Ensure clean slate)
echo -e "${YELLOW}Ensuring clean dhcpcd.conf...${NC}"
# Remove any existing static IP config for wlan0 to prevent conflicts
if [ -f /etc/dhcpcd.conf ]; then
    sed -i '/^interface wlan0$/,/^nohook wpa_supplicant$/d' /etc/dhcpcd.conf
fi

# Enable IP forwarding
echo -e "${YELLOW}Enabling IP forwarding...${NC}"
# Create sysctl.conf if it doesn't exist
if [ ! -f /etc/sysctl.conf ]; then
    touch /etc/sysctl.conf
fi

# Check if IP forwarding is already enabled
if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "IP forwarding already enabled in sysctl.conf"
elif grep -q "^#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    # Uncomment if commented
    sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    # Add if not present
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# Apply immediately
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sysctl -p /etc/sysctl.conf > /dev/null 2>&1 || true

# Setup iptables rules for NAT (if eth0 exists)
if ip link show eth0 > /dev/null 2>&1; then
    echo -e "${YELLOW}Configuring iptables for NAT...${NC}"
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables -A FORWARD -i eth0 -o ${INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i ${INTERFACE} -o eth0 -j ACCEPT
    iptables-save > /etc/iptables/rules.v4
fi

# Setup Python Virtual Environment (Issue 5 Fix)
echo -e "${YELLOW}Setting up Python Virtual Environment...${NC}"
mkdir -p /opt/roomsense
python3 -m venv /opt/roomsense/venv
/opt/roomsense/venv/bin/pip install flask

# Setup Captive Portal Service (Issue 1 Fix: Systemd)
echo -e "${YELLOW}Setting up Captive Portal Service...${NC}"
cat > /etc/systemd/system/roomsense-captive-portal.service <<EOF
[Unit]
Description=RoomSense Captive Portal
After=network.target

[Service]
Type=simple
ExecStart=/opt/roomsense/venv/bin/python3 ${SCRIPT_DIR}/captive_portal.py
WorkingDirectory=${SCRIPT_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# We do NOT enable it, as it is controlled by start_access_point.sh
systemctl disable roomsense-captive-portal.service 2>/dev/null || true

# Restart Services (Issue 6 Fix)
echo -e "${YELLOW}Restarting services...${NC}"
systemctl restart dhcpcd 2>/dev/null || true
systemctl start dnsmasq
systemctl start hostapd

echo -e "${GREEN}Access Point configuration complete!${NC}"
echo -e "${YELLOW}SSID: ${AP_SSID}${NC}"
echo -e "${YELLOW}Security: WPA2${NC}"
echo -e "${YELLOW}Password: ${AP_PASSWORD}${NC}"
echo -e "${YELLOW}IP Address: ${AP_IP}${NC}"


#!/bin/bash
# Setup Access Point for Captive Portal
# This script configures hostapd and dnsmasq for the onboarding access point

set -e

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
apt-get install -y hostapd dnsmasq iptables-persistent python3 python3-pip python3-flask iw

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
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# Configure hostapd daemon
sed -i 's/#DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/' /etc/default/hostapd

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
EOF

# Backup original dnsmasq config if it exists
if [ -f /etc/dnsmasq.conf.orig ]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup
else
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
fi

# Configure static IP for wlan0
echo -e "${YELLOW}Configuring static IP...${NC}"
cat > /etc/dhcpcd.conf.ap <<EOF
interface ${INTERFACE}
static ip_address=${AP_IP}/24
nohook wpa_supplicant
EOF

# Enable IP forwarding
echo -e "${YELLOW}Enabling IP forwarding...${NC}"
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p > /dev/null

# Setup iptables rules for NAT (if eth0 exists)
if ip link show eth0 > /dev/null 2>&1; then
    echo -e "${YELLOW}Configuring iptables for NAT...${NC}"
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables -A FORWARD -i eth0 -o ${INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i ${INTERFACE} -o eth0 -j ACCEPT
    iptables-save > /etc/iptables/rules.v4
fi

echo -e "${GREEN}Access Point configuration complete!${NC}"
echo -e "${YELLOW}SSID: ${AP_SSID}${NC}"
echo -e "${YELLOW}Password: ${AP_PASSWORD}${NC}"
echo -e "${YELLOW}IP Address: ${AP_IP}${NC}"


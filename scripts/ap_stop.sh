#!/usr/bin/env bash
set -euo pipefail

WIFI_IF=${WIFI_IF:-}
if [ -z "${WIFI_IF}" ]; then
  # Try multiple methods to detect interface
  WIFI_IF=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
fi
if [ -z "${WIFI_IF}" ] && command -v nmcli >/dev/null 2>&1; then
  WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}')
fi
if [ -z "${WIFI_IF}" ]; then
  WIFI_IF=wlan0
fi

# Stop dnsmasq started by us
if [ -f /run/roomsense-dnsmasq.pid ]; then
  sudo kill "$(cat /run/roomsense-dnsmasq.pid)" 2>/dev/null || true
  sudo rm -f /run/roomsense-dnsmasq.pid 2>/dev/null || true
fi

# Clean up iptables NAT rules for this interface
if [ -n "${WIFI_IF}" ] && [ -e "/sys/class/net/$WIFI_IF" ]; then
  # Get the IP address of the interface to clean up specific rules
  AP_IP=$(ip -o -4 addr show "$WIFI_IF" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n1)
  if [ -n "$AP_IP" ]; then
    # Remove the specific DNAT rules we added (HTTP and HTTPS)
    sudo iptables -t nat -D PREROUTING -i "$WIFI_IF" -p tcp --dport 80 -j DNAT --to-destination "$AP_IP:80" 2>/dev/null || true
    sudo iptables -t nat -D PREROUTING -i "$WIFI_IF" -p tcp --dport 443 -j DNAT --to-destination "$AP_IP:80" 2>/dev/null || true
    echo "[ap_stop] Cleaned up iptables NAT rules for $WIFI_IF"
  fi
fi

if command -v nmcli >/dev/null 2>&1; then
  nmcli con down roomsense-hotspot 2>/dev/null || true
  # Also try to delete the connection
  nmcli connection delete roomsense-hotspot 2>/dev/null || true
else
  # nothing else to stop here; hostapd not managed in this setup
  :
fi

echo "[ap_stop] Hotspot stopped"

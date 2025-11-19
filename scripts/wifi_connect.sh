#!/usr/bin/env bash
set -euo pipefail

SSID="$1"
PSK="$2"
COUNTRY="$3"

if [ -z "$SSID" ] || [ -z "$PSK" ]; then
  echo "Usage: wifi_connect.sh <SSID> <PASSWORD> <COUNTRY>"
  exit 1
fi

# Detect Wi-Fi interface with multiple methods
WIFI_IF=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
if [ -z "$WIFI_IF" ] && command -v nmcli >/dev/null 2>&1; then
  WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}')
fi
if [ -z "$WIFI_IF" ]; then
  WIFI_IF=$(ls /sys/class/net/ | grep -E '^wlan[0-9]+$' | head -n1)
fi
[ -z "$WIFI_IF" ] && WIFI_IF=wlan0

sudo iw reg set "$COUNTRY" || true

if command -v nmcli >/dev/null 2>&1; then
  echo "[wifi_connect] Using NetworkManager on $WIFI_IF"
  nmcli dev disconnect "$WIFI_IF" || true
  # If a connection with same SSID exists, try to use it
  if nmcli -t -f NAME,TYPE con | grep -q "^$SSID:wifi$"; then
    nmcli con up "$SSID" ifname "$WIFI_IF"
  else
    nmcli dev wifi connect "$SSID" password "$PSK" ifname "$WIFI_IF"
  fi
else
  echo "[wifi_connect] Legacy path using wpa_cli"
  sudo wpa_cli -i "$WIFI_IF" disconnect || true
  NET_ID=$(wpa_cli -i "$WIFI_IF" add_network | tail -n1)
  wpa_cli -i "$WIFI_IF" set_network "$NET_ID" ssid '"'"$SSID"'"'
  wpa_cli -i "$WIFI_IF" set_network "$NET_ID" psk '"'"$PSK"'"'
  wpa_cli -i "$WIFI_IF" enable_network "$NET_ID"
  wpa_cli -i "$WIFI_IF" save_config
fi

# Wait for connectivity
for i in {1..20}; do
  if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
    echo "[wifi_connect] Connected"
    touch /opt/roomsense/state/wifi_connected
    exit 0
  fi
  sleep 1
  echo "[wifi_connect] Waiting for IP... ($i)"
done

echo "[wifi_connect] Failed to connect"
exit 2

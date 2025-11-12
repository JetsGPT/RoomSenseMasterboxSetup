#!/usr/bin/env bash
set -euo pipefail

SSID=${SSID:-RoomSense-Setup}
PSK=${PSK:-roomsense123}
COUNTRY=${COUNTRY:-AT}

# Detect Wi-Fi interface automatically
WIFI_IF=${WIFI_IF:-}
if [ -z "${WIFI_IF}" ]; then
  WIFI_IF=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
fi
if [ -z "${WIFI_IF}" ]; then
  WIFI_IF=wlan0
fi

# Set regulatory domain
sudo iw reg set "$COUNTRY" || true

if command -v nmcli >/dev/null 2>&1; then
  echo "[ap_start] Using NetworkManager to start hotspot on $WIFI_IF"
  # Disconnect client if any
  nmcli dev disconnect "$WIFI_IF" || true
  # Create hotspot connection named roomsense-hotspot
  nmcli dev wifi hotspot ifname "$WIFI_IF" ssid "$SSID" password "$PSK" || true
  nmcli con modify Hotspot connection.id roomsense-hotspot || true
  nmcli con up roomsense-hotspot || true
  # Ensure the AP has a known address; NM typically assigns 10.42.0.1/24
  AP_ADDR=$(ip -o -4 addr show "$WIFI_IF" | awk '{print $4}' | head -n1)
  if [ -z "$AP_ADDR" ]; then
    sudo ip addr add 10.42.0.1/24 dev "$WIFI_IF" || true
    sudo ip link set "$WIFI_IF" up || true
  fi
  # Add iptables redirect from clients' HTTP to portal on this device
  sudo iptables -t nat -C PREROUTING -i "$WIFI_IF" -p tcp --dport 80 -j DNAT --to-destination 10.42.0.1:80 2>/dev/null || \
    sudo iptables -t nat -A PREROUTING -i "$WIFI_IF" -p tcp --dport 80 -j DNAT --to-destination 10.42.0.1:80
  echo "[ap_start] HTTP redirect to portal enabled"
else
  echo "[ap_start] Legacy path: hostapd + static IP on $WIFI_IF"
  sudo ip link set "$WIFI_IF" down || true
  sudo ip addr flush dev "$WIFI_IF" || true
  sudo ip link set "$WIFI_IF" up || true
  sudo ip addr add 10.42.0.1/24 dev "$WIFI_IF" || true
  # Expect hostapd service to be configured if needed (not provided here)
  # Start dnsmasq in captive mode bound to the AP interface (legacy path)
  sudo systemctl stop dnsmasq || true
  sudo dnsmasq --conf-file=/etc/roomsense/dnsmasq-portal.conf --interface="$WIFI_IF" --except-interface=lo --bind-interfaces --log-facility=/opt/roomsense/logs/dnsmasq.log --pid-file=/run/roomsense-dnsmasq.pid
  echo "[ap_start] Hotspot and captive DNS started on $WIFI_IF"
fi

echo "[ap_start] Hotspot ready on $WIFI_IF"

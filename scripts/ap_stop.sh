#!/usr/bin/env bash
set -euo pipefail

WIFI_IF=${WIFI_IF:-}
if [ -z "${WIFI_IF}" ]; then
  WIFI_IF=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
fi

# Stop dnsmasq started by us
if [ -f /run/roomsense-dnsmasq.pid ]; then
  sudo kill "$(cat /run/roomsense-dnsmasq.pid)" || true
  sudo rm -f /run/roomsense-dnsmasq.pid || true
fi

if command -v nmcli >/dev/null 2>&1; then
  nmcli con down roomsense-hotspot || true
else
  # nothing else to stop here; hostapd not managed in this setup
  :
fi

echo "[ap_stop] Hotspot stopped"

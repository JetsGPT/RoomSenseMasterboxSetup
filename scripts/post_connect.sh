#!/usr/bin/env bash
set -euo pipefail

# Stop portal and AP, then reboot
/opt/roomsense/setup/scripts/portal_stop.sh || true
/opt/roomsense/setup/scripts/ap_stop.sh || true

echo "[post_connect] Rebooting in 2s..."
sleep 2
reboot

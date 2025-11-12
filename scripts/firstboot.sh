#!/usr/bin/env bash
set -euo pipefail

COUNTRY=${COUNTRY:-AT}

LOG_DIR=/opt/roomsense/logs
mkdir -p "$LOG_DIR"

if "$(dirname "$0")/network_check.sh"; then
  echo "[firstboot] Internet available; starting deploy"
  systemctl start roomsense-deploy.service
  exit 0
fi

# No internet: start portal target
export COUNTRY
echo "[firstboot] No internet; starting hotspot + portal"
systemctl start roomsense-portal.target

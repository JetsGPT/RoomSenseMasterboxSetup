#!/usr/bin/env bash
set -euo pipefail

COUNTRY=${COUNTRY:-AT}

LOG_DIR=/opt/roomsense/logs
mkdir -p "$LOG_DIR"

STATE_DIR=/opt/roomsense/state
FORCE_PORTAL_FLAG="$STATE_DIR/force_portal_once"
mkdir -p "$STATE_DIR"

if [ -f "$FORCE_PORTAL_FLAG" ]; then
  echo "[firstboot] Force portal flag detected; starting hotspot + portal regardless of internet"
  rm -f "$FORCE_PORTAL_FLAG" || true
  export COUNTRY
  if ! systemctl start roomsense-portal.target; then
    echo "[firstboot] ERROR: Failed to start roomsense-portal.target" >&2
    systemctl status roomsense-ap.service || true
    systemctl status roomsense-portal.service || true
    exit 1
  fi
  echo "[firstboot] Portal target started successfully"
  exit 0
fi

if "$(dirname "$0")/network_check.sh"; then
  echo "[firstboot] Internet available; starting deploy"
  systemctl start roomsense-deploy.service
  exit 0
fi

# No internet: start portal target
export COUNTRY
echo "[firstboot] No internet; starting hotspot + portal"
if ! systemctl start roomsense-portal.target; then
  echo "[firstboot] ERROR: Failed to start roomsense-portal.target" >&2
  systemctl status roomsense-ap.service || true
  systemctl status roomsense-portal.service || true
  exit 1
fi
echo "[firstboot] Portal target started successfully"

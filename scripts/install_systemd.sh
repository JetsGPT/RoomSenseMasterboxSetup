#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR_SRC="$REPO_ROOT/systemd"
UNIT_DIR_DST="/etc/systemd/system"

echo "[install_systemd] Copying setup scripts to /opt/roomsense/setup"
sudo mkdir -p /opt/roomsense/setup
sudo rsync -a --delete "$REPO_ROOT/scripts/" /opt/roomsense/setup/scripts/

echo "[install_systemd] Copying portal app to /opt/roomsense/portal"
sudo mkdir -p /opt/roomsense/portal
sudo rsync -a --delete "$REPO_ROOT/portal/" /opt/roomsense/portal/

echo "[install_systemd] Installing units"
sudo install -m 0644 "$UNIT_DIR_SRC/roomsense-portal.target" "$UNIT_DIR_DST/"
sudo install -m 0644 "$UNIT_DIR_SRC/roomsense-ap.service" "$UNIT_DIR_DST/"
sudo install -m 0644 "$UNIT_DIR_SRC/roomsense-portal.service" "$UNIT_DIR_DST/"
sudo install -m 0644 "$UNIT_DIR_SRC/roomsense-firstboot.service" "$UNIT_DIR_DST/"
sudo install -m 0644 "$UNIT_DIR_SRC/roomsense-deploy.service" "$UNIT_DIR_DST/"

sudo systemctl daemon-reload

# Enable firstboot to run at boot
sudo systemctl enable roomsense-firstboot.service

echo "[install_systemd] Done"

#!/usr/bin/env bash
set -euo pipefail

COUNTRY=${COUNTRY:-AT}

# Prepare venv
if [ ! -d /opt/roomsense/portal-venv ]; then
  python3 -m venv /opt/roomsense/portal-venv
fi
source /opt/roomsense/portal-venv/bin/activate
pip install --upgrade pip >/dev/null
pip install flask gunicorn >/dev/null

echo "[portal_start] Starting Flask portal on :80"
export ROOMSENSE_COUNTRY="$COUNTRY"
export FLASK_APP=/opt/roomsense/portal/app.py

# Copy portal app if not present
if [ ! -d /opt/roomsense/portal ]; then
  sudo mkdir -p /opt/roomsense/portal
  sudo cp -r "$(dirname "$0")/../portal/." /opt/roomsense/portal/
fi

exec gunicorn -w 2 -b 0.0.0.0:80 app:app -c /dev/null --chdir /opt/roomsense/portal

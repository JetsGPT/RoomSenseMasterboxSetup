#!/usr/bin/env bash
set -euo pipefail

COUNTRY=${COUNTRY:-AT}

LOG_DIR=/opt/roomsense/logs
mkdir -p "$LOG_DIR"

# Verify portal files exist
if [ ! -d /opt/roomsense/portal ] || [ ! -f /opt/roomsense/portal/app.py ]; then
  echo "[portal_start] ERROR: Portal files not found at /opt/roomsense/portal" >&2
  echo "[portal_start] Portal should have been copied by install_systemd.sh" >&2
  exit 1
fi

# Prepare venv
if [ ! -d /opt/roomsense/portal-venv ]; then
  echo "[portal_start] Creating Python virtual environment..."
  python3 -m venv /opt/roomsense/portal-venv
fi

echo "[portal_start] Activating virtual environment and installing dependencies..."
source /opt/roomsense/portal-venv/bin/activate
pip install --upgrade pip --quiet
pip install flask gunicorn --quiet

echo "[portal_start] Starting Flask portal on 0.0.0.0:80"
export ROOMSENSE_COUNTRY="$COUNTRY"
export FLASK_APP=/opt/roomsense/portal/app.py

# Verify we can bind to port 80
if ! command -v gunicorn >/dev/null 2>&1; then
  echo "[portal_start] ERROR: gunicorn not found after installation" >&2
  exit 1
fi

# Check if port 80 is already in use
if command -v ss >/dev/null 2>&1; then
  if ss -tlnp | grep -q ":80 "; then
    echo "[portal_start] WARNING: Port 80 is already in use" >&2
    ss -tlnp | grep ":80 " || true
  fi
elif command -v netstat >/dev/null 2>&1; then
  if netstat -tlnp 2>/dev/null | grep -q ":80 "; then
    echo "[portal_start] WARNING: Port 80 is already in use" >&2
    netstat -tlnp 2>/dev/null | grep ":80 " || true
  fi
fi

# Start gunicorn
exec gunicorn -w 2 -b 0.0.0.0:80 app:app --chdir /opt/roomsense/portal --access-logfile "$LOG_DIR/portal-access.log" --error-logfile "$LOG_DIR/portal-error.log"

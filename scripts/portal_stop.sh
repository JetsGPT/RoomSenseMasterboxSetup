#!/usr/bin/env bash
set -euo pipefail

pkill -f "gunicorn.*app:app" || true

echo "[portal_stop] Portal stopped"

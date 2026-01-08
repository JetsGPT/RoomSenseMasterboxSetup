#!/bin/bash

# RoomSense WiFi Watchdog
# Checks for internet connectivity.
# If lost:
# 1. Retry X times.
# 2. If still lost, STOP Main App.
# 3. START Setup Hotspot.

TARGET_HOST="8.8.8.8"
FAIL_COUNT=0
MAX_RETRIES=3

check_connection() {
    ping -c 1 -W 2 $TARGET_HOST > /dev/null 2>&1
    return $?
}

if check_connection; then
    echo "Connection OK"
    exit 0
else
    echo "Connection lost. Retrying..."
    for i in $(seq 1 $MAX_RETRIES); do
        sleep 20
        if check_connection; then
             echo "Connection restored on retry $i."
             exit 0
        fi
    done
fi

echo "Connection permanently lost. Reverting to Setup Mode..."

# Stop Production App
systemctl stop roomsense-app.service

# Start AP Mode
systemctl start roomsense-setup.service

# We might want to disable the watchdog timer so it doesn't keep firing
# But if it fires while in setup mode, it will just fail ping and restart setup service (idempotent-ish)
# or we can have logic to check if setup service is already running.

IS_SETUP_RUNNING=$(systemctl is-active roomsense-setup.service)
if [ "$IS_SETUP_RUNNING" != "active" ]; then
    systemctl start roomsense-setup.service
fi

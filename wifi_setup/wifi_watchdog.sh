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

# Define absolute paths for safety in systemd environment
PING_CMD="/bin/ping"
SYSTEMCTL_CMD="/bin/systemctl"
SLEEP_CMD="/bin/sleep"
DATE_CMD="/bin/date"

LOG_FILE="/var/log/roomsense_watchdog.log"
log() {
    $DATE_CMD >> $LOG_FILE
    echo "$1" >> $LOG_FILE
}

# Redirect stdout/stderr to log just in case
exec >> $LOG_FILE 2>&1

log "Watchdog started."

check_connection() {
    # Try ping. 
    $PING_CMD -c 1 -W 2 $TARGET_HOST > /dev/null 2>&1
    return $?
}

if check_connection; then
    log "Connection OK."
    exit 0
else
    log "Connection lost. Retrying..."
    for i in $(seq 1 $MAX_RETRIES); do
        $SLEEP_CMD 20
        if check_connection; then
             log "Connection restored on retry $i."
             exit 0
        fi
    done
fi

log "Connection permanently lost. Reverting to Setup Mode..."

# Stop Production App (Nginx holds Port 80, which we need)
# Also stop Docker (containers might hold Port 80, 443, etc)
log "Stopping Nginx..."
$SYSTEMCTL_CMD stop nginx
log "Stopping Docker..."
$SYSTEMCTL_CMD stop docker

# Start AP Mode
log "Enabling & Starting Setup Service..."
# Enable ensures if user reboots while offline, the AP comes back
$SYSTEMCTL_CMD enable roomsense-setup.service
$SYSTEMCTL_CMD start roomsense-setup.service

# Double check
IS_SETUP_RUNNING=$($SYSTEMCTL_CMD is-active roomsense-setup.service)
if [ "$IS_SETUP_RUNNING" != "active" ]; then
    log "Setup service not active (Status: $IS_SETUP_RUNNING), forcing start..."
    $SYSTEMCTL_CMD start roomsense-setup.service
else
    log "Setup service already running."
fi

log "Watchdog action complete."

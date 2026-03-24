#!/bin/bash

# RoomSense WiFi Watchdog
# Checks for internet connectivity.
# If lost:
# 1. Retry X times.
# 2. If still lost, STOP Main App.
# 3. START Setup Hotspot.

TARGET_HOST="8.8.8.8"
FAIL_COUNT=0
MAX_RETRIES=5
RETRY_WAIT=30

# Define absolute paths for safety in systemd environment
PING_CMD="/bin/ping"
SYSTEMCTL_CMD="/bin/systemctl"
SLEEP_CMD="/bin/sleep"
DATE_CMD="/bin/date"

LOG_FILE="/var/log/roomsense_watchdog.log"

# Log rotation: keep log under 100KB
MAX_LOG_SIZE=102400
if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
    tail -c 50000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

log() {
    $DATE_CMD >> $LOG_FILE
    echo "$1" >> $LOG_FILE
}

# Redirect stdout/stderr to log just in case
exec >> $LOG_FILE 2>&1

log "Watchdog started."

# [FIX 2] RESTORE AUTOCONNECT
# Ensure we try to connect to saved networks before assuming we need the Hotspot.
# This fixes the issue where the device remembers 'autoconnect=no' from the previous AP session.
log "Ensuring saved networks are set to auto-connect..."
/usr/bin/nmcli -t -f UUID,NAME,TYPE connection show | while IFS=: read -r uuid name type; do
    if [[ "$type" =~ wifi|wireless ]] && [ "$name" != "RoomSenseSetup" ]; then
        /usr/bin/nmcli connection modify "$uuid" connection.autoconnect yes
    fi
done

# EDGE CASE: If setup service (AP mode) is already active, skip monitoring
# Otherwise watchdog will continuously fail pings and restart services
IS_SETUP_ACTIVE=$($SYSTEMCTL_CMD is-active roomsense-setup.service 2>/dev/null)
if [ "$IS_SETUP_ACTIVE" = "active" ]; then
    log "Setup service is active (AP mode). Skipping connectivity check."
    exit 0
fi

IS_PROVISION_ACTIVE=$($SYSTEMCTL_CMD is-active roomsense-provision.service 2>/dev/null)
if [ "$IS_PROVISION_ACTIVE" = "active" ] || [ "$IS_PROVISION_ACTIVE" = "activating" ]; then
    log "Provisioning service is active. Skipping connectivity check."
    exit 0
fi

check_connection() {
    # Try ping. 
    $PING_CMD -c 1 -W 2 $TARGET_HOST > /dev/null 2>&1
    return $?
}

if check_connection; then
    log "Connection OK."
    exit 0
else
    log "Connection lost. Retrying with backoff..."
    for i in $(seq 1 $MAX_RETRIES); do
        $SLEEP_CMD $RETRY_WAIT
        if check_connection; then
             log "Connection restored on retry $i."
             exit 0
        fi
        log "Retry $i failed."
    done
fi

log "Connection permanently lost. Attempting reconnection before AP mode..."

# First, attempt to reconnect to any saved WiFi networks
log "Toggling networking to trigger reconnection..."
/usr/bin/nmcli networking off
$SLEEP_CMD 2
/usr/bin/nmcli networking on

# Wait longer for DHCP on slow networks
log "Waiting 45s for network reconnection..."
$SLEEP_CMD 45

# Check if reconnection worked
if $PING_CMD -c 1 -W 2 $TARGET_HOST > /dev/null 2>&1; then
    log "Reconnection successful after networking toggle. Exiting..."
    exit 0
fi

# Give it one more try with a shorter wait
log "First reconnection attempt failed. Waiting another 30s..."
$SLEEP_CMD 30

if $PING_CMD -c 1 -W 2 $TARGET_HOST > /dev/null 2>&1; then
    log "Reconnection successful on second attempt. Exiting..."
    exit 0
fi

log "Reconnection failed. Reverting to Setup Mode..."

# [FIX 2A] Check if provisioning is running - don't interrupt it
if pgrep -f "provision.sh" > /dev/null || [ "$IS_PROVISION_ACTIVE" = "active" ] || [ "$IS_PROVISION_ACTIVE" = "activating" ]; then
    log "Provisioning is in progress. Deferring watchdog action."
    exit 0
fi

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

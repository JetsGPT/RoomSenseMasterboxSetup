#!/bin/bash
# Check if Wi-Fi is configured and start appropriate service
# This script runs on boot to determine if AP mode or normal Wi-Fi should be used

set -e

WPA_SUPPLICANT_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/wifi_setup.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log "Checking Wi-Fi configuration..."

# Check if wpa_supplicant.conf exists and has network entries
if [ -f "${WPA_SUPPLICANT_CONF}" ]; then
    # Check if there are any network blocks (excluding empty/comment lines)
    NETWORK_COUNT=$(grep -c "^network=" "${WPA_SUPPLICANT_CONF}" 2>/dev/null || echo "0")
    
    if [ "${NETWORK_COUNT}" -gt 0 ]; then
        log "Wi-Fi credentials found. Attempting to connect..."
        
        # Wait for interface to be ready
        sleep 5
        
        # Try to connect to Wi-Fi
        systemctl restart wpa_supplicant 2>/dev/null || true
        systemctl restart dhcpcd 2>/dev/null || true
        
        # Wait for connection (check multiple times)
        CONNECTED=false
        for i in {1..15}; do
            sleep 2
            if ip addr show wlan0 | grep -q "inet "; then
                CONNECTED=true
                break
            fi
        done
        
        # Check if we have an IP address
        if [ "$CONNECTED" = true ]; then
            log "Successfully connected to Wi-Fi!"
            
            # Start post-connection setup
            "${SCRIPT_DIR}/post_wifi_connection.sh" &
            
            exit 0
        else
            log "Failed to connect to Wi-Fi. Starting access point..."
        fi
    else
        log "No Wi-Fi networks configured. Starting access point..."
    fi
else
    log "No wpa_supplicant.conf found. Starting access point..."
fi

# No Wi-Fi configured or connection failed - start access point
log "Starting access point mode..."
"${SCRIPT_DIR}/start_access_point.sh"


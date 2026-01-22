#!/bin/bash

# RoomSense Provisioning Script
# Triggers after successful WiFi connection

LOG_FILE="/var/log/roomsense_provision.log"
INSTALL_DIR="/opt/roomsense"
BACKEND_REPO="https://github.com/JetsGPT/RoomSenseLocalServer.git"
FRONTEND_REPO="https://github.com/JetsGPT/RoomSenseAppReact.git"

# Redirect stdout/stderr to log
exec > >(tee -a $LOG_FILE) 2>&1

echo "Starting Provisioning Process..."
date

# Exit strictly on any error
set -e

# 1. Wait for Internet
echo "Waiting for internet connection..."
while ! ping -c 1 -W 1 8.8.8.8; do
    echo "Waiting for 8.8.8.8..."
    sleep 5
done
echo "Internet connected!"

# 2. Clone/Update Repositories
echo "Setting up repositories in $INSTALL_DIR..."
mkdir -p $INSTALL_DIR

# Backend
if [ -d "$INSTALL_DIR/backend" ]; then
    echo "Updating Backend..."
    cd "$INSTALL_DIR/backend"
    git fetch --all
    git reset --hard origin/main
    echo "Backend updated to latest."
else
    echo "Cloning Backend..."
    git clone $BACKEND_REPO "$INSTALL_DIR/backend"
fi

# Frontend
if [ -d "$INSTALL_DIR/frontend" ]; then
    echo "Updating Frontend..."
    cd "$INSTALL_DIR/frontend"
    git fetch --all
    git reset --hard origin/main
    echo "Frontend updated to latest."
else
    echo "Cloning Frontend..."
    git clone $FRONTEND_REPO "$INSTALL_DIR/frontend"
fi

# 3. Frontend Build & Deploy to Backend (Express)
DEPLOY_TARGET="$INSTALL_DIR/backend/webserver/src/public"
mkdir -p "$DEPLOY_TARGET"

# Always rebuild frontend to ensure latest version is deployed
echo "Building Frontend..."
cd "$INSTALL_DIR/frontend/roomsenseapp"

# Clean npm cache and node_modules to ensure fresh build
rm -rf node_modules/.cache dist
npm install
npm run build

echo "Deploying Frontend to Backend (Express)..."
# Clear old deploy and copy fresh build artifacts
rm -rf "$DEPLOY_TARGET"/*
cp -r "$INSTALL_DIR/frontend/roomsenseapp/dist/"* "$DEPLOY_TARGET/"
echo "Frontend deployed."

# 4. Backend Setup (Docker Swarm)
echo "Starting Backend..."

# CRITICAL: Stop the setup service NOW (releases port 80 for nginx)
# This must happen BEFORE deploying the stack, otherwise nginx can't bind to port 80
echo "Stopping setup service to release port 80..."
systemctl stop roomsense-setup.service || true

# Wait for port 80 to be released (Flask takes a moment to shutdown)
for i in {1..10}; do
    if ! ss -tlnp | grep -q ':80 '; then
        echo "Port 80 is free"
        break
    fi
    echo "Waiting for port 80 to be released... ($i/10)"
    sleep 1
done

# Ensure Docker is running (it might have been stopped by app.py during reset)
systemctl start docker

cd "$INSTALL_DIR/backend/webserver"

# Initialize Docker Swarm
# Check if Swarm is active
SWARM_STATUS=$(docker info --format '{{.Swarm.LocalNodeState}}')
IS_MANAGER=$(docker info --format '{{.Swarm.ControlAvailable}}')

echo "Docker Swarm Status: $SWARM_STATUS (Manager: $IS_MANAGER)"

# Detect WiFi interface dynamically
WIFI_IFACE=$(nmcli -t -f DEVICE,TYPE device | grep wifi | cut -d: -f1 | head -n1)
if [ -z "$WIFI_IFACE" ]; then
    WIFI_IFACE="wlan0"
fi
echo "Using WiFi interface: $WIFI_IFACE"

if [ "$SWARM_STATUS" = "active" ] && [ "$IS_MANAGER" = "true" ]; then
    # [FIX 1B] Check if current IP matches the advertise address
    # DHCP may assign a different IP after reboot, breaking Swarm
    CURRENT_IP=$(ip -4 addr show $WIFI_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    SWARM_ADDR=$(docker info --format '{{.Swarm.NodeAddr}}')
    
    if [ -n "$CURRENT_IP" ] && [ -n "$SWARM_ADDR" ] && [ "$CURRENT_IP" != "$SWARM_ADDR" ]; then
        echo "IP mismatch detected! Current: $CURRENT_IP, Swarm: $SWARM_ADDR"
        echo "Re-initializing Swarm with new IP..."
        docker swarm leave --force
        docker swarm init --advertise-addr $CURRENT_IP
    else
        echo "Swarm is already initialized with correct IP ($SWARM_ADDR)."
    fi
elif [ "$SWARM_STATUS" = "active" ] && [ "$IS_MANAGER" != "true" ]; then
    echo "Node is in Swarm but NOT a manager. Leaving..."
    docker swarm leave --force
    echo "Initializing new Swarm..."
    # Determine the IP address of WiFi interface or fall back to default route
    ADVERTISE_ADDR=$(ip -4 addr show $WIFI_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$ADVERTISE_ADDR" ]; then
        docker swarm init
    else
        docker swarm init --advertise-addr $ADVERTISE_ADDR
    fi
else
    echo "Initializing Docker Swarm..."
    # Determine the IP address of WiFi interface or fall back to default route
    ADVERTISE_ADDR=$(ip -4 addr show $WIFI_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$ADVERTISE_ADDR" ]; then
        docker swarm init
    else
        docker swarm init --advertise-addr $ADVERTISE_ADDR
    fi
fi
# Ensure executable
chmod +x scripts/init/start.sh
# Run the start script handles restarts
./scripts/init/start.sh

# 5. Transition to Production
echo "Transitioning to Production Mode..."

# Enable Watchdog FIRST (before stopping setup service)
systemctl enable wifi-watchdog.timer
systemctl start wifi-watchdog.timer

# STOP Nginx (if running) because Docker/Express will likely want Port 80
systemctl stop nginx
systemctl disable nginx

# Check if first time provisioning
if [ -f "/opt/roomsense/wifi_setup/.provisioned" ]; then
    echo "Update complete. Services restarted."
    # Service was already stopped before stack deployment
    systemctl disable roomsense-setup.service
else
    # First time provision
    echo "First time provisioning complete."
    touch /opt/roomsense/wifi_setup/.provisioned
    
    # Disable setup service FIRST
    systemctl disable roomsense-setup.service
    
    echo "Rebooting in 5 seconds..."
    sleep 5
    # Use nohup to detach reboot from this script/service
    nohup /sbin/reboot &
fi

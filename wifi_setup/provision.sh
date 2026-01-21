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

CHANGES_DETECTED=false

# Backend
if [ -d "$INSTALL_DIR/backend" ]; then
    echo "Updating Backend..."
    cd "$INSTALL_DIR/backend"
    OLD_HEAD=$(git rev-parse HEAD)
    git pull
    NEW_HEAD=$(git rev-parse HEAD)
    if [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
        CHANGES_DETECTED=true
        echo "Backend changes detected."
    fi
else
    echo "Cloning Backend..."
    git clone $BACKEND_REPO "$INSTALL_DIR/backend"
    CHANGES_DETECTED=true
fi

# Frontend
if [ -d "$INSTALL_DIR/frontend" ]; then
    echo "Updating Frontend..."
    cd "$INSTALL_DIR/frontend"
    OLD_HEAD=$(git rev-parse HEAD)
    git pull
    NEW_HEAD=$(git rev-parse HEAD)
    if [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
        CHANGES_DETECTED=true
        echo "Frontend changes detected."
    fi
else
    echo "Cloning Frontend..."
    git clone $FRONTEND_REPO "$INSTALL_DIR/frontend"
    CHANGES_DETECTED=true
fi

# 3. Frontend Build & Deploy to Backend (Express)
DEPLOY_TARGET="$INSTALL_DIR/backend/webserver/src/public"
mkdir -p "$DEPLOY_TARGET"

# Only build if changes were detected OR if the deploy target is truly empty (first run)
DEPLOY_EMPTY=false
if [ ! -f "$DEPLOY_TARGET/index.html" ]; then
    DEPLOY_EMPTY=true
fi

if [ "$CHANGES_DETECTED" = true ] || [ "$DEPLOY_EMPTY" = true ]; then
    echo "Building Frontend (changes detected or first deploy)..."
    cd "$INSTALL_DIR/frontend/roomsenseapp"
    npm install
    npm run build

    echo "Deploying Frontend to Backend (Express)..."
    # Copy build artifacts (Vite uses 'dist')
    cp -r "$INSTALL_DIR/frontend/roomsenseapp/dist/"* "$DEPLOY_TARGET/"
    echo "Frontend deployed."
else
    echo "No changes detected. Skipping Frontend build."
fi

# 4. Backend Setup (Docker Swarm)
echo "Starting Backend..."
# Ensure Docker is running (it might have been stopped by app.py during reset)
systemctl start docker

cd "$INSTALL_DIR/backend/webserver"

# Initialize Docker Swarm
# Check if Swarm is active
SWARM_STATUS=$(docker info --format '{{.Swarm.LocalNodeState}}')
IS_MANAGER=$(docker info --format '{{.Swarm.ControlAvailable}}')

echo "Docker Swarm Status: $SWARM_STATUS (Manager: $IS_MANAGER)"

if [ "$SWARM_STATUS" = "active" ] && [ "$IS_MANAGER" = "true" ]; then
    echo "Swarm is already initialized and active manager."
elif [ "$SWARM_STATUS" = "active" ] && [ "$IS_MANAGER" != "true" ]; then
    echo "Node is in Swarm but NOT a manager. Leaving..."
    docker swarm leave --force
    echo "Initializing new Swarm..."
    # Determine the IP address of wlan0 or fall back to default route
    ADVERTISE_ADDR=$(ip -4 addr show wlan0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$ADVERTISE_ADDR" ]; then
        docker swarm init
    else
        docker swarm init --advertise-addr $ADVERTISE_ADDR
    fi
else
    echo "Initializing Docker Swarm..."
    # Determine the IP address of wlan0 or fall back to default route
    ADVERTISE_ADDR=$(ip -4 addr show wlan0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
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

# STOP Setup Service to free Port 80
systemctl stop roomsense-setup.service
systemctl disable roomsense-setup.service

# STOP Nginx (if running) because Docker/Express will likely want Port 80
systemctl stop nginx
systemctl disable nginx

# Enable Watchdog
systemctl enable wifi-watchdog.timer
systemctl start wifi-watchdog.timer

# Check if first time provisioning
if [ -f "/opt/roomsense/wifi_setup/.provisioned" ]; then
    echo "Update complete. Services restarted. Skipping reboot."
else
    # First time provision
    echo "First time provisioning complete."
    touch /opt/roomsense/wifi_setup/.provisioned
    echo "Rebooting in 10 seconds..."
    sleep 10
    reboot
fi

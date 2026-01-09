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
    cd "$INSTALL_DIR/backend" && git pull
else
    echo "Cloning Backend..."
    git clone $BACKEND_REPO "$INSTALL_DIR/backend"
fi

# Frontend
if [ -d "$INSTALL_DIR/frontend" ]; then
    echo "Updating Frontend..."
    cd "$INSTALL_DIR/frontend" && git pull
else
    echo "Cloning Frontend..."
    git clone $FRONTEND_REPO "$INSTALL_DIR/frontend"
fi

# 3. Frontend Build & Deploy to Backend (Express)
echo "Building Frontend..."
cd "$INSTALL_DIR/frontend/roomsenseapp"
npm install
npm run build

echo "Deploying Frontend to Backend (Express)..."
# Destination: The 'public' folder of the Express app inside the cloned backend repo.
# Note: This assumes the Docker container mounts this directory or has verified permissions.
DEPLOY_TARGET="$INSTALL_DIR/backend/webserver/src/public"
mkdir -p "$DEPLOY_TARGET"

# Copy build artifacts (Vite uses 'dist')
# We use rsync or cp. cp -r is simpler.
cp -r "$INSTALL_DIR/frontend/roomsenseapp/dist/"* "$DEPLOY_TARGET/"

echo "Frontend deployed. Express should now serve the app."

# 4. Backend Setup (Docker Swarm)
echo "Starting Backend..."
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
# Run the start script
# We can't be sure if we are in the right relative path, but the script handles it via SCRIPT_DIR
./scripts/init/start.sh

# 5. Transition to Production
echo "Transitioning to Production Mode..."

# STOP Setup Service to free Port 80
systemctl stop roomsense-setup.service
systemctl disable roomsense-setup.service

# STOP Nginx (if running) because Docker/Express will likely want Port 80 (or handled by Traefik/Swarm)
# Since we are deploying to Express, we assume the Backend handles the web serving now.
systemctl stop nginx
systemctl disable nginx

# Mark provisioning as successful
touch /opt/roomsense/wifi_setup/.provisioned

# Enable Watchdog
systemctl enable wifi-watchdog.timer
systemctl start wifi-watchdog.timer

echo "Provisioning Complete. Rebooting in 10 seconds..."
sleep 10
reboot

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

# 3. Backend Setup (Docker Swarm)
echo "Starting Backend..."
cd "$INSTALL_DIR/backend"
# Ensure executable
chmod +x scripts/init/start.sh
# Run the start script
# We can't be sure if we are in the right relative path, but the script handles it via SCRIPT_DIR
./scripts/init/start.sh

# 4. Frontend Build & Serve
echo "Building Frontend..."
# The frontend code is in the 'roomsenseapp' folder inside the repo
cd "$INSTALL_DIR/frontend/roomsenseapp"
npm install
npm run build

echo "Configuring Nginx to serve Frontend..."
# Assuming 'dist' is the build output (default for Vite)
BUILD_DIR="$INSTALL_DIR/frontend/roomsenseapp/dist"

# Simple Nginx Config
cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    server_name _;
    root $BUILD_DIR;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

# Reload Nginx
if systemctl is-active --quiet nginx; then
    systemctl reload nginx
else
    systemctl enable nginx
    systemctl start nginx
fi

# 5. Transition to Production
echo "Transitioning to Production Mode..."

# Disable Setup Service
systemctl disable roomsense-setup.service

# Enable Watchdog
systemctl enable wifi-watchdog.timer
systemctl start wifi-watchdog.timer

echo "Provisioning Complete. Rebooting in 10 seconds..."
sleep 10
reboot

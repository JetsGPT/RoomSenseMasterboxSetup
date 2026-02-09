#!/bin/bash

# factory_reset.sh
# Removes all changes made by RoomSenseMasterboxSetup install.sh
# Run this as root: sudo ./factory_reset.sh

if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root"
  exit 1
fi

echo "WARNING: This will remove RoomSense services, files, and network configurations."
echo "starting cleanup..."

# 1. Stop and Disable Services
echo "Stopping services..."
systemctl stop roomsense-setup.service wifi-watchdog.timer wifi-watchdog.service docker nginx
systemctl disable roomsense-setup.service wifi-watchdog.timer wifi-watchdog.service

# 2. Docker Swarm & Resource Cleanup
echo "Cleaning up Docker..."

# Remove the stack first (before leaving swarm) to gracefully stop services
docker stack rm roomsense 2>/dev/null || true
echo "Waiting for stack services to drain..."
sleep 10

# Leave Swarm (destroys all stack services and secrets)
docker swarm leave --force 2>/dev/null || true

# Wait for Docker to fully clean up after swarm leave
sleep 5

# Stop all running containers (for non-swarm containers)
if [ -n "$(docker ps -q)" ]; then
    docker stop $(docker ps -q)
fi

# Explicitly remove known named volumes that may survive system prune
# docker system prune --volumes only removes UNUSED volumes, but Swarm volumes
# can be marked as in-use during the cleanup race after swarm leave
echo "Removing Docker volumes explicitly..."
docker volume rm roomsense_pgdata 2>/dev/null || true
docker volume rm roomsense_influxdb_data 2>/dev/null || true
docker volume rm roomsense_npm_data 2>/dev/null || true
docker volume rm roomsense_npm_letsencrypt 2>/dev/null || true
# Also try without stack prefix (in case of naming differences)
docker volume rm pgdata 2>/dev/null || true
docker volume rm influxdb_data 2>/dev/null || true

# Deep Clean: Remove all containers, images, volumes, and networks
# This ensures no old data/code persists
echo "Pruning all Docker resources (volumes, images, networks, build cache)..."
docker system prune -a --volumes -f

# Final check: remove any remaining volumes
echo "Removing any remaining Docker volumes..."
docker volume ls -q 2>/dev/null | xargs -r docker volume rm 2>/dev/null || true

# 3. Remove Service Files
echo "Removing systemd units..."
rm -f /etc/systemd/system/roomsense-setup.service
rm -f /etc/systemd/system/wifi-watchdog.service
rm -f /etc/systemd/system/wifi-watchdog.timer
systemctl daemon-reload
systemctl reset-failed

# 4. Remove Project Files
echo "Removing /opt/roomsense..."
rm -rf /opt/roomsense

# 4. Revert NetworkManager Configurations
echo "Reverting NetworkManager configuration..."
rm -f /etc/NetworkManager/conf.d/dns-servers.conf
rm -f /etc/NetworkManager/dnsmasq-shared.d/roomsense.conf

# Check if we added dns=dnsmasq and remove it
if grep -q "dns=dnsmasq" /etc/NetworkManager/NetworkManager.conf; then
    echo "Removing dns=dnsmasq from NetworkManager.conf..."
    # Create backup
    cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.backup_reset
    # Remove the line
    sed -i '/dns=dnsmasq/d' /etc/NetworkManager/NetworkManager.conf
fi

# 5. Clean up Network Connections
echo "Deleting 'RoomSenseSetup' and other wifi connections..."
# Delete the specific hotspot connection
nmcli connection delete RoomSenseSetup 2>/dev/null || true

# OPTIONAL: Delete all wifi connections to start fresh (Uncomment if desired)
# echo "Deleting all WiFi connections..."
# nmcli --fields UUID,TYPE connection show | grep wifi | awk '{print $1}' | xargs -r nmcli connection delete

# 6. Restart Networking to apply changes
echo "Restarting NetworkManager..."
systemctl restart NetworkManager

# 7. Optional Package Removal (Deep Clean)
# echo "Removing installed packages (docker, nginx, dnsmasq)..."
# apt-get remove -y docker.io nginx dnsmasq
# apt-get autoremove -y

echo "Done! The system is reset relative to the project installation."
echo "You can now run 'sudo ./install.sh' again."

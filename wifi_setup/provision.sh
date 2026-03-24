#!/bin/bash

# RoomSense Provisioning Script
# Triggers after successful WiFi connection or on boot when internet is available.

set -euo pipefail

LOG_FILE="/var/log/roomsense_provision.log"
INSTALL_DIR="/opt/roomsense"
SETUP_DIR="$INSTALL_DIR/wifi_setup"
PROVISIONING_MARKER="$SETUP_DIR/.provisioning"
BACKEND_REPO="https://github.com/JetsGPT/RoomSenseLocalServer.git"
BACKEND_BRANCH="main"
FRONTEND_REPO="https://github.com/JetsGPT/RoomSenseAppReact.git"
FRONTEND_BRANCH="main"
STACK_NAME="roomsense"
PRODUCTION_READY=0

# Redirect stdout/stderr to log
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Starting Provisioning Process..."
date

# Ensure HOME is set for npm/git operations
export HOME="/root"

cleanup() {
    local exit_code=$?

    rm -f "$PROVISIONING_MARKER"

    if [ "$exit_code" -ne 0 ] && [ "$PRODUCTION_READY" -ne 1 ]; then
        echo "Provisioning failed before production became healthy. Restoring setup mode..."
        systemctl stop docker || true
        systemctl stop nginx || true
        systemctl disable nginx || true
        systemctl enable roomsense-setup.service || true
        systemctl restart roomsense-setup.service || true
    fi

    trap - EXIT
    exit "$exit_code"
}
trap cleanup EXIT

wait_for_internet() {
    echo "Waiting for internet connection..."
    while ! ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; do
        echo "Waiting for 8.8.8.8..."
        sleep 5
    done
    echo "Internet connected!"
}

wait_for_docker_daemon() {
    local timeout="${1:-60}"
    local start_time
    start_time=$(date +%s)

    while true; do
        if docker info >/dev/null 2>&1; then
            echo "Docker daemon is ready."
            return 0
        fi

        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            echo "Timed out waiting for Docker daemon to become ready."
            return 1
        fi

        echo "Waiting for Docker daemon to become ready..."
        sleep 2
    done
}

update_repo_to_latest_main() {
    local name="$1"
    local repo_url="$2"
    local branch="$3"
    local target_dir="$4"

    if [ -d "$target_dir/.git" ]; then
        echo "Updating $name..."
        cd "$target_dir"
        git fetch origin "$branch"
        git checkout -B "$branch" "origin/$branch"
        echo "$name updated to latest $branch."
    else
        echo "Cloning $name..."
        git clone --branch "$branch" --single-branch "$repo_url" "$target_dir"
        echo "$name clone complete."
    fi
}

wait_for_stack_removal() {
    local timeout="${1:-120}"
    local start_time
    start_time=$(date +%s)

    while true; do
        if ! docker service ls --format '{{.Name}}' | grep -q "^${STACK_NAME}_"; then
            echo "Old $STACK_NAME stack services have been removed."
            return 0
        fi

        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            echo "Timed out waiting for old $STACK_NAME services to be removed."
            return 1
        fi

        echo "Waiting for old $STACK_NAME services to be removed..."
        sleep 2
    done
}

wait_for_port_release() {
    local port="$1"
    local timeout="${2:-30}"
    local start_time
    start_time=$(date +%s)

    while true; do
        if ! ss -tln | grep -q ":${port} "; then
            echo "Port $port is free."
            return 0
        fi

        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            echo "Timed out waiting for port $port to be released."
            return 1
        fi

        echo "Waiting for port $port to be released..."
        sleep 1
    done
}

wait_for_port_listening() {
    local port="$1"
    local timeout="${2:-60}"
    local start_time
    start_time=$(date +%s)

    while true; do
        if ss -tln | grep -q ":${port} "; then
            echo "Port $port is listening."
            return 0
        fi

        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            echo "Timed out waiting for port $port to listen."
            return 1
        fi

        echo "Waiting for port $port to start listening..."
        sleep 2
    done
}

wait_for_service_replicas() {
    local service_name="$1"
    local timeout="${2:-180}"
    local full_service_name="${STACK_NAME}_${service_name}"
    local start_time
    start_time=$(date +%s)

    while true; do
        local replicas
        replicas=$(docker service ls --filter "name=${full_service_name}" --format '{{.Replicas}}')
        if [ "$replicas" = "1/1" ]; then
            echo "Service $full_service_name is healthy."
            return 0
        fi

        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            echo "Timed out waiting for $full_service_name to become healthy. Current replicas: ${replicas:-missing}"
            return 1
        fi

        echo "Waiting for $full_service_name to become healthy. Current replicas: ${replicas:-missing}"
        sleep 3
    done
}

wait_for_stack_health() {
    wait_for_service_replicas "postgres"
    wait_for_service_replicas "influxdb"
    wait_for_service_replicas "mosquitto"
    wait_for_service_replicas "webserver"
    wait_for_service_replicas "nginx"
    wait_for_port_listening 8081 90
    wait_for_port_listening 443 90
}

wait_for_internet

echo "Setting up repositories in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

update_repo_to_latest_main "Backend" "$BACKEND_REPO" "$BACKEND_BRANCH" "$INSTALL_DIR/backend"
update_repo_to_latest_main "Frontend" "$FRONTEND_REPO" "$FRONTEND_BRANCH" "$INSTALL_DIR/frontend"

DEPLOY_TARGET="$INSTALL_DIR/backend/webserver/src/public"
mkdir -p "$DEPLOY_TARGET"

echo "Building Frontend..."
cd "$INSTALL_DIR/frontend/roomsenseapp"

rm -rf node_modules/.cache dist
echo "Installing npm dependencies..."
npm install --loglevel verbose
echo "Running npm build..."
npm run build
echo "Frontend build complete."

echo "Deploying Frontend to Backend (Express)..."
rm -rf "${DEPLOY_TARGET:?}/"*
cp -r "$INSTALL_DIR/frontend/roomsenseapp/dist/"* "$DEPLOY_TARGET/"
echo "Frontend deployed."

echo "Starting Backend..."
echo "Ensuring Docker is running..."
systemctl start docker
wait_for_docker_daemon

echo "Stopping existing stack to force update..."
docker stack rm "$STACK_NAME" || true
wait_for_stack_removal
wait_for_port_release 8081 30
wait_for_port_release 1883 30
wait_for_port_release 8883 30
wait_for_port_release 9001 30
wait_for_port_release 5432 30
wait_for_port_release 8086 30

echo "Pruning old images to force rebuild..."
docker image prune -a -f || true

echo "Stopping setup service to release port 80..."
systemctl stop roomsense-setup.service || true
wait_for_port_release 80 15

echo "Stopping host nginx to release port 443..."
systemctl stop nginx || true
systemctl disable nginx || true
wait_for_port_release 443 15 || true

cd "$INSTALL_DIR/backend/webserver"

SWARM_STATUS=$(docker info --format '{{.Swarm.LocalNodeState}}')
IS_MANAGER=$(docker info --format '{{.Swarm.ControlAvailable}}')

echo "Docker Swarm Status: $SWARM_STATUS (Manager: $IS_MANAGER)"

WIFI_IFACE=$(nmcli -t -f DEVICE,TYPE device | grep wifi | cut -d: -f1 | head -n1)
if [ -z "$WIFI_IFACE" ]; then
    WIFI_IFACE="wlan0"
fi
echo "Using WiFi interface: $WIFI_IFACE"

if [ "$SWARM_STATUS" = "active" ] && [ "$IS_MANAGER" = "true" ]; then
    echo "Swarm is already initialized and active manager."
elif [ "$SWARM_STATUS" = "active" ] && [ "$IS_MANAGER" != "true" ]; then
    echo "Node is in Swarm but not a manager. Leaving..."
    docker swarm leave --force
    echo "Initializing new Swarm..."
    ADVERTISE_ADDR=$(ip -4 addr show "$WIFI_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$ADVERTISE_ADDR" ]; then
        docker swarm init
    else
        docker swarm init --advertise-addr "$ADVERTISE_ADDR"
    fi
else
    echo "Initializing Docker Swarm..."
    ADVERTISE_ADDR=$(ip -4 addr show "$WIFI_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$ADVERTISE_ADDR" ]; then
        docker swarm init
    else
        docker swarm init --advertise-addr "$ADVERTISE_ADDR"
    fi
fi

chmod +x scripts/init/start.sh
./scripts/init/start.sh
wait_for_stack_health

echo "Transitioning to Production Mode..."
systemctl enable wifi-watchdog.timer
systemctl start wifi-watchdog.timer

PRODUCTION_READY=1

if [ -f "$SETUP_DIR/.provisioned" ]; then
    echo "Update complete. Services restarted."
else
    echo "First time provisioning complete."
    touch "$SETUP_DIR/.provisioned"

    echo "Rebooting in 5 seconds..."
    sleep 5
    nohup /sbin/reboot &
fi

#!/usr/bin/env bash
set -euo pipefail

STACK_DIR=/opt/roomsense/stack
BACKEND_DIR=/opt/roomsense/backend
FRONTEND_DIR=/opt/roomsense/frontend
LOG_DIR=/opt/roomsense/logs
mkdir -p "$STACK_DIR" "$BACKEND_DIR" "$FRONTEND_DIR" "$LOG_DIR"

# Install Docker if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "[deploy] Installing Docker Engine"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$SUDO_USER" || true
fi

# Ensure compose plugin
if ! docker compose version >/dev/null 2>&1; then
  echo "[deploy] Docker Compose plugin missing or old; continuing (Docker script often installs it)"
fi

# Clone or update repositories
if [ ! -d "$BACKEND_DIR/.git" ]; then
  git clone --branch main https://github.com/JetsGPT/RoomSenseLocalServer "$BACKEND_DIR"
else
  git -C "$BACKEND_DIR" fetch --all
  git -C "$BACKEND_DIR" checkout main
  git -C "$BACKEND_DIR" pull --ff-only
fi

if [ ! -d "$FRONTEND_DIR/.git" ]; then
  git clone --branch TN_Frontend https://github.com/JetsGPT/RoomSenseAppReact "$FRONTEND_DIR"
else
  git -C "$FRONTEND_DIR" fetch --all
  git -C "$FRONTEND_DIR" checkout TN_Frontend
  git -C "$FRONTEND_DIR" pull --ff-only
fi

# Write compose file if not exists
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  cat > "$COMPOSE_FILE" <<'YAML'
services:
  roomsense-backend:
    build: ../backend
    container_name: roomsense-backend
    ports:
      - "8080:8080"
    restart: unless-stopped
  roomsense-frontend:
    build: ../frontend
    container_name: roomsense-frontend
    ports:
      - "80:80"
    depends_on:
      - roomsense-backend
    restart: unless-stopped
YAML
fi

# Build and start
( cd "$STACK_DIR" && docker compose up -d --build )

echo "[deploy] Stack deployed"

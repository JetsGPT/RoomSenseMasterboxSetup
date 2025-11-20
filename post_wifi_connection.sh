#!/bin/bash
# Post Wi-Fi Connection Setup
# This script runs after successful Wi-Fi connection to pull and deploy backend/frontend

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/post_wifi_setup.log"
BACKEND_REPO="https://github.com/JetsGPT/RoomSenseLocalServer.git"
FRONTEND_REPO="https://github.com/JetsGPT/RoomSenseAppReact.git"
BACKEND_DIR="/opt/roomsense/backend"
FRONTEND_DIR="/opt/roomsense/frontend"
WEBSERVER_DIR="${BACKEND_DIR}/webserver"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log "Starting post-Wi-Fi connection setup..."

# Wait for internet connectivity
log "Waiting for internet connectivity..."
for i in {1..30}; do
    if ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        log "Internet connectivity confirmed!"
        break
    fi
    if [ $i -eq 30 ]; then
        log "No internet connectivity after 60 seconds. Exiting."
        exit 1
    fi
    sleep 2
done

# Install required packages
log "Installing required packages..."
apt-get update -qq
apt-get install -y -qq git nodejs npm nginx curl

# Install Docker
log "Installing Docker..."
if ! command -v docker > /dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    usermod -aG docker $USER 2>/dev/null || true
fi

# Install Docker Compose
log "Installing Docker Compose..."
if ! docker compose version > /dev/null 2>&1 && ! command -v docker-compose > /dev/null 2>&1; then
    # Docker Compose v2 plugin may not be available, install standalone docker-compose
    log "Installing docker-compose standalone..."
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    if [ -z "${DOCKER_COMPOSE_VERSION}" ]; then
        DOCKER_COMPOSE_VERSION="v2.24.0"  # Fallback version
    fi
    curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
    log "Docker Compose installed"
elif docker compose version > /dev/null 2>&1; then
    log "Docker Compose v2 plugin is available"
else
    log "Docker Compose is already installed"
fi

# Create directories
mkdir -p "${BACKEND_DIR}"
mkdir -p "${FRONTEND_DIR}"

# Clone or update backend
log "Setting up backend..."
if [ -d "${BACKEND_DIR}/.git" ]; then
    log "Backend repository exists. Updating..."
    cd "${BACKEND_DIR}"
    git pull origin ble-discovery-pi || true
else
    log "Cloning backend repository..."
    git clone -b ble-discovery-pi "${BACKEND_REPO}" "${BACKEND_DIR}" || {
        log "Failed to clone backend repository"
        exit 1
    }
fi

# Navigate to webserver directory
if [ -d "${WEBSERVER_DIR}" ]; then
    cd "${WEBSERVER_DIR}"
    
    # Check for compose.yaml or docker-compose.yml
    COMPOSE_FILE=""
    if [ -f "compose.yaml" ]; then
        COMPOSE_FILE="compose.yaml"
    elif [ -f "docker-compose.yml" ]; then
        COMPOSE_FILE="docker-compose.yml"
    elif [ -f "docker-compose.yaml" ]; then
        COMPOSE_FILE="docker-compose.yaml"
    fi
    
    if [ -n "${COMPOSE_FILE}" ]; then
        log "Found ${COMPOSE_FILE}, deploying with Docker Compose..."
        
        # Stop any existing containers
        log "Stopping existing containers..."
        docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || docker-compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
        
        # Pull latest images and build
        log "Building and starting containers..."
        if docker compose version > /dev/null 2>&1; then
            # Use Docker Compose v2 (plugin)
            docker compose -f "${COMPOSE_FILE}" up -d --build
        else
            # Fall back to docker-compose v1
            docker-compose -f "${COMPOSE_FILE}" up -d --build
        fi
        
        # Wait a moment for containers to start
        sleep 5
        
        # Verify containers are running
        if docker compose -f "${COMPOSE_FILE}" ps | grep -q "Up" || docker-compose -f "${COMPOSE_FILE}" ps | grep -q "Up"; then
            log "Backend containers started successfully!"
        else
            log "Warning: Containers may not have started properly. Check logs with: docker compose logs"
        fi
        
        # Create systemd service to manage docker-compose on boot
        log "Setting up systemd service for Docker Compose..."
        cat > /etc/systemd/system/roomsense-backend.service <<EOF
[Unit]
Description=RoomSense Backend Server (Docker Compose)
After=docker.service network.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${WEBSERVER_DIR}
ExecStart=/bin/bash -c 'if command -v docker > /dev/null && docker compose version > /dev/null 2>&1; then docker compose -f ${COMPOSE_FILE} up -d; elif command -v docker-compose > /dev/null; then docker-compose -f ${COMPOSE_FILE} up -d; fi'
ExecStop=/bin/bash -c 'if command -v docker > /dev/null && docker compose version > /dev/null 2>&1; then docker compose -f ${COMPOSE_FILE} down; elif command -v docker-compose > /dev/null; then docker-compose -f ${COMPOSE_FILE} down; fi'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable roomsense-backend.service
        
        log "Backend service configured to start on boot!"
    else
        log "Warning: No compose.yaml or docker-compose.yml found in ${WEBSERVER_DIR}"
        log "Expected files: compose.yaml, docker-compose.yml, or docker-compose.yaml"
    fi
else
    log "Warning: webserver directory not found in backend repository"
fi

# Clone or update frontend
log "Setting up frontend..."
if [ -d "${FRONTEND_DIR}/.git" ]; then
    log "Frontend repository exists. Updating..."
    cd "${FRONTEND_DIR}"
    git pull origin main || git pull origin master || true
else
    log "Cloning frontend repository..."
    git clone "${FRONTEND_REPO}" "${FRONTEND_DIR}" || {
        log "Failed to clone frontend repository"
        exit 1
    }
fi

# Build and serve frontend
if [ -d "${FRONTEND_DIR}" ]; then
    cd "${FRONTEND_DIR}"
    
    # Install Node.js dependencies
    log "Installing frontend dependencies..."
    if [ -f "package.json" ]; then
        npm install --silent
        
        # Build the React app
        log "Building React application..."
        npm run build || {
            log "Build failed, trying alternative build command..."
            npm run build:prod || npm run dist || true
        }
        
        # Configure nginx to serve the frontend
        log "Configuring nginx..."
        cat > /etc/nginx/sites-available/roomsense <<EOF
server {
    listen 80;
    server_name _;
    
    root ${FRONTEND_DIR}/build;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    location /api {
        proxy_pass http://localhost:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

        ln -sf /etc/nginx/sites-available/roomsense /etc/nginx/sites-enabled/
        rm -f /etc/nginx/sites-enabled/default
        
        systemctl restart nginx
        log "Frontend served via nginx!"
    else
        log "Warning: package.json not found in frontend directory"
    fi
fi

# Get current IP address
IP_ADDR=$(hostname -I | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then
    IP_ADDR="localhost"
fi

log "Post-Wi-Fi setup complete!"
log "===================================================="
log "RoomSense is running!"
log "Backend: http://${IP_ADDR}:5000"
log "Frontend: http://${IP_ADDR}"
log "===================================================="

# Try to display to console users
echo -e "\n\n${GREEN}RoomSense Setup Complete!${NC}" > /dev/tty1 2>/dev/null || true
echo -e "${YELLOW}Access RoomSense at: http://${IP_ADDR}${NC}\n" > /dev/tty1 2>/dev/null || true


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
apt-get install -y -qq git nodejs npm python3 python3-pip python3-venv nginx

# Create directories
mkdir -p "${BACKEND_DIR}"
mkdir -p "${FRONTEND_DIR}"

# Clone or update backend
log "Setting up backend..."
if [ -d "${BACKEND_DIR}/.git" ]; then
    log "Backend repository exists. Updating..."
    cd "${BACKEND_DIR}"
    git pull origin main || git pull origin master || true
else
    log "Cloning backend repository..."
    git clone "${BACKEND_REPO}" "${BACKEND_DIR}" || {
        log "Failed to clone backend repository"
        exit 1
    }
fi

# Navigate to webserver directory
if [ -d "${WEBSERVER_DIR}" ]; then
    cd "${WEBSERVER_DIR}"
    
    # Install Python dependencies
    log "Installing backend dependencies..."
    if [ -f "requirements.txt" ]; then
        python3 -m pip install -r requirements.txt --quiet
    else
        # Try to install common dependencies
        python3 -m pip install flask flask-cors gunicorn --quiet || true
    fi
    
    # Set up backend service
    log "Setting up backend service..."
    
    # Try to find the main app file
    APP_FILE="app.py"
    if [ ! -f "${WEBSERVER_DIR}/${APP_FILE}" ]; then
        # Try alternative names
        if [ -f "${WEBSERVER_DIR}/main.py" ]; then
            APP_FILE="main.py"
        elif [ -f "${WEBSERVER_DIR}/server.py" ]; then
            APP_FILE="server.py"
        elif [ -f "${WEBSERVER_DIR}/wsgi.py" ]; then
            APP_FILE="wsgi.py"
        fi
    fi
    
    # Check if gunicorn is available, otherwise use flask directly
    if command -v gunicorn > /dev/null 2>&1; then
        EXEC_START="/usr/bin/python3 -m gunicorn -w 4 -b 0.0.0.0:5000 ${APP_FILE%.py}:app"
    else
        EXEC_START="/usr/bin/python3 ${WEBSERVER_DIR}/${APP_FILE}"
    fi
    
    cat > /etc/systemd/system/roomsense-backend.service <<EOF
[Unit]
Description=RoomSense Backend Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WEBSERVER_DIR}
ExecStart=${EXEC_START}
Restart=always
RestartSec=10
Environment="FLASK_APP=${APP_FILE}"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable roomsense-backend.service
    systemctl restart roomsense-backend.service
    
    log "Backend service started!"
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

log "Post-Wi-Fi setup complete!"
log "Backend: http://localhost:5000"
log "Frontend: http://localhost"


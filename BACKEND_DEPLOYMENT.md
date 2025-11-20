# Backend Deployment Explanation

## Overview

The backend is automatically deployed after the Raspberry Pi successfully connects to Wi-Fi. The deployment process is handled by `post_wifi_connection.sh`, which runs in the background after Wi-Fi connection is established. **The backend is deployed using Docker Compose**, which provides containerized, isolated deployment.

## Deployment Flow

```
Wi-Fi Connected
    ↓
check_wifi_setup.sh detects connection
    ↓
post_wifi_connection.sh starts (background process)
    ↓
1. Wait for Internet connectivity
    ↓
2. Install system dependencies (Docker, Docker Compose)
    ↓
3. Clone/Update backend repository
    ↓
4. Navigate to webserver directory
    ↓
5. Detect compose.yaml or docker-compose.yml
    ↓
6. Build and start Docker containers
    ↓
7. Create systemd service for auto-start
    ↓
8. Enable service for boot
```

## Step-by-Step Process

### 1. **Internet Connectivity Check** (Lines 27-39)
```bash
# Pings Google DNS (8.8.8.8) up to 30 times
# Waits up to 60 seconds for internet connection
# Exits if no connectivity after timeout
```

### 2. **System Dependencies Installation** (Lines 41-67)
```bash
apt-get install -y git nodejs npm nginx curl
```

Then installs:
- **Docker**: Using official Docker installation script
- **Docker Compose**: Either v2 plugin (if available) or standalone v1
- **git** - For cloning repositories
- **nodejs**, **npm** - For frontend build
- **nginx** - Web server for frontend
- **curl** - For downloading Docker installation script

### 3. **Repository Management** (Lines 50-62)
```bash
BACKEND_DIR="/opt/roomsense/backend"
WEBSERVER_DIR="${BACKEND_DIR}/webserver"
BACKEND_REPO="https://github.com/JetsGPT/RoomSenseLocalServer.git"
```

**If repository exists:**
- Runs `git pull` to update to latest code
- Tries both `main` and `master` branches

**If repository doesn't exist:**
- Clones the entire repository to `/opt/roomsense/backend`
- Navigates to `webserver` subdirectory

### 4. **Docker Compose File Detection** (Lines 96-104)
The script looks for Docker Compose configuration files in this order:
1. `compose.yaml` (newer standard)
2. `docker-compose.yml` (traditional)
3. `docker-compose.yaml` (alternative)

### 5. **Container Deployment** (Lines 106-131)
```bash
# Stop any existing containers
docker compose down  # or docker-compose down

# Build and start containers
docker compose up -d --build  # or docker-compose up -d --build
```

**Docker Compose advantages:**
- **Isolation**: Backend runs in isolated container
- **Dependencies**: All dependencies defined in Dockerfile
- **Consistency**: Same environment across all deployments
- **Multi-service**: Can run multiple services (database, cache, etc.)
- **Easy updates**: Just rebuild containers
- **Portability**: Works the same on any Docker host

**The script supports both:**
- Docker Compose v2 (plugin): `docker compose`
- Docker Compose v1 (standalone): `docker-compose`

### 6. **Systemd Service Creation** (Lines 133-150)
Creates `/etc/systemd/system/roomsense-backend.service`:

```ini
[Unit]
Description=RoomSense Backend Server (Docker Compose)
After=docker.service network.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/roomsense/backend/webserver
ExecStart=/bin/bash -c 'docker compose -f compose.yaml up -d'
ExecStop=/bin/bash -c 'docker compose -f compose.yaml down'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Key features:**
- **After=docker.service**: Waits for Docker to be ready
- **Type=oneshot**: Runs once, then systemd tracks the containers
- **RemainAfterExit=yes**: Service stays active after containers start
- **ExecStart/ExecStop**: Manages docker-compose lifecycle
- **Restart=on-failure**: Restarts if docker-compose command fails

### 7. **Service Activation** (Lines 152-154)
```bash
systemctl daemon-reload    # Reload systemd to recognize new service
systemctl enable ...       # Enable service to start on boot
# Service will start containers automatically on boot
```

## Backend Service Details

### **Location**
- **Code**: `/opt/roomsense/backend/webserver/`
- **Compose File**: `/opt/roomsense/backend/webserver/compose.yaml` (or docker-compose.yml)
- **Service File**: `/etc/systemd/system/roomsense-backend.service`
- **Container Logs**: `docker compose logs` or `docker-compose logs`
- **Systemd Logs**: `journalctl -u roomsense-backend.service`

### **Network Configuration**
- **Port**: Defined in `compose.yaml` (typically `5000`)
- **Bind Address**: Configured in Docker Compose file
- **Container Network**: Managed by Docker Compose

### **Access**
- **Local**: `http://localhost:5000`
- **Network**: `http://<pi-ip-address>:5000`
- **Via Nginx**: `http://<pi-ip-address>/api` (proxied to backend)

## Nginx Integration

The frontend deployment also configures Nginx to proxy API requests:

```nginx
location /api {
    proxy_pass http://localhost:5000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_cache_bypass $http_upgrade;
}
```

This allows the frontend to make API calls to `/api/*` which are automatically forwarded to the backend on port 5000.

## Monitoring & Management

### **Check Service Status**
```bash
# Check systemd service
sudo systemctl status roomsense-backend

# Check Docker containers
cd /opt/roomsense/backend/webserver
docker compose ps  # or docker-compose ps
```

### **View Logs**
```bash
# Container logs (application logs)
cd /opt/roomsense/backend/webserver
docker compose logs -f  # or docker-compose logs -f

# Systemd service logs
sudo journalctl -u roomsense-backend -n 50
sudo journalctl -u roomsense-backend -f
```

### **Restart Service**
```bash
# Restart via systemd
sudo systemctl restart roomsense-backend

# Or restart containers directly
cd /opt/roomsense/backend/webserver
docker compose restart  # or docker-compose restart
```

### **Stop Service**
```bash
# Stop via systemd
sudo systemctl stop roomsense-backend

# Or stop containers directly
cd /opt/roomsense/backend/webserver
docker compose down  # or docker-compose down
```

### **Disable Auto-Start**
```bash
sudo systemctl disable roomsense-backend
```

## Update Process

The backend automatically updates on each Wi-Fi connection:

1. Script checks if repository exists
2. If exists: `git pull` to get latest changes
3. Rebuilds Docker containers with `docker compose up -d --build`
4. Containers are restarted with new code

**Manual Update:**
```bash
cd /opt/roomsense/backend
git pull
cd webserver
docker compose up -d --build  # or docker-compose up -d --build
```

**Note**: Docker will rebuild images if Dockerfile or dependencies changed, and restart containers automatically.

## Error Handling

The script includes error handling for:
- **No internet**: Exits gracefully after timeout
- **Clone failure**: Logs error and exits
- **Missing webserver directory**: Logs warning, continues with frontend
- **Missing compose file**: Logs warning, skips backend deployment
- **Docker not installed**: Installs Docker automatically
- **Docker Compose unavailable**: Installs docker-compose standalone
- **Container build failure**: Logs error, but doesn't crash script

## Customization

### **Change Backend Repository**
Edit `post_wifi_connection.sh`:
```bash
BACKEND_REPO="https://github.com/YourOrg/YourRepo.git"
```

### **Change Port**
Edit the `compose.yaml` or `docker-compose.yml` file in the backend repository:
```yaml
services:
  backend:
    ports:
      - "8080:5000"  # Change host port from 5000 to 8080
```

### **Modify Container Configuration**
Edit the `compose.yaml` or `docker-compose.yml` file in the backend repository. Common changes:
- Environment variables
- Volume mounts
- Network configuration
- Resource limits
- Health checks

### **Use Different Compose File**
The script automatically detects `compose.yaml`, `docker-compose.yml`, or `docker-compose.yaml`. To use a custom file, modify the detection logic in `post_wifi_connection.sh`.

## Troubleshooting

### **Backend not starting**
1. Check container status: `cd /opt/roomsense/backend/webserver && docker compose ps`
2. Check container logs: `docker compose logs`
3. Check systemd service: `sudo systemctl status roomsense-backend`
4. Verify compose file exists: `ls /opt/roomsense/backend/webserver/compose.yaml`

### **Port already in use**
```bash
# Find what's using the port
sudo netstat -tulpn | grep :5000

# Stop the conflicting service or change port in compose.yaml
cd /opt/roomsense/backend/webserver
docker compose down
# Edit compose.yaml to change port
docker compose up -d
```

### **Docker not running**
```bash
# Check Docker status
sudo systemctl status docker

# Start Docker
sudo systemctl start docker
sudo systemctl enable docker
```

### **Container build fails**
```bash
cd /opt/roomsense/backend/webserver
docker compose build --no-cache  # Rebuild from scratch
docker compose logs  # Check for build errors
```

### **Service keeps restarting**
Check logs for errors:
```bash
# Container logs
cd /opt/roomsense/backend/webserver
docker compose logs -f

# Systemd logs
sudo journalctl -u roomsense-backend -n 100
```

### **Docker Compose command not found**
The script should install it automatically, but if needed:
```bash
# Install Docker Compose v2 (if Docker is installed)
# Or install standalone:
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```


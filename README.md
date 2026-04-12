# RoomSense Masterbox Setup

WiFi provisioning and device setup system for the RoomSense smart device ecosystem. Handles initial network configuration, automated deployment of the full RoomSense application stack, and self-healing connectivity monitoring.

## How It Works

1. **Setup Mode** — The device boots into a WiFi hotspot ("RoomSenseSetup") and serves a captive portal on `http://10.42.0.1/`
2. **WiFi Configuration** — Users connect to the hotspot, select their home WiFi network, and enter credentials
3. **Provisioning** — Once internet is verified, the system automatically clones, builds, and deploys the RoomSense backend and frontend via Docker Swarm
4. **Monitoring** — A watchdog service continuously monitors connectivity and restores setup mode if the connection is lost

## Project Structure

```
├── install.sh                    # Main installation script (run as root)
├── factory_reset.sh              # Full cleanup / factory reset
└── wifi_setup/
    ├── app.py                    # Flask web app (setup portal)
    ├── network_manager.py        # NetworkManager wrapper (scan, connect, AP)
    ├── provision.sh              # Deploys backend + frontend via Docker Swarm
    ├── wifi_watchdog.sh          # Connectivity monitor (runs every 2 min)
    ├── dnsmasq.conf              # Captive portal DNS config
    ├── roomsense-setup.service   # Systemd service for setup portal
    ├── roomsense-provision.service # Systemd service for provisioning
    └── templates/
        └── index.html            # Setup portal web UI
```

## Tech Stack

- **Backend**: Python 3 / Flask
- **System**: Bash, systemd, NetworkManager, dnsmasq
- **Deployment**: Docker & Docker Swarm
- **Frontend**: HTML / CSS / JavaScript (captive portal UI)
- **Target OS**: Linux (Debian/Ubuntu-based)

## Installation

```bash
sudo ./install.sh
```

This installs all dependencies (Python 3, NetworkManager, dnsmasq, Node.js, Docker, nginx, etc.), configures networking, registers systemd services, and reboots into setup mode.

### First Boot

1. Connect to the **RoomSenseSetup** WiFi hotspot from your phone or computer
2. The captive portal opens automatically (or navigate to `http://10.42.0.1/`)
3. Select your home WiFi network and enter the password
4. The device connects, validates internet, and begins provisioning
5. The device reboots once provisioning is complete

### Subsequent Boots

- Connects to saved WiFi automatically
- Provisioning checks for updates on each boot
- Watchdog monitors connectivity every 2 minutes

## Factory Reset

```bash
sudo ./factory_reset.sh
```

Stops all services, removes Docker containers/images/volumes, deletes `/opt/roomsense/`, reverts NetworkManager config, and clears saved WiFi connections.

## Key Features

- **Captive Portal** — Redirects all DNS to the local setup page for seamless onboarding
- **Self-Healing** — Watchdog restores setup hotspot if internet connection is lost
- **Automated Updates** — Pulls latest code from upstream repos on each provisioning run
- **Graceful Degradation** — Falls back to AP mode if connection or provisioning fails
- **Full Stack Deployment** — Provisions PostgreSQL, InfluxDB, Mosquitto, web server, and nginx via Docker Swarm

## API Endpoints (Setup Portal)

| Endpoint | Method | Description |
|---|---|---|
| `/` | GET | Setup portal UI |
| `/api/scan` | GET | List available WiFi networks |
| `/api/connect` | POST | Connect to a WiFi network |
| `/api/status` | GET | Check connection/provisioning status |

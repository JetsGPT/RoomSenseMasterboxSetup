# System Architecture

## Overview

The RoomSense Pi Onboarding system provides an automated Wi-Fi configuration flow that mimics commercial captive portal systems (like airport/hotel Wi-Fi).

## Flow Diagram

```
Boot → check_wifi_setup.sh
         │
         ├─→ Wi-Fi Credentials Exist?
         │   │
         │   ├─→ YES → Connect to Wi-Fi
         │   │          │
         │   │          └─→ post_wifi_connection.sh
         │   │                │
         │   │                ├─→ Clone/Pull Backend
         │   │                ├─→ Deploy Backend Service
         │   │                ├─→ Clone/Pull Frontend
         │   │                └─→ Build & Serve Frontend
         │   │
         │   └─→ NO → start_access_point.sh
         │              │
         │              ├─→ Configure hostapd (AP)
         │              ├─→ Configure dnsmasq (DHCP/DNS)
         │              └─→ Start captive_portal.py
         │                    │
         │                    └─→ User connects → Redirected to portal
         │                          │
         │                          └─→ Select SSID + Password
         │                                │
         │                                └─→ Write to wpa_supplicant.conf
         │                                      │
         │                                      └─→ Reboot
```

## Components

### 1. Boot Check (`check_wifi_setup.sh`)
- **Purpose**: Determines if Wi-Fi is configured
- **Location**: Runs via systemd service on boot
- **Actions**:
  - Checks `/etc/wpa_supplicant/wpa_supplicant.conf` for network entries
  - If found: Attempts Wi-Fi connection, then triggers post-connection setup
  - If not found: Starts access point mode

### 2. Access Point Setup (`setup_access_point.sh`)
- **Purpose**: One-time configuration of AP infrastructure
- **Dependencies**: `hostapd`, `dnsmasq`
- **Configuration**:
  - SSID: `RoomSense-Setup`
  - Password: `roomsense123`
  - IP: `192.168.4.1`
  - DHCP Range: `192.168.4.2-192.168.4.20`

### 3. Access Point Starter (`start_access_point.sh`)
- **Purpose**: Activates AP and captive portal
- **Actions**:
  - Stops normal Wi-Fi services
  - Configures static IP on `wlan0`
  - Starts `hostapd` and `dnsmasq`
  - Launches `captive_portal.py` web server

### 4. Captive Portal (`captive_portal.py`)
- **Purpose**: Web server providing Wi-Fi configuration UI
- **Technology**: Python Flask
- **Port**: 80 (requires root)
- **Endpoints**:
  - `/` - Main configuration page
  - `/api/networks` - List available Wi-Fi networks
  - `/api/connect` - Save Wi-Fi credentials
  - `/api/reboot` - Reboot system
  - `/generate_204` - Android captive portal detection
  - `/hotspot-detect.html` - iOS captive portal detection
  - `/connecttest.txt` - Windows captive portal detection

### 5. Post-Connection Setup (`post_wifi_connection.sh`)
- **Purpose**: Deploy backend and frontend after Wi-Fi connection
- **Actions**:
  1. Wait for internet connectivity
  2. Install dependencies (git, nodejs, nginx, python packages)
  3. Clone/update backend repository
  4. Install backend dependencies
  5. Create systemd service for backend
  6. Clone/update frontend repository
  7. Build React application
  8. Configure nginx to serve frontend

## File Locations

### Configuration Files
- `/etc/hostapd/hostapd.conf` - Access point configuration
- `/etc/dnsmasq.conf` - DHCP/DNS configuration
- `/etc/wpa_supplicant/wpa_supplicant.conf` - Wi-Fi credentials
- `/etc/systemd/system/roomsense-wifi-setup.service` - Boot service
- `/etc/systemd/system/roomsense-backend.service` - Backend service

### Application Directories
- `/opt/roomsense/backend/` - Backend repository
- `/opt/roomsense/frontend/` - Frontend repository

### Log Files
- `/var/log/wifi_setup.log` - Wi-Fi setup process
- `/var/log/post_wifi_setup.log` - Deployment process
- `/var/log/captive_portal.log` - Captive portal server

## Network Architecture

### Access Point Mode
```
Internet (if eth0 connected)
    │
    └─→ NAT (iptables)
        │
        └─→ wlan0 (192.168.4.1)
            │
            └─→ DHCP Clients (192.168.4.2-20)
                │
                └─→ Captive Portal (port 80)
```

### Normal Wi-Fi Mode
```
Wi-Fi Router
    │
    └─→ wlan0 (DHCP)
        │
        ├─→ Backend Service (port 5000)
        └─→ Nginx (port 80)
            │
            └─→ Frontend (React App)
```

## Security Considerations

1. **Access Point Password**: Default password should be changed for production
2. **Wi-Fi Credentials**: Stored in `/etc/wpa_supplicant/wpa_supplicant.conf` with 600 permissions
3. **Root Privileges**: Required for:
   - Port 80 binding
   - Network configuration
   - System reboot
4. **Network Isolation**: AP mode isolates setup traffic from main network

## Dependencies

### System Packages
- `hostapd` - Access point daemon
- `dnsmasq` - DHCP/DNS server
- `python3`, `python3-pip`, `python3-flask` - Captive portal
- `git` - Repository cloning
- `nodejs`, `npm` - Frontend build
- `nginx` - Web server
- `iw` - Wi-Fi scanning

### Python Packages
- `flask` - Web framework

## Troubleshooting Points

1. **AP not appearing**: Check `hostapd` service and interface status
2. **Portal not loading**: Verify Flask server is running on port 80
3. **Wi-Fi not connecting**: Check credentials format in wpa_supplicant.conf
4. **Deployment failing**: Verify internet connectivity and repository access
5. **Backend not starting**: Check for correct app file name and dependencies

## Customization

### Change AP Credentials
Edit `setup_access_point.sh`:
- `AP_SSID`
- `AP_PASSWORD`

### Change Portal Appearance
Edit `templates/index.html`

### Change Repositories
Edit `post_wifi_connection.sh`:
- `BACKEND_REPO`
- `FRONTEND_REPO`

### Change Service Ports
Edit `post_wifi_connection.sh`:
- Backend port (default: 5000)
- Nginx port (default: 80)


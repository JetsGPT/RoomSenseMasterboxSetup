# Quick Start Guide

## Installation (5 minutes)

1. **Clone and install:**
   ```bash
   git clone <repository-url>
   cd RoomSenseMasterboxSetup
   sudo ./install.sh
   ```
   
   The install script will:
   - Clear existing Wi-Fi credentials (backed up first)
   - Set up the onboarding system
   - Automatically reboot after 5 seconds

2. **Connect to the access point:**
   - Look for Wi-Fi network: **RoomSense-Setup**
   - Security: **Open (No Password)**
   - Connect from your phone/laptop

3. **Configure Wi-Fi:**
   - You'll be automatically redirected to the setup page
   - Select your Wi-Fi network
   - Enter password
   - Click "Connect"
   - The Pi will reboot and connect to your network

5. **Automatic deployment:**
   - After connecting, the Pi automatically:
     - Pulls the backend from GitHub
     - Deploys the backend service
     - Pulls the frontend from GitHub
     - Builds and serves the React app
   - This happens automatically in the background (check logs if needed)

## Access Your Application

Once deployed, access:
- **Frontend**: `http://<pi-ip-address>` (or `http://raspberrypi.local`)
- **Backend API**: `http://<pi-ip-address>:5000`

## Troubleshooting

### Can't see the access point
```bash
sudo systemctl status hostapd
sudo journalctl -u hostapd
```

### Captive portal not loading
```bash
sudo tail -f /var/log/captive_portal.log
ps aux | grep captive_portal
```

### Check deployment status
```bash
sudo tail -f /var/log/post_wifi_setup.log
sudo systemctl status roomsense-backend
```

### Manual AP start
```bash
sudo ./start_access_point.sh
```

### Reset and start over
```bash
sudo rm /etc/wpa_supplicant/wpa_supplicant.conf
sudo reboot
```

## Next Steps

- Change the default AP password in `setup_access_point.sh`
- Customize the captive portal page in `templates/index.html`
- Configure backend/frontend repositories if different


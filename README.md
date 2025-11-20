# RoomSense Raspberry Pi Onboarding System

An automated Wi-Fi onboarding system for Raspberry Pi that provides a captive portal interface for easy network configuration, similar to airport or hotel Wi-Fi systems.

## Features

- **Automatic Access Point**: When no Wi-Fi credentials exist, the Pi automatically creates a hotspot
- **Captive Portal**: Users are automatically redirected to the setup page when connecting
- **Network Scanning**: Displays all available nearby Wi-Fi networks with signal strength
- **Secure Configuration**: Saves Wi-Fi credentials securely to the system
- **Auto-Deployment**: After connecting to Wi-Fi, automatically pulls and deploys:
  - Backend from [RoomSenseLocalServer/webserver](https://github.com/JetsGPT/RoomSenseLocalServer/tree/main/webserver)
  - Frontend from [RoomSenseAppReact](https://github.com/JetsGPT/RoomSenseAppReact)

## Installation

1. Clone this repository to your Raspberry Pi:
```bash
git clone <this-repo-url>
cd RoomSenseMasterboxSetup
```

2. Run the installation script (it will automatically clear Wi-Fi credentials and reboot):
```bash
sudo ./install.sh
```

**Note**: The install script will:
- Clear any existing Wi-Fi credentials (backed up first)
- Set up the onboarding system
- Automatically reboot after 5 seconds
- On reboot, the Pi will start the access point since no Wi-Fi is configured

## How It Works

### First Boot (No Wi-Fi Configured)

1. On boot, the system checks for existing Wi-Fi credentials
2. If none are found, it automatically:
   - Configures `hostapd` to create an access point
   - Sets up `dnsmasq` for DHCP and DNS
   - Starts the captive portal web server
3. The access point appears as **"RoomSense-Setup"** (password: `roomsense123`)
4. When users connect, they're automatically redirected to the setup page
5. Users select their Wi-Fi network and enter the password
6. The system saves credentials and reboots

### After Wi-Fi Configuration

1. On boot, the system detects Wi-Fi credentials
2. Connects to the configured network
3. Once connected, automatically:
   - Clones/updates the backend repository
   - Installs backend dependencies
   - Starts the backend service
   - Clones/updates the frontend repository
   - Builds the React application
   - Configures nginx to serve the frontend
4. The RoomSense application is now accessible on the local network

## Access Point Details

- **SSID**: `RoomSense-Setup`
- **Password**: `roomsense123`
- **IP Address**: `192.168.4.1`
- **DHCP Range**: `192.168.4.2` - `192.168.4.20`

## Manual Operations

### Start Access Point Manually
```bash
sudo ./start_access_point.sh
```

### Check Wi-Fi Setup Status
```bash
sudo ./check_wifi_setup.sh
```

### View Logs
```bash
# Wi-Fi setup logs
sudo tail -f /var/log/wifi_setup.log

# Post-connection setup logs
sudo tail -f /var/log/post_wifi_setup.log

# Captive portal logs
sudo tail -f /var/log/captive_portal.log
```

## File Structure

```
.
├── captive_portal.py          # Flask web server for captive portal
├── templates/
│   └── index.html             # Captive portal web interface
├── setup_access_point.sh      # Initial AP configuration
├── start_access_point.sh      # Start AP and captive portal
├── check_wifi_setup.sh        # Boot-time Wi-Fi check
├── post_wifi_connection.sh    # Post-connection deployment
├── install.sh                 # Installation script
└── README.md                  # This file
```

## Requirements

- Raspberry Pi (any model with Wi-Fi)
- Raspberry Pi OS (or compatible Linux distribution)
- Internet connection (for initial package installation)

## Troubleshooting

### Access Point Not Appearing
- Check if `hostapd` is running: `sudo systemctl status hostapd`
- Verify interface: `ip link show wlan0`
- Check logs: `sudo journalctl -u hostapd`

### Captive Portal Not Loading
- Check if Flask server is running: `ps aux | grep captive_portal`
- Verify port 80 is not in use: `sudo netstat -tulpn | grep :80`
- Check logs: `sudo tail -f /var/log/captive_portal.log`

### Wi-Fi Connection Fails
- Verify credentials in `/etc/wpa_supplicant/wpa_supplicant.conf`
- Check Wi-Fi status: `sudo wpa_cli status`
- Restart networking: `sudo systemctl restart wpa_supplicant`

### Backend/Frontend Not Deploying
- Check internet connectivity: `ping 8.8.8.8`
- Verify repositories are accessible
- Check logs: `sudo tail -f /var/log/post_wifi_setup.log`

## Security Notes

- The default AP password should be changed for production use
- Wi-Fi credentials are stored in `/etc/wpa_supplicant/wpa_supplicant.conf` with restricted permissions
- Consider implementing HTTPS for the captive portal in production environments

## License

[Add your license here]

## Support

For issues or questions, please open an issue in the repository.


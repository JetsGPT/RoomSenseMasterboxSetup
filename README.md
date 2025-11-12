# RoomSense Masterbox Setup (Raspberry Pi 5, Raspberry Pi OS Lite)

This repository contains scripts and units to enable a first-boot hotspot with a captive-portal-like Wi‑Fi setup page and then deploy the RoomSense backend and frontend in Docker containers.

Defaults
- Country code: AT
- Hotspot SSID: RoomSense-Setup
- Hotspot password: roomsense123
- Backend: JetsGPT/RoomSenseLocalServer (branch: main)
- Frontend: JetsGPT/RoomSenseAppReact (branch: TN_Frontend)

## What it does
1. On first boot, checks internet connectivity.
2. If offline, starts a Wi‑Fi hotspot + captive-portal page to collect SSID/password.
3. On successful connection, reboots.
4. With internet, installs Docker, clones repos, and starts containers.

## Install on the Pi
1. Copy this repo to the Pi (e.g., /home/pi/RoomSenseMasterboxSetup).
2. Run prerequisites installer (as root):
   ```bash
   sudo bash scripts/install_prereqs.sh
   ```
3. Install systemd units and enable first boot:
   ```bash
   sudo bash scripts/install_systemd.sh
   ```
4. Reboot to start the flow:
   ```bash
   sudo reboot
   ```

## Files
- scripts/*.sh: helper scripts for AP, portal, Wi‑Fi connect, deploy
- systemd/*.service, *.target: boot logic
- portal/: Flask app + static UI
- config/: dnsmasq config
- docker/docker-compose.yml: reference compose file (deployment script will generate a runnable copy under /opt/roomsense/stack)

## Notes
- Raspberry Pi OS Bookworm uses NetworkManager. Scripts auto-detect and use `nmcli`. Fallback to legacy tools when needed.
- HTTPS captive portals are not possible; the portal works by DNS hijack and HTTP interception.
- If connection fails, the device falls back to the hotspot on next boot.

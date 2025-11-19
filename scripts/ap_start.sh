#!/usr/bin/env bash
set -euo pipefail

SSID=${SSID:-RoomSense-Setup}
PSK=${PSK:-roomsense123}
COUNTRY=${COUNTRY:-AT}

LOG_DIR=/opt/roomsense/logs
mkdir -p "$LOG_DIR"

# Wait for NetworkManager to be ready if it exists
if command -v nmcli >/dev/null 2>&1; then
  echo "[ap_start] Waiting for NetworkManager to be ready..."
  for i in {1..30}; do
    if nmcli -t -f STATE general status 2>/dev/null | grep -q "connected\|disconnected"; then
      echo "[ap_start] NetworkManager is ready"
      break
    fi
    if [ $i -eq 30 ]; then
      echo "[ap_start] WARNING: NetworkManager not ready after 30 seconds" >&2
    fi
    sleep 1
  done
fi

# Detect Wi-Fi interface automatically with multiple methods
WIFI_IF=${WIFI_IF:-}
if [ -z "${WIFI_IF}" ]; then
  # Try iw first
  WIFI_IF=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
fi
if [ -z "${WIFI_IF}" ] && command -v nmcli >/dev/null 2>&1; then
  # Try NetworkManager
  WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}')
fi
if [ -z "${WIFI_IF}" ]; then
  # Try /sys/class/net
  WIFI_IF=$(ls /sys/class/net/ | grep -E '^wlan[0-9]+$' | head -n1)
fi
if [ -z "${WIFI_IF}" ]; then
  # Last resort: default
  WIFI_IF=wlan0
  echo "[ap_start] WARNING: Could not detect Wi-Fi interface, using default: $WIFI_IF" >&2
else
  echo "[ap_start] Detected Wi-Fi interface: $WIFI_IF"
fi

# Verify interface exists
if [ ! -e "/sys/class/net/$WIFI_IF" ]; then
  echo "[ap_start] ERROR: Wi-Fi interface $WIFI_IF does not exist!" >&2
  exit 1
fi

# Set regulatory domain
sudo iw reg set "$COUNTRY" 2>/dev/null || true

if command -v nmcli >/dev/null 2>&1; then
  echo "[ap_start] Using NetworkManager to start hotspot on $WIFI_IF"
  
  # Disconnect any existing connections on this interface
  nmcli dev disconnect "$WIFI_IF" 2>/dev/null || true
  sleep 1
  
  # Delete existing roomsense-hotspot connection if it exists
  if nmcli -t -f NAME connection show | grep -q "^roomsense-hotspot$"; then
    echo "[ap_start] Removing existing roomsense-hotspot connection"
    nmcli connection delete roomsense-hotspot 2>/dev/null || true
    sleep 1
  fi
  
  # Create hotspot connection
  echo "[ap_start] Creating hotspot connection..."
  if ! nmcli dev wifi hotspot ifname "$WIFI_IF" ssid "$SSID" password "$PSK" 2>&1; then
    echo "[ap_start] ERROR: Failed to create hotspot" >&2
    exit 1
  fi
  
  # Find the hotspot connection name (it might be "Hotspot" or something else)
  HOTSPOT_CONN=$(nmcli -t -f NAME,TYPE connection show | awk -F: '$2 == "802-11-wireless" {print $1}' | grep -i hotspot | head -n1)
  if [ -z "$HOTSPOT_CONN" ]; then
    # Try to find any wireless connection that was just created
    HOTSPOT_CONN=$(nmcli -t -f NAME connection show | tail -n1)
  fi
  
  if [ -n "$HOTSPOT_CONN" ] && [ "$HOTSPOT_CONN" != "roomsense-hotspot" ]; then
    echo "[ap_start] Renaming connection '$HOTSPOT_CONN' to 'roomsense-hotspot'"
    nmcli connection modify "$HOTSPOT_CONN" connection.id roomsense-hotspot 2>/dev/null || true
    HOTSPOT_CONN="roomsense-hotspot"
  fi
  
  # Bring up the connection
  echo "[ap_start] Activating hotspot connection..."
  if ! nmcli con up "$HOTSPOT_CONN" 2>&1; then
    echo "[ap_start] ERROR: Failed to activate hotspot connection" >&2
    exit 1
  fi
  
  # Wait a moment for the connection to establish
  sleep 2
  # Ensure the AP has a known address; NM typically assigns 10.42.0.1/24
  AP_ADDR=$(ip -o -4 addr show "$WIFI_IF" 2>/dev/null | awk '{print $4}' | head -n1)
  if [ -z "$AP_ADDR" ]; then
    echo "[ap_start] No IP address assigned, setting 10.42.0.1/24 manually"
    sudo ip addr flush dev "$WIFI_IF" 2>/dev/null || true
    sudo ip addr add 10.42.0.1/24 dev "$WIFI_IF" 2>/dev/null || true
    sudo ip link set "$WIFI_IF" up 2>/dev/null || true
    AP_ADDR="10.42.0.1/24"
  else
    echo "[ap_start] Hotspot IP address: $AP_ADDR"
  fi
  
  # Extract IP address without CIDR for iptables and dnsmasq
  AP_IP=$(echo "$AP_ADDR" | cut -d'/' -f1)
  
  # Configure hotspot to use our dnsmasq as DNS server for clients
  # NetworkManager hotspot mode provides DHCP, we'll configure it to advertise our IP as DNS
  echo "[ap_start] Configuring hotspot DNS settings to use $AP_IP..."
  nmcli connection modify "$HOTSPOT_CONN" ipv4.dns "$AP_IP" 2>/dev/null || true
  nmcli connection modify "$HOTSPOT_CONN" ipv4.ignore-auto-dns yes 2>/dev/null || true
  # Reload connection to apply DNS settings
  nmcli connection reload "$HOTSPOT_CONN" 2>/dev/null || true
  
  # Start dnsmasq for DNS hijacking (captive portal)
  # NetworkManager handles DHCP, so dnsmasq only does DNS
  echo "[ap_start] Starting dnsmasq for DNS hijacking..."
  sudo systemctl stop dnsmasq 2>/dev/null || true
  # Kill any existing roomsense dnsmasq instance
  if [ -f /run/roomsense-dnsmasq.pid ]; then
    sudo kill "$(cat /run/roomsense-dnsmasq.pid)" 2>/dev/null || true
    sudo rm -f /run/roomsense-dnsmasq.pid 2>/dev/null || true
  fi
  # Update dnsmasq config with actual AP IP
  # Update wildcard catch-all
  sudo sed -i "s|address=/#/.*|address=/#/$AP_IP|" /etc/roomsense/dnsmasq-portal.conf 2>/dev/null || true
  # Update all explicit domain entries (format: address=/domain/IP)
  sudo sed -i "s|address=/\([^/]*\)/10\.42\.0\.1|address=/\1/$AP_IP|g" /etc/roomsense/dnsmasq-portal.conf 2>/dev/null || true
  # Start dnsmasq in DNS-only mode (no DHCP to avoid conflict with NetworkManager)
  sudo dnsmasq \
    --conf-file=/etc/roomsense/dnsmasq-portal.conf \
    --interface="$WIFI_IF" \
    --except-interface=lo \
    --bind-interfaces \
    --no-dhcp \
    --log-facility=/opt/roomsense/logs/dnsmasq.log \
    --pid-file=/run/roomsense-dnsmasq.pid \
    --log-queries 2>&1 || {
    echo "[ap_start] WARNING: Failed to start dnsmasq, DNS hijacking may not work" >&2
  }
  echo "[ap_start] DNS hijacking enabled (all DNS queries redirect to $AP_IP)"
  
  # Add iptables redirect from clients' HTTP to portal on this device
  if ! sudo iptables -t nat -C PREROUTING -i "$WIFI_IF" -p tcp --dport 80 -j DNAT --to-destination "$AP_IP:80" 2>/dev/null; then
    sudo iptables -t nat -A PREROUTING -i "$WIFI_IF" -p tcp --dport 80 -j DNAT --to-destination "$AP_IP:80"
    echo "[ap_start] HTTP redirect to portal enabled (redirecting to $AP_IP:80)"
  else
    echo "[ap_start] HTTP redirect rule already exists"
  fi
  
  # Also redirect HTTPS (port 443) - will show certificate warning but allows detection
  if ! sudo iptables -t nat -C PREROUTING -i "$WIFI_IF" -p tcp --dport 443 -j DNAT --to-destination "$AP_IP:80" 2>/dev/null; then
    sudo iptables -t nat -A PREROUTING -i "$WIFI_IF" -p tcp --dport 443 -j DNAT --to-destination "$AP_IP:80"
    echo "[ap_start] HTTPS redirect to portal enabled (redirecting to $AP_IP:80)"
  else
    echo "[ap_start] HTTPS redirect rule already exists"
  fi
else
  echo "[ap_start] Legacy path: hostapd + static IP on $WIFI_IF"
  sudo ip link set "$WIFI_IF" down || true
  sudo ip addr flush dev "$WIFI_IF" || true
  sudo ip link set "$WIFI_IF" up || true
  sudo ip addr add 10.42.0.1/24 dev "$WIFI_IF" || true
  # Expect hostapd service to be configured if needed (not provided here)
  # Start dnsmasq in captive mode bound to the AP interface (legacy path)
  sudo systemctl stop dnsmasq || true
  sudo dnsmasq --conf-file=/etc/roomsense/dnsmasq-portal.conf --interface="$WIFI_IF" --except-interface=lo --bind-interfaces --log-facility=/opt/roomsense/logs/dnsmasq.log --pid-file=/run/roomsense-dnsmasq.pid
  echo "[ap_start] Hotspot and captive DNS started on $WIFI_IF"
fi

echo "[ap_start] Hotspot ready on $WIFI_IF"

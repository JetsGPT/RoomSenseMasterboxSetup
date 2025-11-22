import subprocess
import logging
import time
import re

logger = logging.getLogger(__name__)

class NetworkManager:
    def __init__(self):
        pass

    def run_command(self, command):
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, check=True, timeout=10
            )
            return result.stdout.strip()
        except subprocess.TimeoutExpired:
            logger.error(f"Command timed out: {command}")
            return None
        except subprocess.CalledProcessError as e:
            logger.error(f"Command failed: {e.cmd}. Output: {e.output}. Stderr: {e.stderr}")
            return None

    def scan_wifi(self):
        """Scans for available WiFi networks."""
        # We skip the explicit rescan because it can block for a long time.
        # nmcli usually does background scanning anyway.
        
        # Get list with fields: SSID, SIGNAL, SECURITY
        # We reduce timeout to 10s to fail fast if nmcli is stuck
        output = self.run_command(['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY,BARS', 'device', 'wifi', 'list'])
        
        networks = []
        if output:
            seen_ssids = set()
            for line in output.split('\n'):
                if not line: continue
                
                try:
                    # nmcli -t output: SSID:SIGNAL:SECURITY:BARS
                    # We expect at least 3 colons.
                    # If SSID contains colons, they are escaped as \:
                    # We can use a regex or just robust splitting.
                    # Since we requested specific fields, let's try to be robust.
                    
                    # Simple split might fail if SSID has colon.
                    # Let's use rsplit for the last 3 fields which are known to not have colons (mostly)
                    # SIGNAL is int, BARS is string, SECURITY is string.
                    
                    parts = line.rsplit(':', 3)
                    if len(parts) < 4:
                        continue
                        
                    ssid = parts[0].replace('\\:', ':')
                    signal = parts[1]
                    security = parts[2]
                    bars = parts[3]
                    
                    if not ssid:
                        continue
                        
                    if ssid not in seen_ssids:
                        networks.append({
                            'ssid': ssid,
                            'signal': signal,
                            'security': security,
                            'bars': bars
                        })
                        seen_ssids.add(ssid)
                except Exception as e:
                    logger.warning(f"Failed to parse line: {line} - {e}")
                    
        return sorted(networks, key=lambda x: int(x['signal']) if x['signal'].isdigit() else 0, reverse=True)

    def is_connected(self):
        """Checks if connected to a client network (not AP)."""
        # Check for active connection that is NOT our AP
        output = self.run_command(['nmcli', '-t', '-f', 'NAME,TYPE,STATE', 'connection', 'show', '--active'])
        if output:
            for line in output.split('\n'):
                if 'wireless' in line and 'activated' in line:
                    name = line.split(':')[0]
                    if name != 'RoomSenseSetup': # Our AP name
                        return True, name
        return False, None

    def connect_wifi(self, ssid, password):
        """Connects to a WiFi network."""
        # Delete existing connection if it exists to avoid duplicates
        self.run_command(['nmcli', 'connection', 'delete', ssid])
        
        cmd = ['nmcli', 'device', 'wifi', 'connect', ssid]
        if password:
            cmd.extend(['password', password])
            
        result = self.run_command(cmd)
        if result:
            return True
        return False

    def create_ap(self, ssid="RoomSenseSetup", password=None, gateway="10.42.0.1"):
        """Creates a Hotspot."""
        # Check if already exists
        exists = self.run_command(['nmcli', 'connection', 'show', ssid])
        
        if not exists:
            cmd = [
                'nmcli', 'connection', 'add',
                'type', 'wifi',
                'ifname', 'wlan0',
                'con-name', ssid,
                'autoconnect', 'yes',
                'ssid', ssid,
                'mode', 'ap'
            ]
            self.run_command(cmd)
            
            # Set IP settings
            self.run_command(['nmcli', 'connection', 'modify', ssid, 'ipv4.addresses', f'{gateway}/24'])
            self.run_command(['nmcli', 'connection', 'modify', ssid, 'ipv4.method', 'shared'])
            
            if password:
                self.run_command(['nmcli', 'connection', 'modify', ssid, 'wifi-sec.key-mgmt', 'wpa-psk'])
                self.run_command(['nmcli', 'connection', 'modify', ssid, 'wifi-sec.psk', password])
        
        # Activate
        self.run_command(['nmcli', 'connection', 'up', ssid])
        return True

    def delete_connection(self, name):
        self.run_command(['nmcli', 'connection', 'delete', name])

    def get_active_connection(self):
        output = self.run_command(['nmcli', '-t', '-f', 'NAME', 'connection', 'show', '--active'])
        return output.strip() if output else None

    def delete_all_connections(self):
        """Deletes all WiFi connections."""
        # Get all wifi connection UUIDs
        output = self.run_command(['nmcli', '-t', '-f', 'UUID,TYPE', 'connection', 'show'])
        if output:
            for line in output.split('\n'):
                if ':802-11-wireless' in line or ':wifi' in line: # nmcli type is 802-11-wireless or wifi
                    uuid = line.split(':')[0]
                    logger.info(f"Deleting connection {uuid}")
                    self.run_command(['nmcli', 'connection', 'delete', uuid])

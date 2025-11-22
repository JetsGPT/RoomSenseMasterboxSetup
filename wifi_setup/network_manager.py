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
                command, capture_output=True, text=True, check=True, timeout=30
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
        # Rescan first
        self.run_command(['nmcli', 'device', 'wifi', 'rescan'])
        time.sleep(2) # Give it a moment
        
        # Get list with fields: SSID, SIGNAL, SECURITY
        output = self.run_command(['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY,BARS', 'device', 'wifi', 'list'])
        
        networks = []
        if output:
            seen_ssids = set()
            for line in output.split('\n'):
                parts = line.replace(r'\:', '|COLON|').split(':') # Handle escaped colons if any, though -t usually avoids
                # Actually nmcli -t uses : as separator, so we need to be careful if SSID has :
                # Better approach: use fixed width or specific formatting if possible, but -t is standard.
                # Let's try a safer parsing strategy or just assume standard output.
                # Re-implementing with a simpler split, assuming SSID is the first field and might contain colons? 
                # nmcli -t escapes colons in values with \.
                
                # Let's just use the python split and basic cleaning for now.
                # A robust way is to use --fields and handle the output carefully.
                
                # Re-parsing:
                # SSID:SIGNAL:SECURITY:BARS
                # We can't easily split by : if SSID has it. 
                # Let's try a different format that is easier to parse, or just handle the common case.
                
                # Alternative: use -f SSID,SIGNAL,SECURITY,BARS and hope for the best or use Python to parse the escaped string.
                # For this MVP, we will assume SSIDs don't have colons or we split from the right for the known fields.
                
                # SSID can be empty for hidden networks
                if not line: continue
                
                # Split from right to get BARS, SECURITY, SIGNAL
                # The remainder on the left is SSID
                try:
                    # This is a bit hacky but works for most cases
                    # nmcli -t output: SSID:SIGNAL:SECURITY:BARS
                    # We expect at least 3 colons.
                    if line.count(':') < 3:
                        continue
                        
                    parts = line.rsplit(':', 3)
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
                    
        return sorted(networks, key=lambda x: int(x['signal']), reverse=True)

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

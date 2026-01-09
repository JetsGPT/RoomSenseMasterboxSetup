import subprocess
import logging
import time
import re
import os

logger = logging.getLogger(__name__)

class NetworkManager:
    def __init__(self):
        pass

    def run_command(self, command, sensitive=False):
        try:
            if sensitive:
                 # Log only the first argument (executable) and hide the rest
                 logger.info(f"Running: {command[0]} [ARGS REDACTED]")
            else:
                 logger.info(f"Running: {' '.join(command)}")
                 
            result = subprocess.run(
                command, capture_output=True, text=True, check=True, timeout=30
            )
            return result.stdout.strip()
        except subprocess.TimeoutExpired:
            logger.error(f"Command timed out: {command[0]}...")
            return None
        except subprocess.CalledProcessError as e:
            if sensitive:
                logger.error(f"Command failed: {e.cmd[0]}... Stderr: {e.stderr}")
            else:
                logger.error(f"Command failed: {e.cmd}. Output: {e.output}. Stderr: {e.stderr}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error running command: {e}")
            return None

    def scan_wifi(self):
        """Scans for available WiFi networks."""
        # nmcli -t -f SSID,SIGNAL,SECURITY,BARS device wifi list
        # Rescan can be slow, but usually nmcli has a cache.
        cmd = ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY,BARS', 'device', 'wifi', 'list', '--rescan', 'no']
        output = self.run_command(cmd)
        
        networks = []
        if output:
            seen_ssids = set()
            for line in output.split('\n'):
                if not line: continue
                try:
                    # Robust parsing for "SSID:SIGNAL:SECURITY:BARS"
                    # SSID can contain colons.
                    parts = line.rsplit(':', 3)
                    if len(parts) < 4: continue
                    
                    ssid = parts[0].replace(r'\:', ':')
                    signal = parts[1]
                    security = parts[2]
                    
                    if not ssid or ssid == '--': continue
                    
                    # Filter out our own AP if visible
                    if ssid == "RoomSenseSetup": continue

                    if ssid not in seen_ssids:
                        networks.append({
                            'ssid': ssid,
                            'signal': signal,
                            'security': security
                        })
                        seen_ssids.add(ssid)
                except Exception as e:
                    logger.warning(f"Parse error: {e}")

        return sorted(networks, key=lambda x: int(x['signal']) if x['signal'].isdigit() else 0, reverse=True)

    def is_connected_to_internet(self):
        """Checks if we have real internet access."""
        try:
            subprocess.check_call(['ping', '-c', '1', '-W', '2', '8.8.8.8'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except subprocess.CalledProcessError:
            return False

    def connect_wifi(self, ssid, password):
        """
        Attempts to connect to WiFi.
        CRITICAL: On single-radio devices, we must STOP the AP before connecting as client.
        We cannot easily "try" and "fallback" without dropping the user connection.
        """
        logger.info(f"Attempting to connect to {ssid}...")
        
        # 1. Config connection
        connection_name = f"wifi-{ssid}"
        
        # Delete any existing connection with this name/ssid to start fresh
        self.run_command(['nmcli', 'connection', 'delete', ssid]) 
        self.run_command(['nmcli', 'connection', 'delete', connection_name])
        
        # 2. Stop the AP (RoomSenseSetup)
        # This will kill the web request connection eventually, so the caller (app.py) 
        # must have already sent the response or spawned a thread that doesn't rely on the socket.
        logger.info("Stopping AP...")
        self.run_command(['nmcli', 'connection', 'down', 'RoomSenseSetup'])
        
        # 3. Add & Up new connection
        cmd = ['nmcli', 'device', 'wifi', 'connect', ssid]
        if password:
            cmd.extend(['password', password])
        
        # We give it a generous timeout because DHCP can take time
        # but nmcli connect waits for activation.
        success = False
        # Hide password in logs
        result = self.run_command(cmd, sensitive=True if password else False)
        
        if result:
            # Check internet verification
            time.sleep(5) # Wait for IP stabilization
            if self.is_connected_to_internet():
                logger.info("Internet connection verified!")
                success = True
            else:
                logger.warning("Connected to WiFi but no Internet access.")
                # We consider this a "success" for WiFi layer, but maybe "failure" for provisioning?
                # Requirement says: "Master Box to automatically download... once it successfully connects to the internet"
                # If we have no internet, we can't provision. 
                # Should we fail back to AP?
                # User might have a local-only network. But the goal is downloading from GitHub.
                # Let's count it as success, but warn? Or fail?
                # For safety, let's treat it as success, start provision script, provision script will wait for internet.
                success = True
        
        if success:
            return True
        else:
            logger.error("Failed to connect. Restoring AP...")
            self.create_ap()
            return False

    def create_ap(self, ssid="RoomSenseSetup", password=None):
        """Creates and starts the Hotspot."""
        logger.info("Creating AP...")
        
        # Explicitly disconnect current connections on the device to prevent interference
        self.run_command(['nmcli', 'device', 'disconnect', 'wlan0'])
        time.sleep(1) # Wait for disconnect
        
        # Ensure cleanup
        self.run_command(['nmcli', 'connection', 'down', ssid])
        self.run_command(['nmcli', 'connection', 'delete', ssid]) # Recreate to be sure
        
        cmd = [
            'nmcli', 'connection', 'add',
            'type', 'wifi',
            'ifname', 'wlan0',
            'con-name', ssid,
            'autoconnect', 'no',
            'ssid', ssid,
            'mode', 'ap',
            'ipv4.method', 'shared',
            'ipv4.addresses', '10.42.0.1/24'
        ]
        self.run_command(cmd)
        
        if password:
             self.run_command(['nmcli', 'connection', 'modify', ssid, 'wifi-sec.key-mgmt', 'wpa-psk'])
             self.run_command(['nmcli', 'connection', 'modify', ssid, 'wifi-sec.psk', password], sensitive=True)
             
        self.run_command(['nmcli', 'connection', 'up', ssid])

    def delete_all_connections(self):
        output = self.run_command(['nmcli', '-t', '-f', 'UUID,TYPE', 'connection', 'show'])
        if output:
            for line in output.split('\n'):
                if 'wireless' in line or 'wifi' in line:
                    uuid = line.split(':')[0]
                    self.run_command(['nmcli', 'connection', 'delete', uuid])

    def is_connected(self):
        """Returns (bool, ssid) if connected to a wifi network."""
        # nmcli -t -f TYPE,STATE,CONNECTION device
        output = self.run_command(['nmcli', '-t', '-f', 'TYPE,STATE,CONNECTION', 'device'])
        if output:
            for line in output.split('\n'):
                if not line: continue
                parts = line.split(':')
                # wifi:connected:MySSID
                if len(parts) >= 3 and parts[0] == 'wifi' and parts[1] == 'connected':
                     return True, parts[2]
        return False, None

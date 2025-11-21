#!/usr/bin/env python3
"""
Captive Portal Server for Raspberry Pi Wi-Fi Onboarding
Serves a web interface for Wi-Fi network selection and configuration
"""

from flask import Flask, render_template, request, jsonify, redirect
import subprocess
import os
import re
import shutil

# Get the directory where this script is located
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(SCRIPT_DIR, 'templates')

app = Flask(__name__, template_folder=TEMPLATE_DIR)

# Paths
WPA_SUPPLICANT_CONF = '/etc/wpa_supplicant/wpa_supplicant.conf'
WPA_SUPPLICANT_BACKUP = '/etc/wpa_supplicant/wpa_supplicant.conf.backup'
NETPLAN_CONFIG = '/etc/netplan/50-cloud-init.yaml'

def scan_wifi_networks():
    """Scan for available Wi-Fi networks"""
    try:
        result = subprocess.run(
            ['iwlist', 'wlan0', 'scan'],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            # Try nmcli
            result = subprocess.run(
                ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode != 0:
                # Try iw as last resort
                result = subprocess.run(
                    ['iw', 'dev', 'wlan0', 'scan'],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                
                if result.returncode == 0:
                    networks = []
                    current_ssid = None
                    current_signal = '0'
                    current_security = 'Open'
                    
                    for line in result.stdout.split('\n'):
                        line = line.strip()
                        if line.startswith('BSS '):
                            if current_ssid:
                                networks.append({'ssid': current_ssid, 'signal': current_signal, 'security': current_security})
                            current_ssid = None
                            current_signal = '0'
                            current_security = 'Open'
                        elif line.startswith('SSID: '):
                            current_ssid = line.split('SSID: ')[1].strip()
                        elif 'signal:' in line:
                            current_signal = line.split('signal:')[1].split('.')[0].strip()
                        elif 'RSN:' in line or 'WPA:' in line:
                            current_security = 'WPA2'
                            
                    if current_ssid:
                        networks.append({'ssid': current_ssid, 'signal': current_signal, 'security': current_security})
                        
                    # Deduplicate
                    seen = set()
                    unique = []
                    for net in networks:
                        if net['ssid'] and net['ssid'] not in seen:
                            seen.add(net['ssid'])
                            unique.append(net)
                    return unique
            
            if result.returncode == 0:
                networks = []
                for line in result.stdout.strip().split('\n'):
                    if line:
                        parts = line.split(':')
                        if len(parts) >= 2:
                            ssid = parts[0]
                            signal = parts[1] if len(parts) > 1 else '0'
                            security = parts[2] if len(parts) > 2 else ''
                            networks.append({
                                'ssid': ssid,
                                'signal': signal,
                                'security': 'WPA2' if 'WPA' in security else 'Open'
                            })
                return sorted(networks, key=lambda x: int(x['signal']) if x['signal'].isdigit() else 0, reverse=True)
        
        # Parse iwlist output
        networks = []
        current_ssid = None
        current_signal = None
        current_encryption = 'Open'
        
        for line in result.stdout.split('\n'):
            line = line.strip()
            
            # Extract SSID
            ssid_match = re.search(r'ESSID:"([^"]*)"', line)
            if ssid_match:
                if current_ssid and current_ssid != '':
                    networks.append({
                        'ssid': current_ssid,
                        'signal': current_signal or '0',
                        'security': current_encryption
                    })
                current_ssid = ssid_match.group(1)
                current_signal = None
                current_encryption = 'Open'
            
            # Extract signal strength
            signal_match = re.search(r'Signal level=(-?\d+)', line)
            if signal_match:
                current_signal = signal_match.group(1)
            
            # Check encryption
            if 'WPA2' in line or 'WPA' in line:
                current_encryption = 'WPA2'
            elif 'WEP' in line:
                current_encryption = 'WEP'
        
        # Add last network
        if current_ssid and current_ssid != '':
            networks.append({
                'ssid': current_ssid,
                'signal': current_signal or '0',
                'security': current_encryption
            })
        
        # Remove duplicates and empty SSIDs
        seen = set()
        unique_networks = []
        for net in networks:
            if net['ssid'] and net['ssid'] not in seen:
                seen.add(net['ssid'])
                unique_networks.append(net)
        
        return sorted(unique_networks, key=lambda x: int(x['signal']) if x['signal'].lstrip('-').isdigit() else 0, reverse=True)
        
    except Exception as e:
        print(f"Error scanning networks: {e}")
        return []

def write_wifi_credentials(ssid, password):
    """Write Wi-Fi credentials to wpa_supplicant.conf"""
    try:
        # Backup existing config
        if os.path.exists(WPA_SUPPLICANT_CONF):
            shutil.copy(WPA_SUPPLICANT_CONF, WPA_SUPPLICANT_BACKUP)
        
        # Read existing config or create new
        if os.path.exists(WPA_SUPPLICANT_CONF):
            with open(WPA_SUPPLICANT_CONF, 'r') as f:
                content = f.read()
        else:
            content = 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry=AT\n\n'
        
        # Remove ALL existing network entries (clean slate for new connection)
        lines = content.split('\n')
        new_lines = []
        skip_network_block = False
        
        for line in lines:
            # Keep header lines (ctrl_interface, update_config, country)
            if line.strip().startswith('ctrl_interface') or \
               line.strip().startswith('update_config') or \
               line.strip().startswith('country') or \
               line.strip() == '':
                if not skip_network_block:
                    new_lines.append(line)
                continue
            
            # Start of network block
            if re.search(r'network\s*=', line) or line.strip() == 'network={' or line.strip().startswith('network'):
                skip_network_block = True
                continue
            
            # End of network block (empty line after closing brace)
            if skip_network_block and line.strip() == '':
                skip_network_block = False
                continue
            
            # Skip lines inside network block
            if skip_network_block:
                continue
            
            # Keep other non-network lines
            new_lines.append(line)
        
        # Ensure we end with a newline before adding network
        if new_lines and new_lines[-1].strip() != '':
            new_lines.append('')
        
        # Add new network entry (only one network, clean configuration)
        new_lines.append('network={')
        new_lines.append(f'    ssid="{ssid}"')
        if password:
            new_lines.append(f'    psk="{password}"')
        else:
            new_lines.append('    key_mgmt=NONE')
        new_lines.append('}')
        new_lines.append('')
        
        # Write to file
        with open(WPA_SUPPLICANT_CONF, 'w') as f:
            f.write('\n'.join(new_lines))
        
        # Set proper permissions
        os.chmod(WPA_SUPPLICANT_CONF, 0o600)
        
        return True
    except Exception as e:
        print(f"Error writing credentials: {e}")
        return False

@app.route('/')
def index():
    """Main captive portal page"""
    return render_template('index.html')

@app.route('/api/networks')
def get_networks():
    """API endpoint to get available Wi-Fi networks"""
    networks = scan_wifi_networks()
    return jsonify(networks)

@app.route('/api/connect', methods=['POST'])
def connect():
    """API endpoint to save Wi-Fi credentials"""
    data = request.json
    ssid = data.get('ssid', '').strip()
    password = data.get('password', '').strip()
    
    if not ssid:
        return jsonify({'success': False, 'message': 'SSID is required'}), 400
    
    if write_wifi_credentials(ssid, password):
        return jsonify({'success': True, 'message': 'Credentials saved. Rebooting...'})
    else:
        return jsonify({'success': False, 'message': 'Failed to save credentials'}), 500

@app.route('/api/reboot', methods=['POST'])
def reboot():
    """API endpoint to reboot the system
    
    Note: This endpoint is called automatically after successful credential save.
    In a production environment, consider adding additional validation or
    rate limiting to prevent abuse.
    """
    try:
        subprocess.Popen(['sudo', 'reboot'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return jsonify({'success': True, 'message': 'Rebooting...'})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/generate_204')
@app.route('/gen_204')
def generate_204():
    """Android captive portal detection - return 204 No Content"""
    return '', 204

@app.route('/hotspot-detect.html')
@app.route('/library/test/success.html')
@app.route('/success.txt')
def captive_portal_redirect():
    """iOS/Windows captive portal detection - redirect to main page"""
    return redirect('/', code=302)

@app.route('/connecttest.txt')
def connecttest():
    """Windows captive portal detection"""
    return 'Microsoft Connect Test', 200

@app.route('/kindle-wifi/wifiredirect')
def kindle_redirect():
    """Kindle captive portal detection"""
    return redirect('/', code=302)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, debug=False)


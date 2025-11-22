from flask import Flask, render_template, request, jsonify, redirect
from network_manager import NetworkManager
import threading
import time
import os
import subprocess

app = Flask(__name__)
nm = NetworkManager()

# Global state
connection_status = "idle" # idle, connecting, success, failed
current_message = ""

@app.route('/')
def index():
    # Captive portal detection
    # If the host is not our IP, redirect to it? 
    # Actually, DNS redirection handles the "getting here" part.
    # But some OSes check for a specific URL (e.g. generate_204).
    # We should catch-all and serve index.
    return render_template('index.html')

@app.route('/generate_204')
@app.route('/ncsi.txt')
@app.route('/hotspot-detect.html')
def captive_portal_check():
    return redirect('/', code=302)

@app.route('/api/scan')
def scan():
    try:
        networks = nm.scan_wifi()
        return jsonify(networks)
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/connect', methods=['POST'])
def connect():
    global connection_status, current_message
    data = request.json
    ssid = data.get('ssid')
    password = data.get('password')
    
    if not ssid:
        return jsonify({'error': 'SSID required'}), 400
        
    connection_status = "connecting"
    current_message = f"Connecting to {ssid}..."
    
    def connect_thread():
        global connection_status, current_message
        success = nm.connect_wifi(ssid, password)
        if success:
            connection_status = "success"
            current_message = "Connected successfully! Rebooting..."
            # Wait a bit then reboot or stop AP
            time.sleep(3)
            # We could just stop the AP and let the new connection take over, 
            # but a reboot is cleaner to ensure system services start with network.
            subprocess.run(['sudo', 'reboot'])
        else:
            connection_status = "failed"
            current_message = "Failed to connect. Check password."

    threading.Thread(target=connect_thread).start()
    
    return jsonify({'status': 'started'})

@app.route('/api/status')
def status():
    return jsonify({'status': connection_status, 'message': current_message})

def check_and_start_ap():
    """Checks connection status on startup and creates AP if needed."""
    # Check for factory reset marker
    if os.path.exists('.factory_reset'):
        print("Factory reset marker found. Clearing all WiFi connections...")
        nm.delete_all_connections()
        try:
            os.remove('.factory_reset')
        except OSError:
            pass
        # After clearing, we definitely need to start AP
        print("Starting Hotspot after factory reset...")
        nm.create_ap("RoomSenseSetup", None)
        return

    connected, name = nm.is_connected()
    if connected:
        print(f"Connected to {name}. No need to start AP.")
    else:
        print("No active connection found. Starting Hotspot...")
        nm.create_ap("RoomSenseSetup", None) # Open network for easy setup, or add password if desired

if __name__ == '__main__':
    # Ensure we are accessible
    check_and_start_ap()
    app.run(host='0.0.0.0', port=80, threaded=True)

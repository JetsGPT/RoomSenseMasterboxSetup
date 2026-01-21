import threading
import time
import os
import subprocess
import logging

from flask import Flask, render_template, request, jsonify, redirect
from network_manager import NetworkManager

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger('app')

app = Flask(__name__)
nm = NetworkManager()

# Global state
connection_status = "idle" # idle, connecting, success, failed
current_message = ""
ap_mode_active = False  # Track if we're running in AP mode


def background_wifi_monitor():
    """
    Background thread that monitors for saved WiFi networks becoming available.
    Only runs when we're in AP mode. Checks every 2 minutes if a saved network
    is visible, and if so, logs this for the user (they should reconnect via portal).
    
    Note: We can't automatically switch because toggling networking would kill
    the AP that users are connected to. Instead, we just monitor.
    """
    global ap_mode_active
    
    while True:
        time.sleep(120)  # Check every 2 minutes
        
        if not ap_mode_active:
            continue
            
        logger.info("[WiFi Monitor] Scanning for available networks while in AP mode...")
        
        try:
            # Get list of saved connections
            result = subprocess.run(
                ['nmcli', '-t', '-f', 'NAME,TYPE', 'connection', 'show'],
                capture_output=True, text=True
            )
            saved_ssids = set()
            if result.returncode == 0:
                for line in result.stdout.strip().split('\n'):
                    if ':wifi' in line or ':802-11-wireless' in line:
                        saved_ssids.add(line.split(':')[0])
            
            # Scan for visible networks (this works even in AP mode)
            visible = nm.scan_wifi()
            visible_ssids = {n['ssid'] for n in visible}
            
            # Check if any saved network is now visible
            available = saved_ssids & visible_ssids
            if available:
                logger.info(f"[WiFi Monitor] Saved networks available: {available}")
                logger.info("[WiFi Monitor] User can reconnect via the setup portal.")
                    
        except Exception as e:
            logger.error(f"[WiFi Monitor] Error during scan: {e}")

@app.route('/')
def index():
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
        logger.error(f"Scan failed: {e}")
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
        global connection_status, current_message, nm
        # This will STOP the AP, so we might lose connectivity to the client here.
        # But `nm.connect_wifi` handles the stop/start.
        success = nm.connect_wifi(ssid, password)
        
        if success:
            connection_status = "success"
            current_message = "Connected successfully! Provisioning..."
            logger.info("Connection success. Triggering provisioning...")
            
            # Execute provision script in background so we don't block
            # and to allow clean exit if this service gets stopped.
            try:
                subprocess.Popen(['sudo', '/opt/roomsense/scripts/provision.sh'], 
                                 stdout=subprocess.DEVNULL, 
                                 stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            except Exception as e:
                logger.error(f"Failed to start provisioning: {e}")
                
        else:
            connection_status = "failed"
            current_message = "Failed to connect. Check password."
            logger.error("Connection failed.")

    # Start thread
    threading.Thread(target=connect_thread).start()
    
    return jsonify({'status': 'started'})

@app.route('/api/status')
def status():
    return jsonify({'status': connection_status, 'message': current_message})



def check_and_start_ap():
    """Checks connection status on startup and creates AP if needed."""
    
    # Grace Period: Wait for router to wake up (max 30s)
    logger.info("Waiting for internet/connection (Grace Period)...")
    for i in range(10): # 10 * 3s = 30s
        if nm.is_connected_to_internet():
            break
        # Also check if we are just connected to wifi but no internet yet (DHCP slow)
        connected, _ = nm.is_connected()
        if connected: 
             # Give it a bit more time for valid IP
             pass
        time.sleep(3)
        
    # Check for factory reset marker
    if os.path.exists('.factory_reset'):
        logger.info("Factory reset marker found. Clearing all WiFi connections...")
        
        # STOP DOCKER to free Port 80 (prevent conflict with old containers)
        try:
             subprocess.run(['systemctl', 'stop', 'docker'], check=False)
        except Exception:
             pass

        try:
            nm.delete_all_connections()
        except:
             pass # Fail safe
             
        try:
            os.remove('.factory_reset')
        except OSError:
            pass

        try:
            os.remove('.provisioned') # Clean up provision marker on factory reset
        except OSError:
            pass
        
        logger.info("Starting Hotspot after factory reset...")
        nm.create_ap()
        global ap_mode_active
        ap_mode_active = True
        return

    # Check internet connectivity or active wifi connection
    if nm.is_connected_to_internet():
         logger.info("Internet connected. Triggering auto-update/provisioning...")
         try:
             # Always run provision.sh (it is now idempotent/smart)
             subprocess.Popen(['sudo', '/opt/roomsense/scripts/provision.sh'], 
                              stdout=subprocess.DEVNULL, 
                              stderr=subprocess.DEVNULL,
                              start_new_session=True)
             
             # Stop self to let provision/production take over
             # BUT: since provision.sh might just restart services and exit (if no update),
             # we should strictly let provision.sh handle the stopping of this service if needed.
             # However, provision.sh DOES stop this service. So this is fine.
             subprocess.run(['systemctl', 'stop', 'roomsense-setup.service'], check=False)
             return
         except Exception as e:
             logger.error(f"Failed to start auto-update: {e}")

         logger.info("Internet connected. Switching to Production...")
         # Verification: Do NOT start Nginx (Docker handles frontend now)
         # subprocess.run(['systemctl', 'start', 'nginx'], check=False)
         # Stop self
         subprocess.run(['systemctl', 'stop', 'roomsense-setup.service'], check=False)
         return
    else:
        # Check if we are connected to a router at least (but maybe no internet)
        connected, name = nm.is_connected()
        if connected:
             logger.info(f"Connected to {name}, but maybe no internet? Checking...")
             if nm.is_connected_to_internet():
                 logger.info("Internet verified.")
                 return

        # Attempt to trigger reconnection before starting AP
        logger.info("Attempting to trigger network reconnection...")
        try:
            subprocess.run(['nmcli', 'networking', 'off'], check=False)
            time.sleep(2)
            subprocess.run(['nmcli', 'networking', 'on'], check=False)
            time.sleep(15)  # Wait for possible reconnection
            
            if nm.is_connected_to_internet():
                logger.info("Reconnection successful after toggle.")
                return
        except Exception as e:
            logger.error(f"Reconnection attempt failed: {e}")

        logger.info("No valid internet connection found. Starting Hotspot...")
        nm.create_ap()
        global ap_mode_active
        ap_mode_active = True

if __name__ == '__main__':
    # Ensure Nginx and Docker are not running and hogging port 80
    try:
        subprocess.run(['systemctl', 'stop', 'nginx'], check=False)
        subprocess.run(['systemctl', 'stop', 'docker'], check=False)
    except Exception:
        pass

    # Start background WiFi monitor thread (checks for WiFi returning while in AP mode)
    monitor_thread = threading.Thread(target=background_wifi_monitor, daemon=True)
    monitor_thread.start()

    check_and_start_ap()
    app.run(host='0.0.0.0', port=80, threaded=True)

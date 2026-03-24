import logging
import os
import subprocess
import threading
import time

from flask import Flask, jsonify, redirect, render_template, request

from network_manager import NetworkManager

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("app")

app = Flask(__name__)
nm = NetworkManager()

SETUP_DIR = os.path.dirname(os.path.abspath(__file__))
FACTORY_RESET_MARKER = os.path.join(SETUP_DIR, ".factory_reset")
PROVISIONED_MARKER = os.path.join(SETUP_DIR, ".provisioned")
PROVISIONING_MARKER = os.path.join(SETUP_DIR, ".provisioning")
SETUP_SERVICE = "roomsense-setup.service"
PROVISION_SERVICE = "roomsense-provision.service"
SETUP_AP_NAME = "RoomSenseSetup"
INTERNET_VALIDATION_TIMEOUT = 30

# Global state
connection_status = "idle"
current_message = "Setup hotspot is starting."
ap_mode_active = False


def set_connection_state(status, message=""):
    global connection_status, current_message
    connection_status = status
    current_message = message


def clear_provisioning_marker():
    try:
        os.remove(PROVISIONING_MARKER)
    except FileNotFoundError:
        pass
    except OSError as exc:
        logger.warning("Failed to clear provisioning marker: %s", exc)


def service_is_active(service_name):
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service_name],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.stdout.strip() in {"active", "activating"}
    except Exception as exc:
        logger.warning("Failed to query %s state: %s", service_name, exc)
        return False


def is_provisioning_active():
    active = service_is_active(PROVISION_SERVICE)
    if not active and os.path.exists(PROVISIONING_MARKER):
        logger.warning("Removing stale provisioning marker.")
        clear_provisioning_marker()
    return active


def start_provisioning(reason):
    if is_provisioning_active():
        logger.info("Provisioning already active. Reusing current run. Reason=%s", reason)
        return True

    try:
        with open(PROVISIONING_MARKER, "w", encoding="ascii"):
            pass
    except OSError as exc:
        logger.error("Failed to create provisioning marker: %s", exc)
        return False

    try:
        subprocess.run(
            ["systemctl", "reset-failed", PROVISION_SERVICE],
            check=False,
            capture_output=True,
            text=True,
        )
        result = subprocess.run(
            ["systemctl", "start", PROVISION_SERVICE],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            stderr = (result.stderr or result.stdout or "unknown error").strip()
            raise RuntimeError(stderr)
        logger.info("Provisioning service started. Reason=%s", reason)
        return True
    except Exception as exc:
        logger.error("Failed to start provisioning service: %s", exc)
        clear_provisioning_marker()
        return False


def stop_setup_service_async(reason):
    def _stop():
        try:
            logger.info("Stopping %s. Reason=%s", SETUP_SERVICE, reason)
            subprocess.run(["systemctl", "stop", SETUP_SERVICE], check=False)
        except Exception as exc:
            logger.error("Failed to stop setup service: %s", exc)

    threading.Thread(target=_stop, daemon=True).start()


def stop_runtime_services_for_setup():
    logger.info("Stopping runtime services before entering setup mode...")
    for service_name in ("nginx", "docker"):
        try:
            subprocess.run(["systemctl", "stop", service_name], check=False)
        except Exception as exc:
            logger.warning("Failed to stop %s: %s", service_name, exc)


def start_hotspot_mode(reason):
    global ap_mode_active

    logger.info("Starting hotspot mode. Reason=%s", reason)
    stop_runtime_services_for_setup()
    nm.create_ap()
    ap_mode_active = True
    set_connection_state("idle", "Setup hotspot is ready.")
    return True


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
        time.sleep(120)

        if not ap_mode_active:
            continue

        logger.info("[WiFi Monitor] Scanning for available networks while in AP mode...")

        try:
            result = subprocess.run(
                ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"],
                capture_output=True,
                text=True,
                check=False,
            )
            saved_ssids = set()
            if result.returncode == 0:
                for line in result.stdout.strip().split("\n"):
                    parts = line.rsplit(":", 1)
                    if len(parts) == 2 and parts[1] in {"wifi", "802-11-wireless"}:
                        saved_ssids.add(parts[0])

            visible = nm.scan_wifi()
            visible_ssids = {network["ssid"] for network in visible}

            available = saved_ssids & visible_ssids
            if available:
                logger.info("[WiFi Monitor] Saved networks available: %s", available)
                logger.info("[WiFi Monitor] User can reconnect via the setup portal.")

        except Exception as exc:
            logger.error("[WiFi Monitor] Error during scan: %s", exc)


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/generate_204")
@app.route("/ncsi.txt")
@app.route("/hotspot-detect.html")
def captive_portal_check():
    return redirect("/", code=302)


@app.route("/api/scan")
def scan():
    try:
        networks = nm.scan_wifi()
        return jsonify(networks)
    except Exception as exc:
        logger.error("Scan failed: %s", exc)
        return jsonify({"error": str(exc)}), 500


@app.route("/api/connect", methods=["POST"])
def connect():
    global ap_mode_active

    if connection_status in {"connecting", "validating", "provisioning"} or is_provisioning_active():
        return jsonify({"error": "Setup is already processing a connection request."}), 409

    data = request.get_json(silent=True) or {}
    ssid = data.get("ssid")
    password = data.get("password")

    if not ssid:
        return jsonify({"error": "SSID required"}), 400

    set_connection_state("connecting", f"Connecting to {ssid}...")

    def connect_thread():
        global ap_mode_active

        success = nm.connect_wifi(ssid, password)
        if not success:
            ap_mode_active = True
            set_connection_state("failed", "Failed to connect. Check password and signal strength.")
            logger.error("Connection failed.")
            return

        ap_mode_active = False
        set_connection_state("validating", f"Connected to {ssid}. Verifying internet access...")
        logger.info("WiFi association succeeded. Verifying internet access...")

        if not nm.wait_for_internet(timeout=INTERNET_VALIDATION_TIMEOUT, interval=3):
            logger.warning("Internet validation failed. Restoring hotspot mode.")
            try:
                start_hotspot_mode("internet validation failed after WiFi join")
            except Exception as exc:
                logger.error("Failed to restore hotspot after internet validation error: %s", exc)
            set_connection_state(
                "failed_no_internet",
                "Connected to WiFi, but internet access could not be verified. Setup mode has been restored.",
            )
            return

        set_connection_state("provisioning", "Internet verified. Checking for updates and provisioning...")
        logger.info("Internet verified. Waiting 3s for frontend to poll before handoff...")
        time.sleep(3)

        nm.run_command(["nmcli", "connection", "down", SETUP_AP_NAME])

        if start_provisioning("wifi connection completed"):
            logger.info("Provisioning started. Stopping setup service...")
            stop_setup_service_async("handoff after successful WiFi validation")
            return

        logger.error("Provisioning failed to start after internet verification. Restoring hotspot.")
        try:
            start_hotspot_mode("failed to start provisioning service")
        except Exception as exc:
            logger.error("Failed to restore hotspot after provisioning startup error: %s", exc)
        set_connection_state(
            "failed",
            "Connected to the network, but failed to start provisioning. Setup mode has been restored.",
        )

    threading.Thread(target=connect_thread, daemon=True).start()

    return jsonify({"status": "started"})


@app.route("/api/status")
def status():
    return jsonify({"status": connection_status, "message": current_message})


def check_and_start_ap():
    """Checks connection status on startup and decides whether setup mode should run."""

    global ap_mode_active

    logger.info("Waiting for internet/connection (Grace Period)...")
    for _ in range(10):
        if nm.is_connected_to_internet():
            break
        time.sleep(3)

    if os.path.exists(FACTORY_RESET_MARKER):
        logger.info("Factory reset marker found. Clearing saved WiFi connections...")
        stop_runtime_services_for_setup()

        try:
            nm.delete_all_connections()
        except Exception as exc:
            logger.warning("Failed to clear WiFi connections during factory reset: %s", exc)

        for marker in (FACTORY_RESET_MARKER, PROVISIONED_MARKER, PROVISIONING_MARKER):
            try:
                os.remove(marker)
            except FileNotFoundError:
                pass
            except OSError as exc:
                logger.warning("Failed to remove marker %s: %s", marker, exc)

        return start_hotspot_mode("factory reset requested")

    if is_provisioning_active():
        logger.info("Provisioning is already active. Setup service will exit.")
        ap_mode_active = False
        return False

    if nm.is_connected_to_internet():
        logger.info("Internet connected on startup. Checking for updates...")
        set_connection_state("provisioning", "Internet connection detected. Checking for updates...")
        ap_mode_active = False
        if start_provisioning("startup internet detected"):
            return False
        logger.error("Failed to start provisioning on startup. Keeping setup app available.")
        set_connection_state("failed", "Internet is available, but provisioning could not be started.")
        return True

    connected, name = nm.is_connected()
    if connected:
        logger.info("Connected to %s, waiting briefly for internet...", name)
        if nm.wait_for_internet(timeout=15, interval=3):
            logger.info("Internet became available on %s during startup grace window.", name)
            set_connection_state("provisioning", "Internet connection detected. Checking for updates...")
            ap_mode_active = False
            if start_provisioning("startup internet recovered"):
                return False
            logger.error("Failed to start provisioning after internet recovery.")
            set_connection_state("failed", "Internet is available, but provisioning could not be started.")
            return True

    logger.info("Attempting to trigger network reconnection...")
    try:
        subprocess.run(["nmcli", "networking", "off"], check=False)
        time.sleep(2)
        subprocess.run(["nmcli", "networking", "on"], check=False)
        if nm.wait_for_internet(timeout=15, interval=3):
            logger.info("Reconnection successful after networking toggle.")
            set_connection_state("provisioning", "Internet connection detected. Checking for updates...")
            ap_mode_active = False
            if start_provisioning("startup reconnection succeeded"):
                return False
            logger.error("Failed to start provisioning after reconnection.")
            set_connection_state("failed", "Internet is available, but provisioning could not be started.")
            return True
    except Exception as exc:
        logger.error("Reconnection attempt failed: %s", exc)

    logger.info("No valid internet connection found. Starting hotspot.")
    return start_hotspot_mode("no valid internet connection on startup")


if __name__ == "__main__":
    monitor_thread = threading.Thread(target=background_wifi_monitor, daemon=True)
    monitor_thread.start()

    should_run_server = check_and_start_ap()
    if should_run_server:
        app.run(host="0.0.0.0", port=80, threaded=True)
    else:
        logger.info("Setup service handed off to provisioning. Exiting.")

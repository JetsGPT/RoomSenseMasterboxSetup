import os
import subprocess
import json
import shutil
from flask import Flask, request, jsonify, send_from_directory, render_template

app = Flask(__name__, template_folder="templates", static_folder="static")

COUNTRY = os.environ.get("ROOMSENSE_COUNTRY", "AT")
SCRIPTS_DIR = "/opt/roomsense/setup/scripts"


def run(cmd):
    try:
        res = subprocess.run(cmd, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return res.stdout
    except subprocess.CalledProcessError as e:
        return e.stdout + "\n" + e.stderr


@app.route("/")
def index():
    return render_template("index.html")


@app.get("/api/scan")
def scan_wifi():
    # Prefer nmcli if present
    if shutil.which("nmcli"):
        out = run("nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list || true")
        networks = []
        seen = set()
        for line in out.splitlines():
            if not line:
                continue
            parts = line.split(":")
            ssid = parts[0]
            if not ssid or ssid in seen:
                continue
            seen.add(ssid)
            signal = parts[1] if len(parts) > 1 else ""
            security = parts[2] if len(parts) > 2 else ""
            networks.append({"ssid": ssid, "signal": signal, "security": security})
        return jsonify({"networks": networks})
    # Fallback: iw scan
    out = run("iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}'")
    iface = out.strip() or "wlan0"
    scan = run(f"iw dev {iface} scan 2>/dev/null | egrep 'SSID|signal' || true")
    networks = []
    ssid = None
    for line in scan.splitlines():
        if line.strip().startswith("SSID:"):
            ssid = line.split(":", 1)[1].strip()
            if ssid and not any(n["ssid"] == ssid for n in networks):
                networks.append({"ssid": ssid, "signal": "", "security": ""})
        elif line.strip().startswith("signal:") and ssid and networks:
            networks[-1]["signal"] = line.split(":", 1)[1].strip()
    return jsonify({"networks": networks})


@app.post("/api/connect")
def connect_wifi():
    body = request.get_json(force=True, silent=True) or {}
    ssid = body.get("ssid", "").strip()
    password = body.get("password", "").strip()
    country = body.get("country", COUNTRY).strip() or COUNTRY
    if not ssid or not password:
        return jsonify({"ok": False, "error": "ssid and password required"}), 400

    # Call wifi_connect.sh
    script = os.path.join(SCRIPTS_DIR, "wifi_connect.sh")
    proc = subprocess.run(["bash", script, ssid, password, country], capture_output=True, text=True)
    success = proc.returncode == 0

    if success:
        # Stop portal + AP and reboot
        post = os.path.join(SCRIPTS_DIR, "post_connect.sh")
        subprocess.Popen(["bash", post])
        return jsonify({"ok": True})
    else:
        return jsonify({"ok": False, "error": proc.stderr or proc.stdout}), 500


@app.get("/health")
def health():
    return jsonify({"ok": True})


# Captive portal detection endpoints
# These endpoints are checked by various devices to detect captive portals

# Apple iOS/macOS detection
@app.get("/library/test/success.html")
@app.get("/hotspot-detect.html")
def apple_detect():
    """Apple devices check this endpoint"""
    return render_template("index.html")


# Android/Chrome detection
@app.get("/generate_204")
def android_detect():
    """Android and Chrome check this endpoint - should return 204 No Content"""
    return "", 204


# Windows detection
@app.get("/ncsi.txt")
def windows_detect():
    """Windows checks this endpoint - should return 'Microsoft NCSI'"""
    return "Microsoft NCSI", 200, {"Content-Type": "text/plain"}


@app.get("/connecttest.txt")
def windows_connecttest():
    """Windows 10+ checks this endpoint"""
    return "Microsoft Connect Test", 200, {"Content-Type": "text/plain"}


# Generic catch-all for any other path - redirect to portal
# This must be last to not interfere with API routes
@app.route("/<path:path>")
def catch_all(path):
    """Catch-all route to redirect any other requests to the portal"""
    # Don't catch API routes or static files - Flask will handle 404 for those
    if path.startswith("api/") or path.startswith("static/"):
        return "", 404
    # For any other path, show the portal
    return render_template("index.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)

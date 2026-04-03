#!/bin/bash

# batman-adv mesh test setup
# Fresh RPi Lite image, MT7612U on wlan1
# 802.11s mesh point + batman-adv, 2.4 GHz channel 1
# Installs a systemd service for persistence and recovery across reboots/hotplug
#
# Usage: sudo bash batman.sh

set -e

if [[ "$EUID" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

MESH_IF="wlan1"
MESH_ID="birddog-mesh"
BAT_IF="bat0"
FREQ=2412
BATMAN_CONF="/etc/batman.conf"
SERVICE_NAME="batman-mesh"

echo "================================="
echo "batman-adv mesh setup"
echo "================================="
echo ""

# ── Prompt for node IP octet ──
while true; do
    read -r -p "  Enter 2-digit node octet (10-99): " OCTET
    [[ "$OCTET" =~ ^[0-9]{2}$ && "$OCTET" -ge 10 && "$OCTET" -le 99 ]] && break
    echo "  Invalid — must be 2 digits between 10 and 99"
done

MESH_IP="10.10.20.${OCTET}/24"

echo ""
echo "  Interface : $MESH_IF"
echo "  Mesh IP   : $MESH_IP"
echo "  Channel   : 1 (2412 MHz)"
echo ""

# ── Teardown any existing batman session ──
echo "[0] Tearing down any existing batman-adv session..."

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$SERVICE_NAME" || true
    echo "  Stopped $SERVICE_NAME service"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME" || true
fi

pkill -f "batman-mesh-join" 2>/dev/null || true
sleep 1

if ip link show "$BAT_IF" >/dev/null 2>&1; then
    ip link set "$BAT_IF" down 2>/dev/null || true
    batctl if del "$MESH_IF" 2>/dev/null || true
    echo "  bat0 torn down"
fi

if iw dev "$MESH_IF" info 2>/dev/null | grep -q "mesh point"; then
    iw dev "$MESH_IF" mesh leave 2>/dev/null || true
    echo "  wlan1 mesh left"
fi

ip link set "$MESH_IF" down 2>/dev/null || true
echo "  Done"

# ── Dependencies ──
echo "[1] Installing dependencies..."
apt-get update -qq
apt-get install -y batctl iw wireless-tools
echo "  Done"

# ── batman-adv kernel module ──
echo "[2] Loading batman-adv module..."
modprobe batman-adv
lsmod | grep -q batman_adv && echo "  batman_adv loaded" || { echo "  ERROR: module not loaded"; exit 1; }

# Make batman-adv load on boot
echo "batman-adv" > /etc/modules-load.d/batman-adv.conf
echo "  batman-adv configured to load on boot"

# ── Save config ──
echo "[3] Saving node config..."
cat > "$BATMAN_CONF" << EOF
MESH_IP="10.10.20.${OCTET}/24"
MESH_IF="wlan1"
MESH_ID="birddog-mesh"
BAT_IF="bat0"
FREQ=2412
EOF
echo "  Config saved to $BATMAN_CONF"

# ── Install mesh join script ──
echo "[4] Installing batman-mesh-join service script..."

cat > /usr/local/bin/batman-mesh-join.sh << 'MESH_SCRIPT'
#!/bin/bash

# BirdDog batman-adv mesh runtime
# Watches for wlan1, configures 802.11s mesh point, attaches batman-adv
# Recovers automatically on adapter hotplug or mesh loss
# Runs as batman-mesh.service

BATMAN_CONF="/etc/batman.conf"
LOG="/var/log/batman-mesh.log"

if [[ ! -f "$BATMAN_CONF" ]]; then
    echo "ERROR: $BATMAN_CONF not found" | tee -a "$LOG"
    exit 1
fi

source "$BATMAN_CONF"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"
}

log "================================="
log "batman-mesh runtime start"
log "Hostname : $(hostname)"
log "Mesh IP  : $MESH_IP"
log "Freq     : $FREQ MHz"

interface_exists() {
    ip link show "$MESH_IF" >/dev/null 2>&1
}

mesh_joined() {
    iw dev "$MESH_IF" info 2>/dev/null | grep -q "type mesh point"
}

batman_attached() {
    batctl if 2>/dev/null | grep -q "$MESH_IF"
}

bat0_has_ip() {
    ip addr show "$BAT_IF" 2>/dev/null | grep -q "$MESH_IP"
}

teardown() {
    log "Tearing down..."
    ip link set "$BAT_IF" down 2>/dev/null || true
    batctl if del "$MESH_IF" 2>/dev/null || true
    iw dev "$MESH_IF" mesh leave 2>/dev/null || true
    ip link set "$MESH_IF" down 2>/dev/null || true
}

setup() {
    log "Setting up mesh..."

    # Load batman-adv first — matches the order that worked manually
    modprobe batman-adv 2>/dev/null || true

    iw reg set US 2>/dev/null || true
    sleep 1

    ip link set "$MESH_IF" down 2>/dev/null || true
    sleep 1
    iw dev "$MESH_IF" set type mp 2>/dev/null || {
        log "ERROR: could not set mesh point mode"
        return 1
    }
    ip link set "$MESH_IF" up 2>/dev/null || true
    sleep 1

    iw dev "$MESH_IF" mesh join "$MESH_ID" freq "$FREQ" 2>/dev/null || {
        log "ERROR: mesh join failed"
        return 1
    }

    iw dev "$MESH_IF" set mesh_param mesh_fwding 0 2>/dev/null || true

    # Set MTU on wlan1 to accommodate batman-adv header overhead.
    # batman-adv requires at least 1532 bytes on the underlying interface.
    # bat0 stays at standard 1500.
    ip link set "$MESH_IF" mtu 1532 2>/dev/null || true

    batctl if add "$MESH_IF" 2>/dev/null || true
    ip link set "$BAT_IF" up 2>/dev/null || true
    ip link set "$BAT_IF" mtu 1500 2>/dev/null || true
    ip addr replace "$MESH_IP" dev "$BAT_IF" 2>/dev/null || true

    log "Mesh up — IP: $MESH_IP"
    return 0
}

STATE="WAIT_INTERFACE"
log "STATE → $STATE"

while true; do

    if ! interface_exists; then
        if [[ "$STATE" != "WAIT_INTERFACE" ]]; then
            log "Interface lost"
            STATE="WAIT_INTERFACE"
            log "STATE → $STATE"
        fi
        sleep 2
        continue
    fi

    if [[ "$STATE" == "WAIT_INTERFACE" ]]; then
        sleep 2  # allow driver to settle after hotplug
        setup && STATE="STEADY" || STATE="RECOVERY"
        log "STATE → $STATE"
        continue
    fi

    if ! mesh_joined || ! batman_attached; then
        log "Mesh or batman-adv lost"
        teardown
        STATE="RECOVERY"
        log "STATE → $STATE"
    fi

    if ! bat0_has_ip; then
        ip addr replace "$MESH_IP" dev "$BAT_IF" 2>/dev/null || true
        log "IP restored: $MESH_IP"
    fi

    if [[ "$STATE" == "RECOVERY" ]]; then
        sleep 3
        setup && STATE="STEADY" || true
        log "STATE → $STATE"
    fi

    sleep 5

done
MESH_SCRIPT

chmod +x /usr/local/bin/batman-mesh-join.sh
echo "  batman-mesh-join.sh installed"

# ── Install systemd service ──
echo "[5] Installing systemd service..."

cat > /etc/systemd/system/batman-mesh.service << EOF
[Unit]
Description=batman-adv Mesh Runtime
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/batman-mesh-join.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable batman-mesh
systemctl start batman-mesh
echo "  batman-mesh.service installed and started"

# ── Verify ──
echo ""
sleep 5
echo "================================="
echo "Verification"
echo "================================="
echo ""
echo "--- Interface ---"
iw dev "$MESH_IF" info 2>/dev/null | grep -E "type|channel|freq|txpower" || echo "  wlan1 not ready yet"
echo ""
echo "--- bat0 ---"
ip addr show "$BAT_IF" 2>/dev/null | grep inet || echo "  bat0 IP not assigned yet"
echo ""
echo "--- batman-adv originators ---"
batctl o 2>/dev/null || echo "  No originators yet"
echo ""
echo "--- Service status ---"
systemctl is-active batman-mesh && echo "  batman-mesh: running" || echo "  batman-mesh: not running"
echo ""
echo "================================="
echo "Setup complete"
echo "  bat0 IP : $MESH_IP"
echo "  Log     : /var/log/batman-mesh.log"
echo "  Run 'sudo batctl o' to watch for peers"
echo "================================="
echo ""

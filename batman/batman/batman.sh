#!/bin/bash

# version: 3
# batman-adv mesh setup
# Fresh RPi Lite image, MT7612U pinned to wlan_mesh_5 via udev
# 802.11s mesh point + batman-adv, 5 GHz channel 36
#
# Run 1: installs udev rule, prompts reboot
# Run 2: completes mesh setup after reboot
#
# Usage: sudo bash batman.sh

set -e

if [[ "$EUID" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

MESH_IF="wlan_mesh_5"
MESH_ID="birddog-mesh"
BAT_IF="bat0"
FREQ=5180

echo "================================="
echo "batman-adv mesh setup"
echo "================================="
echo ""

# ── udev rule — pin MT7612U to wlan_mesh_5 ──
echo "[1] Installing udev rule for MT7612U..."
cat > /etc/udev/rules.d/72-batman-radios.rules << 'EOF'
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mt76x2u", NAME="wlan_mesh_5"
EOF
udevadm control --reload-rules
echo "  MT7612U pinned to wlan_mesh_5"

# Check if wlan_mesh_5 already exists (post-reboot run)
if ! ip link show "$MESH_IF" >/dev/null 2>&1; then
    echo ""
    echo "  Udev rule installed — reboot required"
    echo "  After reboot, re-run this script to complete mesh setup"
    echo ""
    exit 0
fi
echo "  wlan_mesh_5 present — continuing with mesh setup"
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
echo "  Channel   : 36 ($FREQ MHz)"
echo ""

# ── Update package index first ──
echo "[0] Updating package index..."
apt-get update -qq
echo "  Done"

# ── eth0 — configure before removing NetworkManager ──
echo "[2] Configuring eth0 for DHCP via ifupdown..."
apt-get install -y -qq ifupdown
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
echo "  eth0 configured for DHCP via ifupdown"

# ── Remove NetworkManager and rfkill ──
echo "[3] Removing NetworkManager and rfkill..."
apt-get purge -y network-manager rfkill 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
echo "  Done"

# ── Dependencies ──
echo "[4] Installing dependencies..."
apt-get install -y batctl iw wireless-tools
echo "  Done"

# ── batman-adv kernel module ──
echo "[5] Loading batman-adv module..."
modprobe batman-adv
lsmod | grep -q batman_adv && echo "  batman_adv loaded" || { echo "  ERROR: module not loaded"; exit 1; }

# Make batman-adv load on boot
echo "batman-adv" > /etc/modules-load.d/batman-adv.conf
echo "  batman-adv configured to load on boot"

# ── Save node config ──
echo "[6] Saving node config..."
cat > /etc/batman.conf << EOF
MESH_IP="${MESH_IP}"
MESH_IF="${MESH_IF}"
MESH_ID="${MESH_ID}"
BAT_IF="${BAT_IF}"
FREQ=${FREQ}
EOF
echo "  Config saved to /etc/batman.conf"

# ── 802.11s mesh point ──
echo "[7] Configuring $MESH_IF as mesh point..."
ip link set "$MESH_IF" down
iw dev "$MESH_IF" set type mp
ip link set "$MESH_IF" up
echo "  $MESH_IF in mesh point mode"

# ── Join mesh ──
echo "[8] Joining mesh '$MESH_ID' on $FREQ MHz..."
iw dev "$MESH_IF" mesh join "$MESH_ID" freq "$FREQ" HT20
echo "  Joined"

# ── batman-adv ──
echo "[9] Attaching batman-adv..."
batctl if add "$MESH_IF"
ip link set "$BAT_IF" up
ip addr add "$MESH_IP" dev "$BAT_IF"
echo "  bat0 up — IP: $MESH_IP"

# ── MTU ──
echo "[10] Setting MTU..."
ip link set "$MESH_IF" mtu 1532
ip link set "$BAT_IF" mtu 1500
echo "  $MESH_IF MTU: 1532  $BAT_IF MTU: 1500"

# ── mesh_fwding ──
echo "[11] Disabling 802.11s forwarding..."
iw dev "$MESH_IF" set mesh_param mesh_fwding 0
echo "  mesh_fwding: 0"

# ── Install service script ──
echo "[12] Installing batman-mesh service..."

cat > /usr/local/bin/batman-mesh-join.sh << 'MESH_SCRIPT'
#!/bin/bash

# batman-adv mesh runtime
# Runs as batman-mesh.service
# Reads config from /etc/batman.conf
# State machine: WAIT_INTERFACE -> STEADY -> RECOVERY

BATMAN_CONF="/etc/batman.conf"
LOG="/var/log/batman-mesh.log"

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
    ip addr show "$BAT_IF" 2>/dev/null | grep -q "${MESH_IP%/*}"
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

    modprobe batman-adv 2>/dev/null || true

    ip link set "$MESH_IF" down 2>/dev/null || true
    sleep 1

    iw dev "$MESH_IF" set type mp 2>/dev/null || {
        log "ERROR: could not set mesh point mode"
        return 1
    }

    ip link set "$MESH_IF" up 2>/dev/null || true
    sleep 1

    iw dev "$MESH_IF" mesh join "$MESH_ID" freq "$FREQ" HT20 2>/dev/null || {
        log "ERROR: mesh join failed"
        return 1
    }

    batctl if add "$MESH_IF" 2>/dev/null || true
    ip link set "$BAT_IF" up 2>/dev/null || true
    ip addr replace "$MESH_IP" dev "$BAT_IF" 2>/dev/null || true

    iw dev "$MESH_IF" set mesh_param mesh_fwding 0 2>/dev/null || true

    ip link set "$MESH_IF" mtu 1532 2>/dev/null || true
    ip link set "$BAT_IF" mtu 1500 2>/dev/null || true

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
        sleep 2
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
sleep 8
echo "================================="
echo "Verification"
echo "================================="
echo ""
echo "--- rfkill ---"
rfkill list 2>/dev/null || echo "  rfkill removed"
echo ""
echo "--- Interface ---"
iw dev "$MESH_IF" info | grep -E "type|channel|freq|txpower"
echo ""
echo "--- bat0 ---"
ip addr show "$BAT_IF" | grep inet
echo ""
echo "--- MTU ---"
ip link show "$MESH_IF" | grep mtu
ip link show "$BAT_IF" | grep mtu
echo ""
echo "--- Service ---"
systemctl is-active batman-mesh && echo "  batman-mesh: running" || echo "  batman-mesh: not running"
echo ""
echo "--- batman-adv originators ---"
batctl o
echo ""
echo "================================="
echo "Setup complete"
echo "  bat0 IP : $MESH_IP"
echo "  Log     : /var/log/batman-mesh.log"
echo "  Run 'sudo batctl o' to watch for peers"
echo "================================="
echo ""

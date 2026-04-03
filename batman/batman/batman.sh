#!/bin/bash

# batman-adv mesh setup
# Fresh RPi Lite image, MT7612U on wlan1
# 802.11s mesh point + batman-adv, 2.4 GHz channel 1
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
echo "  Channel   : 1 ($FREQ MHz)"
echo ""

# ── eth0 — configure before removing NetworkManager ──
echo "[0] Configuring eth0 for DHCP via ifupdown..."
apt-get install -y -qq ifupdown
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
echo "  eth0 configured for DHCP via ifupdown"

# ── Remove NetworkManager and rfkill ──
echo "[1] Removing NetworkManager and rfkill..."
apt-get purge -y network-manager rfkill 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
echo "  Done"

# ── Dependencies ──
echo "[2] Installing dependencies..."
apt-get update -qq
apt-get install -y batctl iw wireless-tools
echo "  Done"

# ── batman-adv kernel module ──
echo "[3] Loading batman-adv module..."
modprobe batman-adv
lsmod | grep -q batman_adv && echo "  batman_adv loaded" || { echo "  ERROR: module not loaded"; exit 1; }

# Make batman-adv load on boot
echo "batman-adv" > /etc/modules-load.d/batman-adv.conf
echo "  batman-adv configured to load on boot"

# ── 802.11s mesh point ──
echo "[4] Configuring $MESH_IF as mesh point..."
ip link set "$MESH_IF" down
iw dev "$MESH_IF" set type mp
ip link set "$MESH_IF" up
echo "  $MESH_IF in mesh point mode"

# ── Join mesh ──
echo "[5] Joining mesh '$MESH_ID' on $FREQ MHz..."
iw dev "$MESH_IF" mesh join "$MESH_ID" freq "$FREQ"
echo "  Joined"

# ── batman-adv ──
echo "[6] Attaching batman-adv..."
batctl if add "$MESH_IF"
ip link set "$BAT_IF" up
ip addr add "$MESH_IP" dev "$BAT_IF"
echo "  bat0 up — IP: $MESH_IP"

# ── MTU ──
echo "[7] Setting MTU..."
ip link set "$MESH_IF" mtu 1532
ip link set "$BAT_IF" mtu 1500
echo "  wlan1 MTU: 1532  bat0 MTU: 1500"

# ── mesh_fwding ──
echo "[8] Disabling 802.11s forwarding..."
iw dev "$MESH_IF" set mesh_param mesh_fwding 0
echo "  mesh_fwding: 0"

# ── Verify ──
echo ""
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
echo "--- batman-adv originators ---"
batctl o
echo ""
echo "================================="
echo "Setup complete"
echo "  bat0 IP : $MESH_IP"
echo "  Run 'sudo batctl o' to watch for peers"
echo "================================="
echo ""

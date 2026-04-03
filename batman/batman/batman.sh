#!/bin/bash

# batman-adv mesh test setup
# Fresh RPi Lite image, MT7612U on wlan1
# 802.11s mesh point + batman-adv, 5 GHz channel 36
#
# Usage: sudo bash batman.sh <last_octet>
#   e.g. sudo bash batman.sh 10  →  bat0 IP: 10.10.20.10

set -e

if [[ "$EUID" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

if [[ -z "$1" ]]; then
    echo "Usage: sudo bash batman.sh <last_octet>"
    echo "  e.g. sudo bash batman.sh 10"
    exit 1
fi

MESH_IP="10.10.20.$1/24"
MESH_IF="wlan1"
MESH_ID="birddog-mesh"
BAT_IF="bat0"
FREQ=5180

echo "================================="
echo "batman-adv mesh setup"
echo "  Interface : $MESH_IF"
echo "  Mesh IP   : $MESH_IP"
echo "  Channel   : 36 ($FREQ MHz)"
echo "================================="
echo ""

# ── Dependencies ──
echo "[1] Installing dependencies..."
apt-get update -qq
apt-get install -y batctl iw wireless-tools
echo "  Done"

# ── batman-adv kernel module ──
echo "[2] Loading batman-adv module..."
modprobe batman-adv
lsmod | grep -q batman_adv && echo "  batman_adv loaded" || { echo "  ERROR: module not loaded"; exit 1; }

# ── Regulatory domain ──
echo "[3] Setting regulatory domain US..."
iw reg set US
echo "  Done"

# ── 802.11s mesh point ──
echo "[4] Configuring $MESH_IF as mesh point..."
ip link set "$MESH_IF" down
iw dev "$MESH_IF" set type mp
ip link set "$MESH_IF" up
sleep 1
echo "  $MESH_IF in mesh point mode"

# ── Join mesh ──
echo "[5] Joining mesh '$MESH_ID' on $FREQ MHz..."
iw dev "$MESH_IF" mesh join "$MESH_ID" freq "$FREQ" HT20
# Disable 802.11s forwarding — batman-adv owns all routing
iw dev "$MESH_IF" set mesh_param mesh_fwding 0
echo "  Joined (mesh_fwding disabled)"

# ── batman-adv ──
echo "[6] Attaching batman-adv..."
batctl if add "$MESH_IF"
ip link set "$BAT_IF" up
ip addr add "$MESH_IP" dev "$BAT_IF"
echo "  bat0 up — IP: $MESH_IP"

# ── Verify ──
echo ""
echo "================================="
echo "Verification"
echo "================================="
echo ""
iw dev "$MESH_IF" info | grep -E "type|channel|freq|txpower"
echo ""
echo "batman-adv originators:"
batctl o
echo ""
echo "================================="
echo "Setup complete"
echo "  bat0 IP : $MESH_IP"
echo "  Run 'sudo batctl o' to watch for peers"
echo "================================="
echo ""

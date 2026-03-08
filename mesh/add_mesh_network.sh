#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash mesh_setup.sh"
  exit 1
fi

MESH_IF="wlan1"
MESH_ID="birddog"
MESH_CHANNEL="1"

echo "=== Unblocking WiFi ==="
rfkill unblock wifi || true

echo "=== Set regulatory domain ==="
iw reg set US || true

echo "=== Bring interface down ==="
ip link set ${MESH_IF} down

echo "=== Set mesh interface type ==="
iw dev ${MESH_IF} set type mesh

echo "=== Bring interface up ==="
ip link set ${MESH_IF} up

echo "=== Join mesh network ==="
iw dev ${MESH_IF} mesh join ${MESH_ID} freq 2412

echo "=== Disable WiFi power save ==="
iw dev ${MESH_IF} set power_save off || true

echo "=== Mesh interface status ==="
iw dev ${MESH_IF} info

echo "=== Mesh peer table (will populate when other nodes join) ==="
iw dev ${MESH_IF} station dump

echo "=== Mesh setup complete ==="
echo "Mesh ID: ${MESH_ID}"
echo "Interface: ${MESH_IF}"
echo "Channel: ${MESH_CHANNEL}"

#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash bdm_AP_setup.sh"
  exit 1
fi

AP_IF="wlan1"
AP_IP="10.10.10.1/24"
SSID="BirdDog"
PASSPHRASE="StrongPass123"

echo "=== Unblocking WiFi ==="
rfkill unblock wifi || true

echo "=== Installing required packages ==="
apt update
apt install -y hostapd dnsmasq

echo "=== Disable NetworkManager (appliance mode) ==="
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true

echo "=== Enable systemd-networkd ==="
systemctl enable systemd-networkd
systemctl start systemd-networkd

mkdir -p /etc/systemd/network

echo "=== Configure eth0 (DHCP for LAN access) ==="
cat > /etc/systemd/network/eth0.network <<EOF
[Match]
Name=eth0

[Network]
DHCP=yes
EOF

echo "=== Configure ${AP_IF} (Static AP IP) ==="
cat > /etc/systemd/network/${AP_IF}.network <<EOF
[Match]
Name=${AP_IF}

[Network]
Address=${AP_IP}
EOF

echo "=== Configure hostapd ==="
cat > /etc/hostapd/hostapd.conf <<EOF
interface=${AP_IF}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=${PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

if grep -q "^DAEMON_CONF=" /etc/default/hostapd; then
  sed -i "s|^DAEMON_CONF=.*|DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"|" /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

systemctl unmask hostapd || true
systemctl enable hostapd

echo "=== Configure dnsmasq ==="
rm -f /etc/dnsmasq.conf
cat > /etc/dnsmasq.conf <<EOF
interface=${AP_IF}
bind-dynamic
dhcp-range=10.10.10.50,10.10.10.150,255.255.255.0,24h
EOF

systemctl enable dnsmasq

echo "=== Ensure WiFi unblocked on boot ==="
mkdir -p /etc/systemd/system/hostapd.service.d
cat > /etc/systemd/system/hostapd.service.d/rfkill.conf <<EOF
[Service]
ExecStartPre=/usr/sbin/rfkill unblock wifi
EOF

systemctl daemon-reload

echo "=== Restarting services ==="
systemctl restart systemd-networkd
systemctl restart hostapd
systemctl restart dnsmasq

echo "=== DONE ==="
echo "LAN (eth0) → DHCP"
echo "AP (${AP_IF}) → ${AP_IP}"
echo "Rebooting in 5 seconds to validate persistence..."
sleep 5
reboot

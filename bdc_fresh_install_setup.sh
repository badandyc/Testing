#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo bash bdc_fresh_install_setup.sh"
    exit 1
fi

echo "=== BirdDog BDC Installer ==="

# Disable cloud-init if present
if [ -d /etc/cloud ]; then
    echo "Disabling cloud-init..."
    touch /etc/cloud/cloud-init.disabled
fi

# Prompt for hostname
read -p "Enter hostname (e.g. bdc-01): " NEW_HOSTNAME

if [[ -z "$NEW_HOSTNAME" ]]; then
    echo "Hostname cannot be empty."
    exit 1
fi

# Extract numeric suffix
NODE_NUM=$(echo "$NEW_HOSTNAME" | grep -oE '[0-9]+$')

if [[ -z "$NODE_NUM" ]]; then
    echo "Hostname must end in a number (e.g. bdc-01)"
    exit 1
fi

STREAM_NAME="cam$(printf "%02d" "$NODE_NUM")"

echo "Hostname: $NEW_HOSTNAME"
echo "Stream name: $STREAM_NAME"

# Set hostname deterministically
echo "$NEW_HOSTNAME" > /etc/hostname
if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1    $NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1    $NEW_HOSTNAME" >> /etc/hosts
fi
hostname "$NEW_HOSTNAME"

echo "Updating system..."
apt update
apt upgrade -y

echo "Installing packages..."
apt install -y ffmpeg rpicam-apps avahi-daemon

echo "Enabling Avahi..."
systemctl enable avahi-daemon
systemctl start avahi-daemon

BDM_HOST="bdm-01.local"

echo "Installing stream script..."

cat <<EOF > /usr/local/bin/birddog-stream.sh
#!/bin/bash
set -e

BDM_HOST="$BDM_HOST"
STREAM_NAME="$STREAM_NAME"
WIDTH=640
HEIGHT=480
FPS=30

PIPE=/tmp/birddog_stream.h264
rm -f \$PIPE
mkfifo \$PIPE

cleanup() {
    kill \$FFMPEG_PID 2>/dev/null || true
    kill \$RPICAM_PID 2>/dev/null || true
    rm -f \$PIPE
}
trap cleanup EXIT INT TERM

rpicam-vid -t 0 --nopreview \
--width \$WIDTH --height \$HEIGHT \
--framerate \$FPS \
--intra \$FPS --inline \
-o \$PIPE &
RPICAM_PID=\$!

ffmpeg -loglevel error -use_wallclock_as_timestamps 1 \
-f h264 -i \$PIPE -c copy \
-f rtsp rtsp://\$BDM_HOST:8554/\$STREAM_NAME &
FFMPEG_PID=\$!

wait \$FFMPEG_PID
EOF

chmod +x /usr/local/bin/birddog-stream.sh

echo "Installing systemd service..."

cat <<EOF > /etc/systemd/system/birddog-stream.service
[Unit]
Description=BirdDog Camera Stream
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/birddog-stream.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-stream.service

echo "=== Installation Complete ==="
echo "Rebooting in 5 seconds..."
sleep 5
reboot

#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./bdc_fresh_install_setup.sh <stream_name>)"
    exit 1
fi

STREAM_NAME=${1:-cam1}
BDM_HOST="bdm-01"

echo "=== BirdDog BDC Installer ==="
echo "Stream name: $STREAM_NAME"
echo "BDM host: $BDM_HOST"

echo "Updating system..."
apt update
apt upgrade -y

echo "Installing packages..."
apt install -y ffmpeg rpicam-apps

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

ffmpeg -use_wallclock_as_timestamps 1 \
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
reboot

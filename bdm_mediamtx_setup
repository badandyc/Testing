#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash bdm_mediamtx_setup"
  exit 1
fi

INSTALL_DIR="/opt/mediamtx"

echo "=== Creating mediamtx user ==="
id -u mediamtx &>/dev/null || useradd -r -s /usr/sbin/nologin mediamtx

echo "=== Preparing /tmp workspace ==="
cd /tmp
rm -f mediamtx.tar.gz mediamtx mediamtx.yml LICENSE

echo "=== Downloading latest MediaMTX (auto-detect) ==="
LATEST_URL=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
  | grep browser_download_url \
  | grep linux_arm64.tar.gz \
  | cut -d '"' -f 4)

if [ -z "$LATEST_URL" ]; then
  echo "Failed to determine latest MediaMTX release URL"
  exit 1
fi

curl -L -o mediamtx.tar.gz "$LATEST_URL"

echo "=== Extracting archive ==="
tar -xzf mediamtx.tar.gz

if [ ! -f "mediamtx" ]; then
  echo "Extraction failed: mediamtx binary missing"
  exit 1
fi

echo "=== Installing MediaMTX ==="
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

mv mediamtx "$INSTALL_DIR/"

echo "=== Writing deterministic configuration ==="

cat > "$INSTALL_DIR/mediamtx.yml" <<EOF
logLevel: info
logDestinations: [stdout]

###############################################
# Authentication (open – isolated AP appliance)

authMethod: internal
authInternalUsers:
  - user: any
    ips: []
    permissions:
      - action: publish
      - action: read
      - action: playback
      - action: api
      - action: metrics
      - action: pprof

###############################################
# Control API

api: true
apiAddress: :9997
apiAllowOrigins: ['*']

###############################################
# RTSP (ingest)

rtsp: true
rtspAddress: :8554

###############################################
# Disable unused protocols

rtmp: false
hls: false
srt: false
metrics: false
pprof: false
playback: false

###############################################
# WebRTC (viewer)

webrtc: true
webrtcAddress: :8889
webrtcAllowOrigins: ['*']

###############################################
# Default path behavior

pathDefaults:
  source: publisher
  overridePublisher: true

paths:
  all_others:
EOF

chown -R mediamtx:mediamtx "$INSTALL_DIR"

echo "=== Creating systemd service ==="

cat > /etc/systemd/system/mediamtx.service <<EOF
[Unit]
Description=MediaMTX Server
After=network-online.target
Wants=network-online.target

[Service]
User=mediamtx
Group=mediamtx
ExecStart=$INSTALL_DIR/mediamtx $INSTALL_DIR/mediamtx.yml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "=== Enabling and starting service ==="
systemctl daemon-reload
systemctl enable mediamtx
systemctl restart mediamtx

echo "=== DONE ==="
systemctl status mediamtx --no-pager

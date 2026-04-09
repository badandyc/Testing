#!/bin/bash
# =============================================================================
# wm8960_setup.sh
# WM8960 Audio Board setup for Raspberry Pi 3B
# Target OS: Raspberry Pi OS Trixie (Debian 13), Kernel 6.12
#
# What this does:
#   - Fetches Waveshare's fixed wm8960.c codec driver from GitHub
#   - Builds and installs it via DKMS (kernel module management)
#   - Verifies the wm8960-soundcard device tree overlay is present
#   - Configures /boot/firmware/config.txt correctly
#   - Installs ALSA config
#   - Blacklists conflicting modules (soundcard module, bcm2835 audio)
#   - Does NOT install the Waveshare soundcard service (incompatible with 6.12)
#   - Does NOT configure MCLK via GPIO (WM8960 PLL derives clock from BCLK)
#
# Hardware requirements:
#   - P1 jumper holes: ALL EMPTY - no jumper, no wire
#   - GPIO 4 (Pin 7): NOT CONNECTED
#   - MCLK is derived internally by WM8960 PLL from I2S BCLK
#
# Wiring:
#   Board VCC   -> Pi Pin 1  (3.3V)
#   Board GND   -> Pi Pin 6  (GND)
#   Board SDA   -> Pi Pin 3  (GPIO 2)
#   Board SCL   -> Pi Pin 5  (GPIO 3)
#   Board CLK   -> Pi Pin 12 (GPIO 18) [I2S BCLK]
#   Board WS    -> Pi Pin 35 (GPIO 19) [I2S LRCLK]
#   Board RXSDA -> Pi Pin 40 (GPIO 21) [I2S DAC data: Pi->Board] *** NOTE: counterintuitive name ***
#   Board TXSDA -> Pi Pin 38 (GPIO 20) [I2S ADC data: Board->Pi] *** NOTE: counterintuitive name ***
#
#   TXSDA/RXSDA are named from the BOARD's perspective:
#     RXSDA = board receives audio = Pi transmits audio = connect to Pi GPIO 21 (I2S TX)
#     TXSDA = board transmits audio = Pi receives audio = connect to Pi GPIO 20 (I2S RX)
#   P1 jumper holes: ALL EMPTY - no jumper, no wire
#   GPIO 4 (Pin 7): NOT CONNECTED
#
# Usage:
#   chmod +x wm8960_setup.sh
#   sudo ./wm8960_setup.sh
#   sudo reboot
#
# After reboot, test playback:
#   aplay -D hw:0,0 -f S32_LE -r 16000 -c 2 <file.wav>
# Test capture:
#   arecord -D hw:0,0 -f S32_LE -r 16000 -c 2 -d 5 test.wav
# =============================================================================

set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo ./wm8960_setup.sh"
    exit 1
fi

IS_RPI=$(cat /proc/device-tree/model 2>/dev/null | awk '{print $1}')
if [ "x${IS_RPI}" != "xRaspberry" ]; then
    echo "ERROR: This script is for Raspberry Pi only"
    exit 1
fi

KERNEL_VER=$(uname -r)
MOD_VER="1.0"
MOD_NAME="wm8960-soundcard"
SRC_DIR="/usr/src/${MOD_NAME}-${MOD_VER}"
WM8960_C_URL="https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/wm8960_pll.c"
WM8960_H_URL="https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/wm8960_pll.h"

echo "======================================================"
echo "  WM8960 Audio Board Setup"
echo "  Kernel: ${KERNEL_VER}"
echo "======================================================"

# =============================================================================
# STEP 1 - Dependencies
# =============================================================================
echo ""
echo "[1/7] Installing build dependencies..."
apt-get update -qq
apt-get install -y dkms wget
    apt-get install -y linux-headers-$(uname -r)

# =============================================================================
# STEP 2 - Fetch driver source and write supporting files
# =============================================================================
echo ""
echo "[2/7] Setting up DKMS source directory..."

if dkms status 2>/dev/null | grep -q "${MOD_NAME}/${MOD_VER}"; then
    echo "      Removing existing DKMS entry..."
    dkms remove --force -m ${MOD_NAME} -v ${MOD_VER} --all 2>/dev/null || true
fi
rm -rf ${SRC_DIR}
mkdir -p ${SRC_DIR}

echo "      Fetching wm8960_pll.c and wm8960_pll.h..."
wget -q -O ${SRC_DIR}/wm8960_pll.c "${WM8960_C_URL}"
wget -q -O ${SRC_DIR}/wm8960_pll.h "${WM8960_H_URL}"
if [ ! -s ${SRC_DIR}/wm8960_pll.c ] || [ ! -s ${SRC_DIR}/wm8960_pll.h ]; then
    echo "ERROR: Failed to download wm8960_pll.c or wm8960_pll.h"
    exit 1
fi
echo "      wm8960_pll.c fetched ($(wc -l < ${SRC_DIR}/wm8960_pll.c) lines)"
echo "      wm8960_pll.h fetched"

cat > ${SRC_DIR}/Makefile << 'EOF'
obj-m := snd-soc-wm8960.o
snd-soc-wm8960-objs := wm8960_pll.o
EOF

cat > ${SRC_DIR}/dkms.conf << 'EOF'
PACKAGE_NAME="wm8960-soundcard"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="snd-soc-wm8960"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
EOF

# =============================================================================
# STEP 3 - Build and install via DKMS
# =============================================================================
echo ""
echo "[3/7] Building and installing WM8960 codec driver via DKMS..."
echo "      (This may take a few minutes on Pi 3B)"

dkms add -m ${MOD_NAME} -v ${MOD_VER}
dkms build ${KERNEL_VER} -m ${MOD_NAME} -v ${MOD_VER}
dkms install --force ${KERNEL_VER} -m ${MOD_NAME} -v ${MOD_VER}

echo "      DKMS build complete"

# =============================================================================
# STEP 4 - Device tree overlay
# =============================================================================
echo ""
echo "[4/7] Verifying device tree overlay..."

DTBO="/boot/firmware/overlays/wm8960-soundcard.dtbo"
if [ ! -f "${DTBO}" ]; then
    echo "ERROR: ${DTBO} not found."
    echo "       Ensure raspberrypi-kernel is installed and up to date."
    exit 1
fi
echo "      Found: ${DTBO}"

# =============================================================================
# STEP 5 - Configure /boot/firmware/config.txt
# =============================================================================
echo ""
echo "[5/7] Configuring /boot/firmware/config.txt..."

CFG="/boot/firmware/config.txt"

# Disable onboard BCM audio
sed -i 's/^dtparam=audio=on/#dtparam=audio=on/' ${CFG}

# Enable I2C
if ! grep -q "^dtparam=i2c_arm=on" ${CFG}; then
    if grep -q "^#dtparam=i2c_arm=on" ${CFG}; then
        sed -i 's/^#dtparam=i2c_arm=on/dtparam=i2c_arm=on/' ${CFG}
    else
        echo "dtparam=i2c_arm=on" >> ${CFG}
    fi
fi

# Add wm8960-soundcard overlay
if ! grep -q "^dtoverlay=wm8960-soundcard" ${CFG}; then
    echo "dtoverlay=wm8960-soundcard" >> ${CFG}
fi
# Remove custom overlay if present from previous attempt
sed -i '/^dtoverlay=wm8960-birddog/d' ${CFG}

# Remove stale entries from previous attempts
sed -i '/^dtoverlay=gpio-clock/d' ${CFG}
sed -i '/^dtoverlay=i2s-mmap/d' ${CFG}
sed -i '/^dtparam=i2s=on/d' ${CFG}

echo "      config.txt updated"
echo "      Audio-related entries:"
grep -E "audio|i2s|wm8960|i2c_arm" ${CFG} | sed 's/^/        /'

# =============================================================================
# STEP 6 - Blacklist conflicting modules
# =============================================================================
echo ""
echo "[6/7] Blacklisting conflicting modules..."

cat > /etc/modprobe.d/blacklist-wm8960-soundcard.conf << 'EOF'
# snd_soc_wm8960_soundcard conflicts with kernel 6.12 built-in simple-card driver
blacklist snd_soc_wm8960_soundcard
EOF

cat > /etc/modprobe.d/blacklist-bcm2835-audio.conf << 'EOF'
# Disable onboard BCM2835 audio to prevent conflict with WM8960
blacklist snd_bcm2835
EOF

sed -i '/^snd-soc-wm8960/d' /etc/modules 2>/dev/null || true
sed -i '/^snd-soc-wm8960-soundcard/d' /etc/modules 2>/dev/null || true

if systemctl list-unit-files 2>/dev/null | grep -q "wm8960-soundcard.service"; then
    systemctl disable wm8960-soundcard.service 2>/dev/null || true
    systemctl stop wm8960-soundcard.service 2>/dev/null || true
    echo "      Waveshare soundcard service disabled"
fi

echo "      Blacklists written"

# =============================================================================
# STEP 7 - ALSA config
# =============================================================================
echo ""
echo "[7/7] Installing ALSA config..."

mkdir -p /etc/wm8960-soundcard

cat > /etc/wm8960-soundcard/asound.conf << 'EOF'
pcm.!default {
  type asym
  capture.pcm "mic"
  playback.pcm "speaker"
}
pcm.mic {
  type plug
  slave {
    pcm "hw:0,0"
    rate 16000
    channels 2
    format S32_LE
  }
}
pcm.speaker {
  type plug
  slave {
    pcm "hw:0,0"
    rate 16000
    channels 2
    format S32_LE
  }
}
EOF

rm -f /etc/asound.conf
ln -s /etc/wm8960-soundcard/asound.conf /etc/asound.conf
echo "      ALSA config installed"

# Install mixer state file - sets output routing and capture gain at boot
cat > /etc/wm8960-soundcard/mixer_init.sh << 'EOF'
#!/bin/bash
# WM8960 mixer initialization - runs at boot via systemd
# Wait for sound card to be ready
sleep 3
CARD=0

# Output routing - PCM playback through left/right output mixers to TRRS
amixer -c ${CARD} cset numid=51 on 2>/dev/null  # Left Output Mixer PCM Playback
amixer -c ${CARD} cset numid=54 on 2>/dev/null  # Right Output Mixer PCM Playback

# Headphone volume (120/127) - TRRS output
amixer -c ${CARD} cset numid=11 120,120 2>/dev/null

# Capture input boost - LINPUT1 for MEMS mic (default)
# Switch to LINPUT3 when handset mic is wired
amixer -c ${CARD} cset numid=49 on 2>/dev/null  # Left Input Mixer Boost
amixer -c ${CARD} cset numid=50 on 2>/dev/null  # Right Input Mixer Boost
amixer -c ${CARD} cset numid=45 on 2>/dev/null  # Left Boost Mixer LINPUT1
amixer -c ${CARD} cset numid=9 3 2>/dev/null    # Left Input Boost LINPUT1 Volume

# Capture volume - max gain
amixer -c ${CARD} cset numid=1 63,63 2>/dev/null

# NOTE: J1 BTL output is no longer used. External amp (TPA3110) will be
# fed from TRRS headphone output when hardware arrives.
# TODO: when handset mic (MH-48) is wired, switch input from LINPUT1 to LINPUT3
EOF
chmod +x /etc/wm8960-soundcard/mixer_init.sh

# Install systemd service for mixer init
cat > /etc/systemd/system/wm8960-mixer.service << 'EOF'
[Unit]
Description=WM8960 mixer initialization
After=sound.target
Wants=sound.target

[Service]
Type=oneshot
ExecStart=/etc/wm8960-soundcard/mixer_init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable wm8960-mixer.service
echo "      Mixer init service installed"

# Install wm8960 CLI
cat > /usr/local/bin/wm8960 << 'EOF'
#!/bin/bash
# wm8960 - CLI for WM8960 audio board
# Usage: wm8960 record [file]
#        wm8960 play [file]

RECORD_FILE="/home/${SUDO_USER:-$(logname 2>/dev/null || echo pi)}/wm8960_recording.wav"
PLAY_FILE="/home/${SUDO_USER:-$(logname 2>/dev/null || echo pi)}/wm8960_recording.wav"
DURATION=5

# Auto-detect wm8960 card number
CARD=$(aplay -l 2>/dev/null | grep -i "wm8960" | head -1 | awk '{print $2}' | tr -d ':')
if [ -z "${CARD}" ]; then
    echo "ERROR: WM8960 sound card not found"
    exit 1
fi

case "$1" in
    record)
        [ -n "$2" ] && RECORD_FILE="$2"
        echo "Recording ${DURATION}s to ${RECORD_FILE} ..."
        arecord -D hw:${CARD},0 -f S32_LE -r 16000 -c 2 -d ${DURATION} "${RECORD_FILE}"
        echo "Done."
        ;;
    play)
        [ -n "$2" ] && PLAY_FILE="$2"
        if [ ! -f "${PLAY_FILE}" ]; then
            echo "ERROR: File not found: ${PLAY_FILE}"
            exit 1
        fi
        echo "Playing ${PLAY_FILE} ..."
        aplay -D plughw:${CARD},0 "${PLAY_FILE}"
        ;;
    *)
        echo "Usage: wm8960 record [file]"
        echo "       wm8960 play [file]"
        echo ""
        echo "  record  - Record 5 seconds from MEMS mic"
        echo "  play    - Play back last recording (or specified file)"
        echo ""
        echo "  Default file: ~/wm8960_recording.wav (overwritten each record)"
        exit 1
        ;;
esac
EOF
chmod +x /usr/local/bin/wm8960
echo "      wm8960 CLI installed (/usr/local/bin/wm8960)"

# Install PTT service
PTT_URL="https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/wm8960_ptt.py"
wget -q -O /usr/local/bin/wm8960_ptt.py "${PTT_URL}"
if [ ! -s /usr/local/bin/wm8960_ptt.py ]; then
    echo "      WARNING: Could not download wm8960_ptt.py"
else
    chmod +x /usr/local/bin/wm8960_ptt.py

    cat > /etc/systemd/system/wm8960-ptt.service << 'EOF'
[Unit]
Description=WM8960 Push-To-Talk Service
After=sound.target wm8960-mixer.service
Wants=sound.target wm8960-mixer.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/wm8960_ptt.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable wm8960-ptt.service
    echo "      PTT service installed (/usr/local/bin/wm8960_ptt.py)"
fi

# Download test wav file to home directory
echo ""
echo "      Downloading test audio file..."
WAV_URL="https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/sound_check.wav"
wget -q -O /home/${SUDO_USER:-pi}/sound_check.wav "${WAV_URL}" && \
    echo "      sound_check.wav downloaded to home directory" || \
    echo "      WARNING: Could not download sound_check.wav"

# =============================================================================
# Done
# =============================================================================
echo ""
echo "======================================================"
echo "  Setup complete."
echo ""
echo "  Driver:   snd-soc-wm8960 installed via DKMS"
echo "  Overlay:  dtoverlay=wm8960-soundcard active"
echo "  BCM audio: disabled"
echo "  Soundcard module: blacklisted (kernel 6.12 incompatible)"
echo "  MCLK: derived by WM8960 PLL from BCLK — no GPIO needed"
echo "  Mixer: auto-initialized at boot via wm8960-mixer.service"
echo ""
echo "  WIRING REMINDER:"
echo "    RXSDA (board) -> Pi Pin 40 GPIO 21  [DAC: Pi to Board]"
echo "    TXSDA (board) -> Pi Pin 38 GPIO 20  [ADC: Board to Pi]"
echo "    P1 jumper: ALL EMPTY"
echo ""
echo "  Reboot then test playback:"
echo "    wm8960 play sound_check.wav"
echo "  Test capture:"
echo "    wm8960 record"
echo "    wm8960 play"
echo "======================================================"
echo ""
echo "Run: sudo reboot"

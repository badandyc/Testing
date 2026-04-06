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
#   Board TXSDA -> Pi Pin 40 (GPIO 21) [I2S DAC data out]
#   Board RXSDA -> Pi Pin 38 (GPIO 20) [I2S ADC data in]
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
# STEP 4 - Build and install custom device tree overlay
# =============================================================================
echo ""
echo "[4/7] Building custom device tree overlay..."

apt-get install -y device-tree-compiler 2>/dev/null

# Write custom DTS - uses "Line" widgets instead of "Headphone"/"Speaker"
# so DAPM treats outputs as always-on (no jack detection required)
cat > /tmp/wm8960-birddog.dts << 'DTSEOF'
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835";

    fragment@0 {
        target = <&i2s_clk_producer>;
        __overlay__ {
            status = "okay";
        };
    };

    fragment@1 {
        target-path = "/";
        __overlay__ {
            wm8960_mclk: wm8960_mclk {
                compatible = "fixed-clock";
                #clock-cells = <0>;
                clock-frequency = <12288000>;
            };
        };
    };

    fragment@2 {
        target = <&i2c1>;
        __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;
            status = "okay";

            wm8960: wm8960@1a {
                compatible = "wlf,wm8960";
                reg = <0x1a>;
                #sound-dai-cells = <0>;
                AVDD-supply = <&vdd_5v0_reg>;
                DVDD-supply = <&vdd_3v3_reg>;
                clocks = <&wm8960_mclk>;
                clock-names = "mclk";
            };
        };
    };

    fragment@3 {
        target = <&sound>;
        __overlay__ {
            compatible = "simple-audio-card";
            simple-audio-card,format = "i2s";
            simple-audio-card,name = "wm8960-soundcard";
            status = "okay";

            simple-audio-card,widgets =
                "Line", "Line Out",
                "Line", "Line In",
                "Microphone", "Mic Jack";

            simple-audio-card,routing =
                "Line Out", "HP_L",
                "Line Out", "HP_R",
                "Line Out", "SPK_LP",
                "Line Out", "SPK_LN",
                "LINPUT1", "Mic Jack",
                "LINPUT3", "Mic Jack",
                "RINPUT1", "Mic Jack",
                "RINPUT2", "Mic Jack";

            simple-audio-card,cpu {
                sound-dai = <&i2s_clk_producer>;
            };

            simple-audio-card,codec {
                sound-dai = <&wm8960>;
            };
        };
    };
};
DTSEOF

dtc -@ -I dts -O dtb -o /boot/firmware/overlays/wm8960-birddog.dtbo /tmp/wm8960-birddog.dts
if [ ! -f /boot/firmware/overlays/wm8960-birddog.dtbo ]; then
    echo "ERROR: Failed to compile device tree overlay"
    exit 1
fi
echo "      Custom overlay compiled: wm8960-birddog.dtbo"

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

# Add wm8960-birddog overlay
if ! grep -q "^dtoverlay=wm8960-birddog" ${CFG}; then
    echo "dtoverlay=wm8960-birddog" >> ${CFG}
fi
# Remove stock overlay if present
sed -i '/^dtoverlay=wm8960-soundcard/d' ${CFG}

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
echo ""
echo "  Reboot then test:"
echo "    aplay -D hw:0,0 -f S32_LE -r 16000 -c 2 <file.wav>"
echo "    arecord -D hw:0,0 -f S32_LE -r 16000 -c 2 -d 5 test.wav"
echo "======================================================"
echo ""
echo "Run: sudo reboot"

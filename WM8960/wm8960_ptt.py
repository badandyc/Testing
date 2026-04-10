#!/usr/bin/env python3
# =============================================================================
# wm8960_ptt.py
# WM8960 Push-To-Talk background service
#
# Hardware:
#   PTT button: GPIO 16 (Pin 36), active high, pull-down resistor
#               MH-48 Pin 6 → GPIO 16; pin goes HIGH when PTT pressed
#
# MH-48 handset wiring:
#   Pin 3 = 5V power (GPIO Pin 4)
#   Pin 4 = GND
#   Pin 5 = MIC → TRRS Sleeve (WM8960 MIC IN)
#   Pin 6 = PTT → GPIO 16 (active high, pull-down)
#
# TRRS wiring:
#   Tip     = LP Out  → TPA3110 amp
#   Ring 1  = RP Out  → TPA3110 amp
#   Ring 2  = GND
#   Sleeve  = MIC IN  ← MH-48 Pin 5
#
# Behavior:
#   - Press and hold PTT = record
#   - Release PTT = stop recording, save to RECORD_FILE, play back
#   - File is overwritten on each press
#
# Usage:
#   sudo python3 wm8960_ptt.py          # run in foreground
#   sudo systemctl start wm8960-ptt     # run as service
# =============================================================================

import subprocess
import time
import os
import sys
import signal
import logging

import RPi.GPIO as GPIO

# =============================================================================
# Configuration
# =============================================================================
PTT_GPIO        = 16                              # GPIO 16, Pin 36
RECORD_FILE     = "/home/birddog/wm8960_recording.wav"
RECORD_FORMAT   = "S32_LE"
RECORD_RATE     = 16000
RECORD_CHANNELS = 2
DEBOUNCE_MS     = 50                              # ms debounce for PTT press

LOG_LEVEL = logging.INFO

# =============================================================================
# Logging
# =============================================================================
logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s [PTT] %(levelname)s %(message)s",
    datefmt="%H:%M:%S"
)
log = logging.getLogger("wm8960_ptt")

# =============================================================================
# Card detection
# =============================================================================
def find_wm8960_card():
    """Find the ALSA card number for the WM8960."""
    try:
        result = subprocess.run(
            ["aplay", "-l"],
            capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            if "wm8960" in line.lower():
                card = line.split()[1].rstrip(":")
                return int(card)
    except Exception:
        pass
    return None

# =============================================================================
# Recording
# =============================================================================
record_proc = None
active_card  = None

def start_recording(card):
    global record_proc, active_card
    if record_proc is not None:
        return
    active_card = card

    log.info("PTT pressed — recording started")
    log.info(f"  File: {RECORD_FILE}")

    cmd = [
        "arecord",
        "-D", f"hw:{card},0",
        "-f", RECORD_FORMAT,
        "-r", str(RECORD_RATE),
        "-c", str(RECORD_CHANNELS),
        RECORD_FILE
    ]

    record_proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

def stop_recording():
    global record_proc, active_card
    if record_proc is None:
        return

    record_proc.terminate()
    try:
        record_proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        record_proc.kill()
    record_proc = None

    log.info("PTT released — recording saved")
    log.info(f"  File: {RECORD_FILE}")

    time.sleep(1)
    log.info("Playing back recording...")
    subprocess.Popen(
        ["aplay", "-D", f"plughw:{active_card},0", RECORD_FILE],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

# =============================================================================
# Cleanup
# =============================================================================
def cleanup(signum=None, frame=None):
    log.info("Shutting down PTT service")
    stop_recording()
    GPIO.cleanup()
    sys.exit(0)

# =============================================================================
# Main
# =============================================================================
def main():
    log.info("WM8960 PTT service starting")

    card = find_wm8960_card()
    if card is None:
        log.error("WM8960 sound card not found — is the driver loaded?")
        sys.exit(1)
    log.info(f"WM8960 found at card {card}")

    GPIO.setmode(GPIO.BCM)
    GPIO.setup(PTT_GPIO, GPIO.IN, pull_up_down=GPIO.PUD_DOWN)
    log.info(f"PTT monitoring GPIO {PTT_GPIO} (Pin 36), active high")

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    ptt_active = False

    log.info("Ready — press PTT button to record")

    try:
        while True:
            ptt_pressed = (GPIO.input(PTT_GPIO) == GPIO.HIGH)

            if ptt_pressed and not ptt_active:
                time.sleep(DEBOUNCE_MS / 1000.0)
                if GPIO.input(PTT_GPIO) == GPIO.HIGH:
                    ptt_active = True
                    start_recording(card)

            elif not ptt_pressed and ptt_active:
                ptt_active = False
                stop_recording()

            time.sleep(0.01)

    except Exception as e:
        log.error(f"Unexpected error: {e}")
        cleanup()

if __name__ == "__main__":
    main()

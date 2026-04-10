#!/usr/bin/env python3
# =============================================================================
# wm8960_ptt.py
# WM8960 Push-To-Talk service with GStreamer RTP audio transport
#
# Hardware:
#   PTT button: GPIO 7 (Pin 26), active low, pull-up resistor
#               MH-48 Pin 6 -> GPIO 7; pin goes LOW when PTT pressed
#
# MH-48 handset wiring:
#   Pin 3 = 5V power (GPIO Pin 4)
#   Pin 4 = GND
#   Pin 5 = MIC -> TRRS Sleeve (WM8960 MIC IN)
#   Pin 6 = PTT -> GPIO 7 (active low, pull-up)
#
# TRRS wiring:
#   Tip     = LP Out  -> TPA3110 amp
#   Ring 1  = RP Out  -> TPA3110 amp
#   Ring 2  = GND
#   Sleeve  = MIC IN  <- MH-48 Pin 5
#
# Behavior:
#   - Receive pipeline runs continuously (incoming audio -> speaker)
#   - PTT press: start transmit pipeline (mic -> RTP -> peer)
#   - PTT release: stop transmit pipeline
#
# Usage:
#   sudo python3 wm8960_ptt.py --peer 192.168.8.185   # run in foreground
#   sudo systemctl start wm8960-ptt                    # run as service
# =============================================================================

import sys
import time
import signal
import logging
import argparse

import gi
gi.require_version('Gst', '1.0')
from gi.repository import Gst

import RPi.GPIO as GPIO

# =============================================================================
# Configuration
# =============================================================================
PTT_GPIO        = 7                               # GPIO 7, Pin 26
PEER_IP         = "192.168.8.185"                 # default peer IP (override with --peer)
RTP_PORT        = 5004                            # RTP port (same on all nodes)
ALSA_SRC_DEV    = "wm8960_dsnoop"                 # ALSA capture device (shared via dsnoop)
ALSA_SINK_DEV   = "wm8960_dmix"                   # ALSA playback device (shared via dmix)
SAMPLE_RATE     = 16000
CHANNELS        = 2
DEBOUNCE_MS     = 150                             # ms debounce for PTT press/release

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
# GStreamer pipeline management
# =============================================================================
rx_pipeline = None
tx_pipeline = None

def build_rx_pipeline():
    """Receive pipeline: UDP RTP -> Opus decode -> ALSA speaker (runs always)"""
    pipe_str = (
        f"udpsrc port={RTP_PORT} "
        f"! application/x-rtp,encoding-name=OPUS,payload=96 "
        f"! rtpopusdepay ! opusdec "
        f"! audioconvert "
        f"! alsasink device={ALSA_SINK_DEV}"
    )
    log.info(f"RX pipeline: {pipe_str}")
    return Gst.parse_launch(pipe_str)

def build_tx_pipeline(peer_ip):
    """Transmit pipeline: ALSA mic -> Opus encode -> UDP RTP -> peer (PTT controlled)"""
    pipe_str = (
        f"alsasrc device={ALSA_SRC_DEV} "
        f"! audio/x-raw,rate={SAMPLE_RATE},channels={CHANNELS},format=S32LE "
        f"! audioconvert ! opusenc "
        f"! rtpopuspay "
        f"! udpsink host={peer_ip} port={RTP_PORT}"
    )
    log.info(f"TX pipeline: {pipe_str}")
    return Gst.parse_launch(pipe_str)

def start_rx(peer_ip):
    global rx_pipeline
    if rx_pipeline is not None:
        return
    rx_pipeline = build_rx_pipeline()
    rx_pipeline.set_state(Gst.State.PLAYING)
    log.info("RX pipeline started — listening for incoming audio")

def stop_rx():
    global rx_pipeline
    if rx_pipeline is None:
        return
    rx_pipeline.set_state(Gst.State.NULL)
    rx_pipeline = None
    log.info("RX pipeline stopped")

def start_tx(peer_ip):
    global tx_pipeline
    if tx_pipeline is not None:
        return
    tx_pipeline = build_tx_pipeline(peer_ip)
    tx_pipeline.set_state(Gst.State.PLAYING)
    log.info(f"TX pipeline started — transmitting to {peer_ip}:{RTP_PORT}")

def stop_tx():
    global tx_pipeline
    if tx_pipeline is None:
        return
    tx_pipeline.set_state(Gst.State.NULL)
    tx_pipeline = None
    log.info("TX pipeline stopped")

# =============================================================================
# Cleanup
# =============================================================================
def cleanup(signum=None, frame=None):
    log.info("Shutting down PTT service")
    stop_tx()
    stop_rx()
    GPIO.cleanup()
    sys.exit(0)

# =============================================================================
# Main
# =============================================================================
def main():
    parser = argparse.ArgumentParser(description="WM8960 PTT service")
    parser.add_argument("--peer", default=PEER_IP, help="Peer node IP address")
    args = parser.parse_args()

    Gst.init(None)

    log.info("WM8960 PTT service starting")
    log.info(f"  Peer: {args.peer}:{RTP_PORT}")

    GPIO.setmode(GPIO.BCM)
    GPIO.setup(PTT_GPIO, GPIO.IN, pull_up_down=GPIO.PUD_UP)
    log.info(f"PTT monitoring GPIO {PTT_GPIO} (Pin 26), active low")

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    start_rx(args.peer)

    ptt_active = False

    log.info("Ready — press PTT to transmit")

    try:
        while True:
            ptt_pressed = (GPIO.input(PTT_GPIO) == GPIO.LOW)

            if ptt_pressed and not ptt_active:
                time.sleep(DEBOUNCE_MS / 1000.0)
                if GPIO.input(PTT_GPIO) == GPIO.LOW:
                    ptt_active = True
                    log.info("PTT pressed — transmitting")
                    start_tx(args.peer)

            elif not ptt_pressed and ptt_active:
                time.sleep(DEBOUNCE_MS / 1000.0)
                if GPIO.input(PTT_GPIO) == GPIO.HIGH:
                    ptt_active = False
                    log.info("PTT released — stopped transmitting")
                    stop_tx()

            time.sleep(0.01)

    except Exception as e:
        log.error(f"Unexpected error: {e}")
        cleanup()

if __name__ == "__main__":
    main()

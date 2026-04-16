#!/usr/bin/env python3
# =============================================================================
# ads1115_detect.py
# MH-48 handset button detector using ADS1115 ADC
#
# Detection method:
#   - Mahalanobis distance with per-button variance weighting
#   - Global rejection threshold (circular, not square)
#   - Normalized axes
#   - Centroid smoothing (5-sample rolling average)
#   - UP/DOWN special handling with tighter threshold and higher debounce
#
# Two modes:
#   monitor - continuous monitoring mode (default)
#   verify  - guided verification, prompts for each button and shows detection
#
# Reads calibration from /home/birddog/ads1115_calibration.txt
# Run ads1115_calibrate.py to regenerate calibration file.
#
# ADS1115 I2C address: 0x48, bus: 1
# MH-48 powered at 5V (GPIO Pin 4)
# SW1 -> ADS1115 A0
# SW2 -> ADS1115 A1
#
# Usage:
#   python3 ads1115_detect.py           # monitor mode
#   python3 ads1115_detect.py verify    # guided verification mode
# =============================================================================

import time
import sys
import math
import smbus2
from collections import deque

# =============================================================================
# ADS1115 configuration
# =============================================================================
ADS1115_ADDR    = 0x48
BUS             = 1

REG_CONVERT     = 0x00
REG_CONFIG      = 0x01

OS_SINGLE       = 0x8000
MUX_A0_GND      = 0x4000
MUX_A1_GND      = 0x5000
PGA_4096        = 0x0200
MODE_SINGLE     = 0x0100
DR_128SPS       = 0x0080
COMP_DISABLE    = 0x0003

CALIBRATION_FILE = "/home/birddog/ads1115_calibration.txt"

# =============================================================================
# Detection parameters
# =============================================================================
# Global rejection threshold — readings further than this from any button = IDLE
MAX_DISTANCE        = 0.010

# UP/DOWN are noisy — use tighter rejection and higher debounce
UPDOWN_MAX_DISTANCE = 0.015
UPDOWN_DEBOUNCE     = 6

# Standard debounce count
DEBOUNCE_COUNT      = 3

# Smoothing window size
SMOOTH_WINDOW       = 5

# Axis normalization scale (based on typical DTMF voltage range)
A0_SCALE = 1.0 / 0.030
A1_SCALE = 1.0 / 0.030

# Button list for verify mode
BUTTONS = [
    "1", "2", "3", "A",
    "4", "5", "6", "B",
    "7", "8", "9", "C",
    "*", "0", "#", "D",
    "P1", "P2", "P3", "P4",
    "UP", "DOWN", "PTT"
]

# =============================================================================
# Load calibration from file
# Format: Button  A0_avg  A1_avg  Tolerance (with V suffix)
# Tolerance is used as per-button std proxy for Mahalanobis weighting
# =============================================================================
def load_calibration(filepath):
    calibration = {}
    try:
        with open(filepath, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("-") or line.startswith("Button"):
                    continue
                parts = line.split()
                if len(parts) != 4:
                    continue
                button = parts[0]
                a0  = float(parts[1].rstrip("V"))
                a1  = float(parts[2].rstrip("V"))
                tol = float(parts[3].rstrip("V"))
                calibration[button] = (a0, a1, tol)
        print(f"  Loaded {len(calibration)} entries from {filepath}")
    except FileNotFoundError:
        print(f"ERROR: Calibration file not found: {filepath}")
        print("       Run: dtmf calibrate")
        sys.exit(1)
    return calibration

# =============================================================================
# ADS1115 read
# =============================================================================
def read_voltage(bus, mux):
    config = OS_SINGLE | mux | PGA_4096 | MODE_SINGLE | DR_128SPS | COMP_DISABLE
    config_bytes = [(config >> 8) & 0xFF, config & 0xFF]
    bus.write_i2c_block_data(ADS1115_ADDR, REG_CONFIG, config_bytes)
    time.sleep(0.01)
    data = bus.read_i2c_block_data(ADS1115_ADDR, REG_CONVERT, 2)
    raw = (data[0] << 8) | data[1]
    if raw > 32767:
        raw -= 65536
    return raw * 4.096 / 32767.0

def read_both(bus):
    return read_voltage(bus, MUX_A0_GND), read_voltage(bus, MUX_A1_GND)

# =============================================================================
# Centroid smoothing — rolling average over last SMOOTH_WINDOW readings
# =============================================================================
history = deque(maxlen=SMOOTH_WINDOW)

def get_smoothed(bus):
    v_a0, v_a1 = read_both(bus)
    history.append((v_a0, v_a1))
    avg_a0 = sum(v[0] for v in history) / len(history)
    avg_a1 = sum(v[1] for v in history) / len(history)
    return avg_a0, avg_a1

# =============================================================================
# Button matching — Mahalanobis distance with normalized axes
# Pure nearest neighbor, then global rejection threshold
# =============================================================================
def match_button(v_a0, v_a1, calibration):
    best_button = None
    best_distance = float('inf')

    for button, (cal_a0, cal_a1, tol) in calibration.items():
        if button == "IDLE":
            continue

        # Mahalanobis-style: normalize by per-button tolerance (std proxy)
        # then apply axis scale
        scale = max(tol, 0.005)  # floor to avoid div by zero
        distance = math.sqrt(
            (((v_a0 - cal_a0) * A0_SCALE) / scale) ** 2 +
            (((v_a1 - cal_a1) * A1_SCALE) / scale) ** 2
        )

        if distance < best_distance:
            best_distance = distance
            best_button = button

    # Apply rejection threshold
    if best_button in ["UP", "DOWN"]:
        threshold = UPDOWN_MAX_DISTANCE * A0_SCALE
    else:
        threshold = MAX_DISTANCE * A0_SCALE

    # Normalize threshold to match Mahalanobis scale
    # Use a fixed scale reference for the threshold comparison
    normalized_threshold = threshold / max(
        calibration.get(best_button, (0, 0, 0.005))[2], 0.005
    ) if best_button else threshold

    # Simpler: use raw Euclidean for final rejection check
    if best_button:
        cal_a0, cal_a1, _ = calibration[best_button]
        raw_distance = math.sqrt((v_a0 - cal_a0) ** 2 + (v_a1 - cal_a1) ** 2)

        if best_button in ["UP", "DOWN"] and raw_distance > UPDOWN_MAX_DISTANCE:
            return "IDLE", raw_distance
        elif best_button not in ["UP", "DOWN", "PTT"] and raw_distance > MAX_DISTANCE:
            return "IDLE", raw_distance

        return best_button, raw_distance

    return "IDLE", 0.0

# =============================================================================
# Monitor mode
# =============================================================================
def monitor_mode(bus, calibration):
    print("=" * 50)
    print("  MH-48 Button Detector — Monitor Mode")
    print("  Press buttons on the handset")
    print("  Ctrl+C to exit")
    print("=" * 50)
    print()

    last_confirmed = None
    candidate = None
    candidate_count = 0

    time.sleep(0.5)  # allow readings to settle

    try:
        while True:
            v_a0, v_a1 = get_smoothed(bus)
            button, distance = match_button(v_a0, v_a1, calibration)

            # Use higher debounce for UP/DOWN
            required = UPDOWN_DEBOUNCE if button in ["UP", "DOWN"] else DEBOUNCE_COUNT

            if button == candidate:
                candidate_count += 1
            else:
                candidate = button
                candidate_count = 1

            if candidate_count >= required:
                if candidate != last_confirmed:
                    if candidate and candidate != "IDLE":
                        print(f"  PRESS:   [{candidate}]  A0={v_a0:.4f}V  A1={v_a1:.4f}V  dist={distance:.4f}")
                    elif last_confirmed and last_confirmed != "IDLE":
                        print(f"  RELEASE: [{last_confirmed}]")
                    last_confirmed = candidate

            time.sleep(0.02)

    except KeyboardInterrupt:
        print("\nExiting.")

# =============================================================================
# Verify mode
# =============================================================================
def verify_mode(bus, calibration):
    print("=" * 50)
    print("  MH-48 Button Detector — Verify Mode")
    print("  Follow prompts to verify each button")
    print("=" * 50)
    print()

    results = {}

    for button in BUTTONS:
        history.clear()  # clear smoothing window between buttons
        input(f"  Press and HOLD [{button}] then hit Enter...")
        detections = []

        for _ in range(10):
            v_a0, v_a1 = get_smoothed(bus)
            detected, distance = match_button(v_a0, v_a1, calibration)
            detections.append((detected, distance, v_a0, v_a1))
            time.sleep(0.05)

        counts = {}
        for d, _, _, _ in detections:
            counts[d] = counts.get(d, 0) + 1
        most_common = max(counts, key=counts.get)
        confidence = counts[most_common] / len(detections) * 100

        match = "✓" if most_common == button else "✗"
        print(f"  Expected [{button}] → Detected [{most_common}]  {match}  confidence={confidence:.0f}%")
        sample = detections[0]
        print(f"    A0={sample[2]:.4f}V  A1={sample[3]:.4f}V  dist={sample[1]:.4f}")
        results[button] = most_common == button
        print()

    passed = sum(1 for v in results.values() if v)
    print(f"  Result: {passed}/{len(BUTTONS)} buttons correct")

# =============================================================================
# Main
# =============================================================================
def main():
    bus = smbus2.SMBus(BUS)
    calibration = load_calibration(CALIBRATION_FILE)
    mode = sys.argv[1] if len(sys.argv) > 1 else "monitor"

    if mode == "verify":
        verify_mode(bus, calibration)
    else:
        monitor_mode(bus, calibration)

    bus.close()

if __name__ == "__main__":
    main()

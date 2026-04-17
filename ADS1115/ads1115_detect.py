#!/usr/bin/env python3
# =============================================================================
# ads1115_detect.py
# MH-48 handset button detector using ADS1115 ADC
#
# Detection method:
#   - Full 2x2 covariance Mahalanobis distance throughout (one system)
#   - Mahalanobis for IDLE detection (not square window)
#   - Determinant floor instead of hard fallback
#   - Smoothing window warm-up (no classification until buffer full)
#   - UP/DOWN: A1 tolerance scaled by std, higher debounce
#   - Confidence score output (exp(-0.5 * dist^2))
#
# Reads calibration from /home/birddog/ads1115_calibration.txt
# Format: Button  A0_avg  A1_avg  A0_std  A1_std  COV
#
# Usage:
#   dtmf detect
#   dtmf detect verify
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
MUX_A1_GND      = 0x7000  # SW2 on A3 to maximize channel separation
PGA_4096        = 0x0200
MODE_SINGLE     = 0x0100
DR_128SPS       = 0x0080
COMP_DISABLE    = 0x0003

CALIBRATION_FILE = "/home/birddog/ads1115_calibration.txt"

# =============================================================================
# Detection parameters
# =============================================================================
MAX_MAHAL           = 2.5    # rejection threshold — standard buttons
UPDOWN_MAX_MAHAL    = 3.0    # UP/DOWN are noisier
IDLE_MAX_MAHAL      = 2.5    # IDLE Mahalanobis threshold
UPDOWN_A1_STD_MULT  = 2.0    # UP/DOWN A1 consistency: reject if > N * s_a1
DET_FLOOR           = 1e-10  # determinant floor — prevents fallback discontinuity

DEBOUNCE_COUNT      = 3
UPDOWN_DEBOUNCE     = 6
SMOOTH_WINDOW       = 5

BUTTONS = [
    "1", "2", "3", "A",
    "4", "5", "6", "B",
    "7", "8", "9", "C",
    "*", "0", "#", "D",
    "P1", "P2", "P3", "P4",
    "UP", "DOWN", "PTT"
]

# =============================================================================
# Load calibration
# Format: Button  A0_avg  A1_avg  A0_std  A1_std  COV
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
                if len(parts) != 6:
                    continue
                button = parts[0]
                a0     = float(parts[1].rstrip("V"))
                a1     = float(parts[2].rstrip("V"))
                s_a0   = float(parts[3].rstrip("V"))
                s_a1   = float(parts[4].rstrip("V"))
                cov    = float(parts[5])
                calibration[button] = (a0, a1, s_a0, s_a1, cov)
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
    time.sleep(0.004)
    data = bus.read_i2c_block_data(ADS1115_ADDR, REG_CONVERT, 2)
    raw = (data[0] << 8) | data[1]
    if raw > 32767:
        raw -= 65536
    return raw * 4.096 / 32767.0

def read_both(bus):
    return read_voltage(bus, MUX_A0_GND), read_voltage(bus, MUX_A1_GND)

# =============================================================================
# Centroid smoothing with warm-up guard
# =============================================================================
history = deque(maxlen=SMOOTH_WINDOW)

def get_smoothed(bus):
    v_a0, v_a1 = read_both(bus)
    history.append((v_a0, v_a1))
    avg_a0 = sum(v[0] for v in history) / len(history)
    avg_a1 = sum(v[1] for v in history) / len(history)
    return avg_a0, avg_a1

def buffer_ready():
    return len(history) >= SMOOTH_WINDOW

# =============================================================================
# Full covariance Mahalanobis distance
#
# Sigma = [[var_a0,  cov  ],
#          [cov,   var_a1 ]]
#
# det = var_a0 * var_a1 - cov^2  (floored to DET_FLOOR)
#
# Sigma_inv = (1/det) * [[var_a1, -cov  ],
#                         [-cov,  var_a0]]
#
# dist^2 = d^T * Sigma_inv * d
# =============================================================================
def mahalanobis(v_a0, v_a1, cal_a0, cal_a1, s_a0, s_a1, cov):
    var_a0 = s_a0 ** 2
    var_a1 = s_a1 ** 2
    det    = max(var_a0 * var_a1 - cov ** 2, DET_FLOOR)

    d0 = v_a0 - cal_a0
    d1 = v_a1 - cal_a1

    m2 = (var_a1 * d0 ** 2 - 2 * cov * d0 * d1 + var_a0 * d1 ** 2) / det
    return math.sqrt(abs(m2))

def confidence(distance):
    return math.exp(-0.5 * distance ** 2)

# =============================================================================
# Button matching — pure Mahalanobis throughout
# =============================================================================
def match_button(v_a0, v_a1, calibration):
    # Warm-up guard
    if not buffer_ready():
        return "IDLE", 0.0

    # Step 1: Mahalanobis IDLE check
    if "IDLE" in calibration:
        idle_a0, idle_a1, s_a0, s_a1, cov = calibration["IDLE"]
        idle_dist = mahalanobis(v_a0, v_a1, idle_a0, idle_a1, s_a0, s_a1, cov)
        if idle_dist < IDLE_MAX_MAHAL:
            return "IDLE", 0.0

    # Step 2: nearest neighbor by Mahalanobis distance
    best_button   = None
    best_distance = float('inf')

    for button, (cal_a0, cal_a1, s_a0, s_a1, cov) in calibration.items():
        if button == "IDLE":
            continue
        distance = mahalanobis(v_a0, v_a1, cal_a0, cal_a1, s_a0, s_a1, cov)
        if distance < best_distance:
            best_distance = distance
            best_button   = button

    if best_button is None:
        return "IDLE", 0.0

    # Step 3: Mahalanobis rejection threshold
    if best_button in ["UP", "DOWN"]:
        if best_distance > UPDOWN_MAX_MAHAL:
            return "IDLE", best_distance
        # A1 consistency check scaled by std
        _, cal_a1, _, s_a1, _ = calibration[best_button]
        if abs(v_a1 - cal_a1) > UPDOWN_A1_STD_MULT * s_a1:
            return "IDLE", best_distance
    else:
        if best_distance > MAX_MAHAL:
            return "IDLE", best_distance

    return best_button, best_distance

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

    last_confirmed  = None
    candidate       = None
    candidate_count = 0

    # Pre-fill smoothing buffer
    for _ in range(SMOOTH_WINDOW):
        get_smoothed(bus)
        time.sleep(0.02)

    try:
        while True:
            v_a0, v_a1 = get_smoothed(bus)
            button, distance = match_button(v_a0, v_a1, calibration)
            conf = confidence(distance) if distance > 0 else 1.0

            required = UPDOWN_DEBOUNCE if button in ["UP", "DOWN"] else DEBOUNCE_COUNT

            if button == candidate:
                candidate_count += 1
            else:
                candidate       = button
                candidate_count = 1

            if candidate_count >= required:
                if candidate != last_confirmed:
                    if candidate and candidate != "IDLE":
                        print(f"  PRESS:   [{candidate}]  A0={v_a0:.4f}V  A1={v_a1:.4f}V  dist={distance:.3f}  conf={conf:.2f}")
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
        history.clear()
        input(f"  Press and HOLD [{button}] then hit Enter...")

        # Pre-fill buffer
        for _ in range(SMOOTH_WINDOW):
            get_smoothed(bus)

        detections = []
        for _ in range(10):
            v_a0, v_a1 = get_smoothed(bus)
            detected, distance = match_button(v_a0, v_a1, calibration)
            conf = confidence(distance) if distance > 0 else 1.0
            detections.append((detected, distance, v_a0, v_a1, conf))
            time.sleep(0.05)

        counts      = {}
        for d, _, _, _, _ in detections:
            counts[d] = counts.get(d, 0) + 1
        most_common = max(counts, key=counts.get)
        pct         = counts[most_common] / len(detections) * 100
        avg_conf    = sum(d[4] for d in detections) / len(detections)

        match = "✓" if most_common == button else "✗"
        print(f"  Expected [{button}] → Detected [{most_common}]  {match}  confidence={pct:.0f}%  avg_conf={avg_conf:.2f}")
        sample = detections[0]
        print(f"    A0={sample[2]:.4f}V  A1={sample[3]:.4f}V  dist={sample[1]:.3f}")
        results[button] = most_common == button
        print()

    passed = sum(1 for v in results.values() if v)
    print(f"  Result: {passed}/{len(BUTTONS)} buttons correct")

# =============================================================================
# Main
# =============================================================================
def main():
    bus         = smbus2.SMBus(BUS)
    calibration = load_calibration(CALIBRATION_FILE)
    mode        = sys.argv[1] if len(sys.argv) > 1 else "monitor"

    if mode == "verify":
        verify_mode(bus, calibration)
    else:
        monitor_mode(bus, calibration)

    bus.close()

if __name__ == "__main__":
    main()

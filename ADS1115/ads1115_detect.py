#!/usr/bin/env python3
# =============================================================================
# ads1115_detect.py
# MH-48 handset button detector using ADS1115 ADC
#
# Two modes:
#   verify  - guided verification, prompts for each button and shows detection
#   monitor - continuous monitoring mode (default)
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
import smbus2

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

# Number of consecutive consistent readings to confirm a button press
DEBOUNCE_COUNT = 3

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
                a0 = float(parts[1].rstrip("V"))
                a1 = float(parts[2].rstrip("V"))
                tol = float(parts[3].rstrip("V"))
                calibration[button] = (a0, a1, tol)
        print(f"  Loaded {len(calibration)} entries from {filepath}")
    except FileNotFoundError:
        print(f"ERROR: Calibration file not found: {filepath}")
        print("       Run ads1115_calibrate.py first.")
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
# Button matching - per-button tolerance, nearest neighbor within window
# =============================================================================
def match_button(v_a0, v_a1, calibration):
    best_button = None
    best_distance = float('inf')

    for button, (cal_a0, cal_a1, tolerance) in calibration.items():
        if button == "IDLE":
            continue  # IDLE is the default when nothing matches
        if abs(v_a0 - cal_a0) <= tolerance and abs(v_a1 - cal_a1) <= tolerance:
            distance = ((v_a0 - cal_a0) ** 2 + (v_a1 - cal_a1) ** 2) ** 0.5
            if distance < best_distance:
                best_distance = distance
                best_button = button

    if best_button is None:
        return "IDLE", 0.0
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

    last_confirmed = None
    candidate = None
    candidate_count = 0

    time.sleep(0.5)  # allow ADC readings to settle at startup

    try:
        while True:
            v_a0, v_a1 = read_both(bus)
            button, distance = match_button(v_a0, v_a1, calibration)

            if button == candidate:
                candidate_count += 1
            else:
                candidate = button
                candidate_count = 1

            if candidate_count >= DEBOUNCE_COUNT:
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
        input(f"  Press and HOLD [{button}] then hit Enter...")
        detections = []

        for _ in range(10):
            v_a0, v_a1 = read_both(bus)
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

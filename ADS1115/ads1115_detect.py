#!/usr/bin/env python3
# =============================================================================
# ads1115_detect.py
# MH-48 handset button detector using ADS1115 ADC
#
# Two modes:
#   verify  - guided verification, prompts for each button and shows detection
#   monitor - continuous monitoring mode (default)
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

# =============================================================================
# Calibration table (from ads1115_calibrate.py output)
# Format: "BUTTON": (A0_voltage, A1_voltage)
# =============================================================================
CALIBRATION = {
    "IDLE":  (0.5718, 0.4590),
    "1":     (0.0145, 0.0121),
    "2":     (0.0174, 0.0119),
    "3":     (0.0226, 0.0120),
    "A":     (0.0361, 0.0120),
    "4":     (0.0144, 0.0140),
    "5":     (0.0173, 0.0140),
    "6":     (0.0224, 0.0139),
    "B":     (0.0357, 0.0141),
    "7":     (0.0146, 0.0171),
    "8":     (0.0173, 0.0171),
    "9":     (0.0225, 0.0170),
    "C":     (0.0356, 0.0164),
    "*":     (0.0147, 0.0225),
    "0":     (0.0170, 0.0229),
    "#":     (0.0226, 0.0223),
    "D":     (0.0364, 0.0225),
    "P1":    (0.0138, 0.0354),
    "P2":    (0.0171, 0.0346),
    "P3":    (0.0227, 0.0349),
    "P4":    (0.0367, 0.0350),
    "UP":    (0.0310, 0.0340),
    "DOWN":  (0.0264, 0.0328),
    "PTT":   (0.5838, 0.5701),
}

# Maximum Euclidean distance to consider a valid match
MAX_DISTANCE = 0.020

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
# Button matching - nearest neighbor with max distance threshold
# =============================================================================
def match_button(v_a0, v_a1):
    best_button = None
    best_distance = MAX_DISTANCE

    for button, (cal_a0, cal_a1) in CALIBRATION.items():
        distance = ((v_a0 - cal_a0) ** 2 + (v_a1 - cal_a1) ** 2) ** 0.5
        if distance < best_distance:
            best_distance = distance
            best_button = button

    return best_button, best_distance

# =============================================================================
# Monitor mode - continuous detection
# =============================================================================
def monitor_mode(bus):
    print("=" * 50)
    print("  MH-48 Button Detector — Monitor Mode")
    print("  Press buttons on the handset")
    print("  Ctrl+C to exit")
    print("=" * 50)
    print()

    last_confirmed = None
    candidate = None
    candidate_count = 0

    try:
        while True:
            v_a0, v_a1 = read_both(bus)
            button, distance = match_button(v_a0, v_a1)

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
# Verify mode - guided per-button verification
# =============================================================================
def verify_mode(bus):
    print("=" * 50)
    print("  MH-48 Button Detector — Verify Mode")
    print("  Follow prompts to verify each button")
    print("=" * 50)
    print()

    results = {}

    for button in BUTTONS:
        input(f"  Press and HOLD [{button}] then hit Enter...")
        detections = []

        # Collect 10 readings while button is held
        for _ in range(10):
            v_a0, v_a1 = read_both(bus)
            detected, distance = match_button(v_a0, v_a1)
            detections.append((detected, distance, v_a0, v_a1))
            time.sleep(0.05)

        # Find most common detection
        counts = {}
        for d, _, _, _ in detections:
            counts[d] = counts.get(d, 0) + 1
        most_common = max(counts, key=counts.get)
        confidence = counts[most_common] / len(detections) * 100

        match = "✓" if most_common == button else "✗"
        print(f"  Expected [{button}] → Detected [{most_common}]  {match}  confidence={confidence:.0f}%")
        if most_common != button:
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
    mode = sys.argv[1] if len(sys.argv) > 1 else "monitor"

    if mode == "verify":
        verify_mode(bus)
    else:
        monitor_mode(bus)

    bus.close()

if __name__ == "__main__":
    main()

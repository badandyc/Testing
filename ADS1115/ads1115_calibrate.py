#!/usr/bin/env python3
# =============================================================================
# ads1115_calibrate.py
# MH-48 handset button matrix calibration script
#
# Improvements:
#   - Per-axis std (A0_std, A1_std) stored separately
#   - Std floor of 0.0015V per axis (prevents overconfidence in tight clusters)
#   - Outlier rejection (2.5 sigma, stats recomputed after)
#   - Proper IDLE collection — 50 samples same as buttons
#   - Cluster separation sanity check at end
#   - Sample rate ~125Hz (0.008s)
#   - PTT max tolerance cap
#
# Output format:
#   Button  A0_avg  A1_avg  A0_std  A1_std
#
# ADS1115 I2C address: 0x48, bus: 1
# MH-48 powered at 5V (GPIO Pin 4)
# SW1 -> ADS1115 A0
# SW2 -> ADS1115 A1
#
# Usage:
#   python3 ads1115_calibrate.py
#   dtmf calibrate
# =============================================================================

import time
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
# Calibration parameters
# =============================================================================
SAMPLES_REQUIRED  = 50
STD_FLOOR         = 0.0015   # minimum std per axis — prevents overconfidence
OUTLIER_SIGMA     = 2.5      # reject samples beyond this many std devs
PTT_MAX_STD       = 0.050    # cap PTT std to prevent huge acceptance zone
CLUSTER_WARN_DIST = 0.005    # warn if two buttons are closer than this (V)
SAMPLE_INTERVAL   = 0.008    # ~125Hz sample rate

# =============================================================================
# Button list
# =============================================================================
BUTTONS = [
    "1", "2", "3", "A",
    "4", "5", "6", "B",
    "7", "8", "9", "C",
    "*", "0", "#", "D",
    "P1", "P2", "P3", "P4",
    "UP", "DOWN",
    "PTT"
]

# =============================================================================
# ADS1115 read
# =============================================================================
def read_voltage(bus, mux):
    config = OS_SINGLE | mux | PGA_4096 | MODE_SINGLE | DR_128SPS | COMP_DISABLE
    config_bytes = [(config >> 8) & 0xFF, config & 0xFF]
    bus.write_i2c_block_data(ADS1115_ADDR, REG_CONFIG, config_bytes)
    time.sleep(SAMPLE_INTERVAL)
    data = bus.read_i2c_block_data(ADS1115_ADDR, REG_CONVERT, 2)
    raw = (data[0] << 8) | data[1]
    if raw > 32767:
        raw -= 65536
    return raw * 4.096 / 32767.0

def read_both(bus):
    return read_voltage(bus, MUX_A0_GND), read_voltage(bus, MUX_A1_GND)

# =============================================================================
# Stats helpers
# =============================================================================
def mean(samples):
    return sum(samples) / len(samples)

def std(samples, avg):
    return (sum((x - avg) ** 2 for x in samples) / len(samples)) ** 0.5

def reject_outliers(samples, avg, std_dev):
    if std_dev < STD_FLOOR:
        return samples
    return [x for x in samples if abs(x - avg) <= OUTLIER_SIGMA * std_dev]

def compute_stats(samples):
    avg = mean(samples)
    s   = std(samples, avg)
    # Reject outliers and recompute
    clean = reject_outliers(samples, avg, s)
    if len(clean) < 5:
        clean = samples  # fallback if too many rejected
    avg = mean(clean)
    s   = max(std(clean, avg), STD_FLOOR)
    return avg, s

# =============================================================================
# Collect samples for one button
# =============================================================================
def collect_button(bus, button, prompt=True):
    if prompt:
        input(f"  Press and HOLD [{button}] then hit Enter...")
    else:
        print(f"  Collecting idle samples — do NOT press anything...")

    print(f"  Collecting {SAMPLES_REQUIRED} samples — keep holding...")
    samples_a0 = []
    samples_a1 = []

    while len(samples_a0) < SAMPLES_REQUIRED:
        v_a0, v_a1 = read_both(bus)
        samples_a0.append(v_a0)
        samples_a1.append(v_a1)
        print(f"    {len(samples_a0)}/{SAMPLES_REQUIRED}  A0={v_a0:.4f}V  A1={v_a1:.4f}V", end="\r")

    avg_a0, std_a0 = compute_stats(samples_a0)
    avg_a1, std_a1 = compute_stats(samples_a1)

    # Cap PTT std
    if button == "PTT":
        std_a0 = min(std_a0, PTT_MAX_STD)
        std_a1 = min(std_a1, PTT_MAX_STD)

    print(f"    Done.                                          ")
    print(f"    A0 avg={avg_a0:.4f}V  std={std_a0:.4f}V")
    print(f"    A1 avg={avg_a1:.4f}V  std={std_a1:.4f}V")

    if prompt:
        input("    Release button and press Enter to continue...")
    print()

    return round(avg_a0, 4), round(avg_a1, 4), round(std_a0, 4), round(std_a1, 4)

# =============================================================================
# Cluster separation check
# =============================================================================
def check_separation(calibration):
    print("  Cluster separation check:")
    buttons = [b for b in calibration if b != "IDLE"]
    warnings = 0
    for i in range(len(buttons)):
        for j in range(i + 1, len(buttons)):
            b1, b2 = buttons[i], buttons[j]
            dx = calibration[b1]["A0"] - calibration[b2]["A0"]
            dy = calibration[b1]["A1"] - calibration[b2]["A1"]
            dist = (dx ** 2 + dy ** 2) ** 0.5
            if dist < CLUSTER_WARN_DIST:
                print(f"    WARNING: [{b1}] and [{b2}] are very close ({dist:.4f}V)")
                warnings += 1
    if warnings == 0:
        print("    All buttons have sufficient separation.")
    print()

# =============================================================================
# Main calibration loop
# =============================================================================
def main():
    bus = smbus2.SMBus(BUS)
    calibration = {}

    print("=" * 60)
    print("  MH-48 Button Matrix Calibration")
    print("  ADS1115 @ 0x48, bus 1")
    print(f"  Samples: {SAMPLES_REQUIRED}  |  Outlier rejection: {OUTLIER_SIGMA}σ")
    print(f"  Std floor: {STD_FLOOR}V  |  Sample rate: {int(1/SAMPLE_INTERVAL)}Hz")
    print("=" * 60)
    print()

    # IDLE — full 50-sample collection
    avg_a0, avg_a1, std_a0, std_a1 = collect_button(bus, "IDLE", prompt=False)
    calibration["IDLE"] = {"A0": avg_a0, "A1": avg_a1, "STD_A0": std_a0, "STD_A1": std_a1}

    for button in BUTTONS:
        avg_a0, avg_a1, std_a0, std_a1 = collect_button(bus, button)
        calibration[button] = {"A0": avg_a0, "A1": avg_a1, "STD_A0": std_a0, "STD_A1": std_a1}

    bus.close()

    print("=" * 70)
    print("  Calibration Complete")
    print("=" * 70)
    print()
    print(f"  {'Button':<6} {'A0_avg':>8} {'A1_avg':>8} {'A0_std':>8} {'A1_std':>8}")
    print(f"  {'-'*6} {'-'*8} {'-'*8} {'-'*8} {'-'*8}")
    for button, v in calibration.items():
        print(f"  {button:<6} {v['A0']:>8.4f}V {v['A1']:>8.4f}V {v['STD_A0']:>8.4f}V {v['STD_A1']:>8.4f}V")

    check_separation(calibration)

    # Save to file
    outfile = "/home/birddog/ads1115_calibration.txt"
    with open(outfile, "w") as f:
        f.write(f"{'Button':<6} {'A0_avg':>8} {'A1_avg':>8} {'A0_std':>8} {'A1_std':>8}\n")
        f.write(f"{'-'*6} {'-'*8} {'-'*8} {'-'*8} {'-'*8}\n")
        for button, v in calibration.items():
            f.write(f"{button:<6} {v['A0']:>8.4f}V {v['A1']:>8.4f}V {v['STD_A0']:>8.4f}V {v['STD_A1']:>8.4f}V\n")

    print(f"  Saved to {outfile}")
    print()

    # Python dict output for reference
    print("  Calibration dict (for reference):")
    print()
    print("CALIBRATION = {")
    for button, v in calibration.items():
        print(f'    "{button}":{" " * (5 - len(button))}({v["A0"]}, {v["A1"]}, {v["STD_A0"]}, {v["STD_A1"]}),')
    print("}")

if __name__ == "__main__":
    main()

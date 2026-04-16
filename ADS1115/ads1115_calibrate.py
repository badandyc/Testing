#!/usr/bin/env python3
# =============================================================================
# ads1115_calibrate.py
# MH-48 handset button matrix calibration script
#
# Collects 50 samples per button for accurate reference values.
# Outputs per-button tolerance based on 3x standard deviation.
# Hold the button, hit Enter, keep holding until collection complete.
#
# ADS1115 I2C address: 0x48, bus: 1
# MH-48 powered at 5V (GPIO Pin 4)
# SW1 -> ADS1115 A0
# SW2 -> ADS1115 A1
#
# Usage:
#   python3 ads1115_calibrate.py
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

SAMPLES_REQUIRED = 50
STD_MULTIPLIER   = 3      # tolerance = max(std_a0, std_a1) * STD_MULTIPLIER
MIN_TOLERANCE    = 0.005  # floor tolerance in volts

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

def std(samples, avg):
    return (sum((x - avg) ** 2 for x in samples) / len(samples)) ** 0.5

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
# Collect samples for one button
# =============================================================================
def collect_button(bus, button):
    input(f"  Press and HOLD [{button}] then hit Enter...")
    print(f"  Collecting {SAMPLES_REQUIRED} samples — keep holding...")
    samples_a0 = []
    samples_a1 = []

    while len(samples_a0) < SAMPLES_REQUIRED:
        v_a0, v_a1 = read_both(bus)
        samples_a0.append(v_a0)
        samples_a1.append(v_a1)
        print(f"    {len(samples_a0)}/{SAMPLES_REQUIRED}  A0={v_a0:.4f}V  A1={v_a1:.4f}V", end="\r")
        time.sleep(0.02)

    avg_a0 = sum(samples_a0) / len(samples_a0)
    avg_a1 = sum(samples_a1) / len(samples_a1)
    std_a0 = std(samples_a0, avg_a0)
    std_a1 = std(samples_a1, avg_a1)
    tolerance = max(max(std_a0, std_a1) * STD_MULTIPLIER, MIN_TOLERANCE)

    print(f"    Done.                                          ")
    print(f"    A0 avg={avg_a0:.4f}V  std={std_a0:.4f}V")
    print(f"    A1 avg={avg_a1:.4f}V  std={std_a1:.4f}V")
    print(f"    Tolerance: {tolerance:.4f}V")
    input("    Release button and press Enter to continue...")
    print()

    return round(avg_a0, 4), round(avg_a1, 4), round(tolerance, 4)

# =============================================================================
# Main calibration loop
# =============================================================================
def main():
    bus = smbus2.SMBus(BUS)
    calibration = {}

    print("=" * 50)
    print("  MH-48 Button Matrix Calibration")
    print("  ADS1115 @ 0x48, bus 1")
    print(f"  Samples per button: {SAMPLES_REQUIRED}")
    print(f"  Tolerance: {STD_MULTIPLIER}x std dev (min {MIN_TOLERANCE}V)")
    print("=" * 50)
    print()

    # Idle values
    print("Do NOT press any button. Reading idle values...")
    time.sleep(1)
    idle_a0, idle_a1 = read_both(bus)
    print(f"  Idle A0 (SW1): {idle_a0:.4f}V")
    print(f"  Idle A1 (SW2): {idle_a1:.4f}V")
    calibration["IDLE"] = {"A0": round(idle_a0, 4), "A1": round(idle_a1, 4), "TOL": 0.020}
    print()

    for button in BUTTONS:
        avg_a0, avg_a1, tolerance = collect_button(bus, button)
        calibration[button] = {"A0": avg_a0, "A1": avg_a1, "TOL": tolerance}

    bus.close()

    print("=" * 60)
    print("  Calibration Complete")
    print("=" * 60)
    print()
    print(f"  {'Button':<6} {'A0 (SW1)':>10} {'A1 (SW2)':>10} {'Tolerance':>10}")
    print(f"  {'-'*6} {'-'*10} {'-'*10} {'-'*10}")
    for button, v in calibration.items():
        print(f"  {button:<6} {v['A0']:>10.4f}V {v['A1']:>10.4f}V {v['TOL']:>10.4f}V")

    # Save results
    outfile = "/home/birddog/ads1115_calibration.txt"
    with open(outfile, "w") as f:
        f.write(f"{'Button':<6} {'A0 (SW1)':>10} {'A1 (SW2)':>10} {'Tolerance':>10}\n")
        f.write(f"{'-'*6} {'-'*10} {'-'*10} {'-'*10}\n")
        for button, v in calibration.items():
            f.write(f"{button:<6} {v['A0']:>10.4f}V {v['A1']:>10.4f}V {v['TOL']:>10.4f}V\n")

    # Output Python dict for copy-paste into detect script
    print()
    print("  Copy this into ads1115_detect.py CALIBRATION dict:")
    print()
    print("CALIBRATION = {")
    for button, v in calibration.items():
        print(f'    "{button}":{" " * (5 - len(button))}({v["A0"]}, {v["A1"]}, {v["TOL"]}),')
    print("}")
    print()
    print(f"Saved to {outfile}")

if __name__ == "__main__":
    main()

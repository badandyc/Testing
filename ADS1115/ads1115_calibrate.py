#!/usr/bin/env python3
# =============================================================================
# ads1115_calibrate.py
# MH-48 handset button matrix calibration script
#
# Reads ADS1115 A0 (SW1) and A1 (SW2) while prompting user to press
# each button, building a calibration table from actual hardware values.
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

# Register addresses
REG_CONVERT     = 0x00
REG_CONFIG      = 0x01

# Config register bits
OS_SINGLE       = 0x8000  # Start single conversion
MUX_A0_GND      = 0x4000  # AIN0 vs GND
MUX_A1_GND      = 0x5000  # AIN1 vs GND
PGA_4096        = 0x0200  # +/-4.096V range
MODE_SINGLE     = 0x0100  # Single shot mode
DR_128SPS       = 0x0080  # 128 samples per second
COMP_DISABLE    = 0x0003  # Disable comparator

# =============================================================================
# ADS1115 read function
# =============================================================================
def read_voltage(bus, mux):
    config = OS_SINGLE | mux | PGA_4096 | MODE_SINGLE | DR_128SPS | COMP_DISABLE
    config_bytes = [(config >> 8) & 0xFF, config & 0xFF]
    bus.write_i2c_block_data(ADS1115_ADDR, REG_CONFIG, config_bytes)
    time.sleep(0.01)  # Wait for conversion
    data = bus.read_i2c_block_data(ADS1115_ADDR, REG_CONVERT, 2)
    raw = (data[0] << 8) | data[1]
    if raw > 32767:
        raw -= 65536
    voltage = raw * 4.096 / 32767.0
    return voltage

def read_both(bus):
    v_a0 = read_voltage(bus, MUX_A0_GND)
    v_a1 = read_voltage(bus, MUX_A1_GND)
    return v_a0, v_a1

# =============================================================================
# Button list
# =============================================================================
BUTTONS = [
    "1", "2", "3", "A",
    "4", "5", "6", "B",
    "7", "8", "9", "C",
    "*", "0", "#", "D",
    "P1", "P2", "P3", "P4",
    "PTT"
]

# =============================================================================
# Main calibration loop
# =============================================================================
def main():
    bus = smbus2.SMBus(BUS)
    calibration = {}

    print("=" * 50)
    print("  MH-48 Button Matrix Calibration")
    print("  ADS1115 @ 0x48, bus 1")
    print("=" * 50)
    print()

    # First read idle values
    print("Do NOT press any button. Reading idle values...")
    time.sleep(1)
    idle_a0, idle_a1 = read_both(bus)
    print(f"  Idle A0 (SW1): {idle_a0:.4f}V")
    print(f"  Idle A1 (SW2): {idle_a1:.4f}V")
    calibration["IDLE"] = {"A0": round(idle_a0, 4), "A1": round(idle_a1, 4)}
    print()

    for button in BUTTONS:
        input(f"Press and HOLD button [{button}] then hit Enter...")
        samples_a0 = []
        samples_a1 = []
        for _ in range(10):
            v_a0, v_a1 = read_both(bus)
            samples_a0.append(v_a0)
            samples_a1.append(v_a1)
            time.sleep(0.02)

        avg_a0 = sum(samples_a0) / len(samples_a0)
        avg_a1 = sum(samples_a1) / len(samples_a1)

        print(f"  [{button}] A0 (SW1): {avg_a0:.4f}V  |  A1 (SW2): {avg_a1:.4f}V")
        calibration[button] = {"A0": round(avg_a0, 4), "A1": round(avg_a1, 4)}
        print()

    bus.close()

    print("=" * 50)
    print("  Calibration Complete")
    print("=" * 50)
    print()
    print("Results:")
    print(f"  {'Button':<6} {'A0 (SW1)':>10} {'A1 (SW2)':>10}")
    print(f"  {'-'*6} {'-'*10} {'-'*10}")
    for button, values in calibration.items():
        print(f"  {button:<6} {values['A0']:>10.4f}V {values['A1']:>10.4f}V")

    # Save to file
    outfile = "/home/birddog/ads1115_calibration.txt"
    with open(outfile, "w") as f:
        f.write(f"{'Button':<6} {'A0 (SW1)':>10} {'A1 (SW2)':>10}\n")
        f.write(f"{'-'*6} {'-'*10} {'-'*10}\n")
        for button, values in calibration.items():
            f.write(f"{button:<6} {values['A0']:>10.4f}V {values['A1']:>10.4f}V\n")

    print()
    print(f"Saved to {outfile}")

if __name__ == "__main__":
    main()

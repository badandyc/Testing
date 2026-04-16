#!/usr/bin/env python3
# =============================================================================
# ads1115_detect.py
# MH-48 handset button detector using ADS1115 ADC
#
# Reads A0 (SW1) and A1 (SW2) continuously and matches against
# calibration table to identify button presses.
#
# ADS1115 I2C address: 0x48, bus: 1
# MH-48 powered at 5V (GPIO Pin 4)
# SW1 -> ADS1115 A0
# SW2 -> ADS1115 A1
#
# Usage:
#   python3 ads1115_detect.py
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
# Calibration table (from ads1115_calibrate.py output)
# Format: "BUTTON": (A0_voltage, A1_voltage)
# =============================================================================
CALIBRATION = {
    "IDLE":  (0.4554, 0.5243),
    "1":     (0.0154, 0.0134),
    "2":     (0.0185, 0.0130),
    "3":     (0.0236, 0.0131),
    "A":     (0.0381, 0.0130),
    "4":     (0.0156, 0.0150),
    "5":     (0.0183, 0.0149),
    "6":     (0.0238, 0.0150),
    "B":     (0.0370, 0.0146),
    "7":     (0.0156, 0.0180),
    "8":     (0.0183, 0.0180),
    "9":     (0.0239, 0.0178),
    "C":     (0.0371, 0.0177),
    "*":     (0.0155, 0.0234),
    "0":     (0.0183, 0.0238),
    "#":     (0.0235, 0.0238),
    "D":     (0.0377, 0.0234),
    "P1":    (0.0150, 0.0362),
    "P2":    (0.0179, 0.0356),
    "P3":    (0.0234, 0.0353),
    "P4":    (0.0377, 0.0356),
    "UP":    (0.0240, 0.0263),
    "DOWN":  (0.0323, 0.0409),
    "PTT":   (0.5623, 0.5416),
}

# Tolerance in volts — how close a reading needs to be to match
TOLERANCE = 0.008

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
# Button matching
# =============================================================================
def match_button(v_a0, v_a1):
    for button, (cal_a0, cal_a1) in CALIBRATION.items():
        if abs(v_a0 - cal_a0) <= TOLERANCE and abs(v_a1 - cal_a1) <= TOLERANCE:
            return button
    return None

# =============================================================================
# Main detection loop
# =============================================================================
def main():
    bus = smbus2.SMBus(BUS)
    last_button = None

    print("=" * 50)
    print("  MH-48 Button Detector")
    print("  Press buttons on the handset")
    print("  Ctrl+C to exit")
    print("=" * 50)
    print()

    try:
        while True:
            v_a0, v_a1 = read_both(bus)
            button = match_button(v_a0, v_a1)

            if button != last_button:
                if button and button != "IDLE":
                    print(f"  PRESS:   [{button}]  A0={v_a0:.4f}V  A1={v_a1:.4f}V")
                elif last_button and last_button != "IDLE":
                    print(f"  RELEASE: [{last_button}]")
                last_button = button

            time.sleep(0.02)

    except KeyboardInterrupt:
        print("\nExiting.")
        bus.close()

if __name__ == "__main__":
    main()

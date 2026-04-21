#!/usr/bin/env python3
# =============================================================================
# keypad_test.py
# 4x4 matrix keypad bit-bang scanner
# Columns: C1=GPIO6, C2=GPIO13, C3=GPIO26, C4=GPIO16
# Rows:    L1=GPIO12, L2=GPIO1,  L3=GPIO8,  L4=GPIO15
# =============================================================================

import RPi.GPIO as GPIO
import time

# Column GPIOs (driven low one at a time)
COLS = [6, 13, 26, 16]

# Row GPIOs (read to detect which row is pulled low)
ROWS = [12, 1, 8, 15]

# Key map — row 0 is top, col 0 is left
KEYS = [
    ['1', '2', '3', 'A'],
    ['4', '5', '6', 'B'],
    ['7', '8', '9', 'C'],
    ['*', '0', '#', 'D'],
]

def setup():
    GPIO.setmode(GPIO.BCM)
    GPIO.setwarnings(False)
    for col in COLS:
        GPIO.setup(col, GPIO.OUT)
        GPIO.output(col, GPIO.HIGH)
    for row in ROWS:
        GPIO.setup(row, GPIO.IN, pull_up_down=GPIO.PUD_UP)

def scan():
    for col_idx, col_pin in enumerate(COLS):
        GPIO.output(col_pin, GPIO.LOW)
        for row_idx, row_pin in enumerate(ROWS):
            if GPIO.input(row_pin) == GPIO.LOW:
                GPIO.output(col_pin, GPIO.HIGH)
                return KEYS[row_idx][col_idx]
        GPIO.output(col_pin, GPIO.HIGH)
    return None

def main():
    setup()
    print("Keypad scanner ready — press any key (Ctrl+C to exit)")
    last_key = None
    try:
        while True:
            key = scan()
            if key and key != last_key:
                print(f"Key pressed: {key}")
            last_key = key
            time.sleep(0.05)
    except KeyboardInterrupt:
        print("\nExiting")
    finally:
        GPIO.cleanup()

if __name__ == "__main__":
    main()

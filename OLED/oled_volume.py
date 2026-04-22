#!/usr/bin/env python3
# =============================================================================
# oled_volume.py
# Proof of concept: UP/DOWN to adjust volume 1-10, FST to confirm
# UP=GPIO11, DOWN=GPIO9, FST=GPIO0
# Volume mapped to amixer numid=11 range (0-127)
# =============================================================================

import subprocess
import RPi.GPIO as GPIO
import time
from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306
from luma.core.render import canvas

UP   = 11
DOWN = 9
FST  = 0
PTT  = 7

VOL_MIN = 1
VOL_MAX = 10

# Map 1-10 to audible amixer range 99-127
AMIXER_MIN = 99
AMIXER_MAX = 127

def vol_to_amixer(vol):
    return int(AMIXER_MIN + (vol - 1) / 9 * (AMIXER_MAX - AMIXER_MIN))

def amixer_to_vol(amixer_val):
    val = round((amixer_val - AMIXER_MIN) / (AMIXER_MAX - AMIXER_MIN) * 9 + 1)
    return max(VOL_MIN, min(VOL_MAX, val))

def get_current_volume():
    try:
        result = subprocess.run(
            ["amixer", "-c", "0", "cget", "numid=11"],
            capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            if "values=" in line and "min=" not in line:
                val = int(line.strip().split("values=")[1].split(",")[0])
                return amixer_to_vol(val)
    except Exception:
        pass
    return 5

def set_volume(vol):
    val = vol_to_amixer(vol)
    subprocess.run(
        ["amixer", "-c", "0", "cset", "numid=11", f"{val},{val}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

def show_volume(device, vol, confirmed=False):
    with canvas(device) as draw:
        draw.rectangle(device.bounding_box, outline="white", fill="black")
        draw.text((10, 8),  "Volume", fill="white")
        draw.text((30, 28), f"{vol} / {VOL_MAX}", fill="white")
        if confirmed:
            draw.text((10, 48), "Set!", fill="white")
        else:
            draw.text((10, 48), "FST to confirm", fill="white")

def play_sound():
    subprocess.run(
        ["aplay", "-D", "plughw:0,0", "/home/birddog/sound_check.wav"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

GPIO.setmode(GPIO.BCM)
GPIO.setup(UP,   GPIO.IN, pull_up_down=GPIO.PUD_UP)
GPIO.setup(DOWN, GPIO.IN, pull_up_down=GPIO.PUD_UP)
GPIO.setup(FST,  GPIO.IN, pull_up_down=GPIO.PUD_UP)
GPIO.setup(PTT,  GPIO.IN, pull_up_down=GPIO.PUD_UP)

serial = i2c(port=1, address=0x3C)
device = ssd1306(serial)

current_vol = get_current_volume()
show_volume(device, current_vol)
print(f"Volume: {current_vol}")

try:
    while True:
        if GPIO.input(UP) == GPIO.LOW:
            current_vol = min(current_vol + 1, VOL_MAX)
            show_volume(device, current_vol)
            print(f"Volume: {current_vol}")
            time.sleep(0.3)

        if GPIO.input(DOWN) == GPIO.LOW:
            current_vol = max(current_vol - 1, VOL_MIN)
            show_volume(device, current_vol)
            print(f"Volume: {current_vol}")
            time.sleep(0.3)

        if GPIO.input(FST) == GPIO.LOW:
            set_volume(current_vol)
            show_volume(device, current_vol, confirmed=True)
            print(f"Volume set: {current_vol} -> amixer {vol_to_amixer(current_vol)}")
            time.sleep(0.5)
            show_volume(device, current_vol)

        if GPIO.input(PTT) == GPIO.LOW:
            print("PTT — playing sound_check.wav")
            play_sound()
            time.sleep(0.3)

        time.sleep(0.05)

except KeyboardInterrupt:
    device.cleanup()
    GPIO.cleanup()
    print("\nDone.")

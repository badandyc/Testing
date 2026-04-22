#!/usr/bin/env python3
# =============================================================================
# oled_volume.py
# PoC: 3-page OLED navigation with volume control on page 2
# UP=GPIO11, DOWN=GPIO9, FST=GPIO0, PTT=GPIO7
# Nav mode:    UP/DOWN cycle pages, FST enter page
# Volume page: UP/DOWN adjust, FST set, PTT play, FST 2s hold exit
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

PAGES      = ["Page 1", "Volume", "Page 3"]
VOL_MIN    = 1
VOL_MAX    = 10
AMIXER_MIN = 99
AMIXER_MAX = 127
FST_HOLD_S = 2.0

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

def play_sound():
    subprocess.run(
        ["aplay", "-D", "plughw:0,0", "/home/birddog/sound_check.wav"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

def show_page_nav(device, page_idx):
    with canvas(device) as draw:
        draw.rectangle(device.bounding_box, outline="white", fill="black")
        draw.text((10, 8),  f"Page {page_idx + 1} of {len(PAGES)}", fill="white")
        draw.text((10, 28), PAGES[page_idx], fill="white")
        draw.text((10, 48), "FST to enter", fill="white")

def show_volume_page(device, vol, status=""):
    with canvas(device) as draw:
        draw.rectangle(device.bounding_box, outline="white", fill="black")
        draw.text((10, 4),  "[ Volume ]", fill="white")
        draw.text((30, 22), f"{vol} / {VOL_MAX}", fill="white")
        draw.text((10, 40), status if status else "UP/DN | FST set | PTT test", fill="white")

def fst_held(hold_seconds=FST_HOLD_S):
    start = time.time()
    while GPIO.input(FST) == GPIO.LOW:
        if time.time() - start >= hold_seconds:
            return True
        time.sleep(0.05)
    return False

# --- Setup ---
GPIO.setmode(GPIO.BCM)
GPIO.setup(UP,   GPIO.IN, pull_up_down=GPIO.PUD_UP)
GPIO.setup(DOWN, GPIO.IN, pull_up_down=GPIO.PUD_UP)
GPIO.setup(FST,  GPIO.IN, pull_up_down=GPIO.PUD_UP)
GPIO.setup(PTT,  GPIO.IN, pull_up_down=GPIO.PUD_UP)

serial = i2c(port=1, address=0x3C)
device = ssd1306(serial)

current_page = 0
show_page_nav(device, current_page)
print(f"Page: {PAGES[current_page]}")

try:
    while True:
        # --- Page navigation mode ---
        if GPIO.input(UP) == GPIO.LOW:
            current_page = (current_page + 1) % len(PAGES)
            show_page_nav(device, current_page)
            print(f"Page: {PAGES[current_page]}")
            time.sleep(0.3)

        elif GPIO.input(DOWN) == GPIO.LOW:
            current_page = (current_page - 1) % len(PAGES)
            show_page_nav(device, current_page)
            print(f"Page: {PAGES[current_page]}")
            time.sleep(0.3)

        elif GPIO.input(FST) == GPIO.LOW:
            time.sleep(0.05)
            if GPIO.input(FST) == GPIO.LOW:

                if PAGES[current_page] == "Volume":
                    print("Entering volume page")
                    current_vol = get_current_volume()
                    show_volume_page(device, current_vol)

                    # --- Volume page loop ---
                    while True:
                        if GPIO.input(UP) == GPIO.LOW:
                            current_vol = min(current_vol + 1, VOL_MAX)
                            show_volume_page(device, current_vol)
                            print(f"Volume: {current_vol}")
                            time.sleep(0.3)

                        elif GPIO.input(DOWN) == GPIO.LOW:
                            current_vol = max(current_vol - 1, VOL_MIN)
                            show_volume_page(device, current_vol)
                            print(f"Volume: {current_vol}")
                            time.sleep(0.3)

                        elif GPIO.input(PTT) == GPIO.LOW:
                            print("PTT — playing sound_check.wav")
                            show_volume_page(device, current_vol, "Playing...")
                            play_sound()
                            show_volume_page(device, current_vol)
                            time.sleep(0.3)

                        elif GPIO.input(FST) == GPIO.LOW:
                            if fst_held():
                                print("FST hold — exiting volume page")
                                show_page_nav(device, current_page)
                                time.sleep(0.5)
                                break
                            else:
                                set_volume(current_vol)
                                print(f"Volume set: {current_vol} -> amixer {vol_to_amixer(current_vol)}")
                                show_volume_page(device, current_vol, "Set!")
                                time.sleep(0.5)
                                show_volume_page(device, current_vol)

                        time.sleep(0.05)

                else:
                    # Placeholder for other pages
                    with canvas(device) as draw:
                        draw.rectangle(device.bounding_box, outline="white", fill="black")
                        draw.text((10, 20), PAGES[current_page], fill="white")
                        draw.text((10, 40), "Hold FST to exit", fill="white")
                    print(f"Inside: {PAGES[current_page]}")

                    while True:
                        if GPIO.input(FST) == GPIO.LOW:
                            if fst_held():
                                print("FST hold — exiting page")
                                show_page_nav(device, current_page)
                                time.sleep(0.5)
                                break
                        time.sleep(0.05)

        time.sleep(0.05)

except KeyboardInterrupt:
    device.cleanup()
    GPIO.cleanup()
    print("\nDone.")

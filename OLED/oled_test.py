#!/usr/bin/env python3
import RPi.GPIO as GPIO
import time
from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306
from luma.core.render import canvas

UP   = 11
DOWN = 9

PAGES = ["Page 1", "Page 2", "Page 3"]
current = 0

GPIO.setmode(GPIO.BCM)
GPIO.setup(UP,   GPIO.IN, pull_up_down=GPIO.PUD_UP)
GPIO.setup(DOWN, GPIO.IN, pull_up_down=GPIO.PUD_UP)

serial = i2c(port=1, address=0x3C)
device = ssd1306(serial)

def show_page(n):
    with canvas(device) as draw:
        draw.rectangle(device.bounding_box, outline="white", fill="black")
        draw.text((30, 25), PAGES[n], fill="white")

show_page(current)
print(f"Showing {PAGES[current]}")

try:
    while True:
        if GPIO.input(UP) == GPIO.LOW:
            current = (current + 1) % len(PAGES)
            show_page(current)
            print(f"Showing {PAGES[current]}")
            time.sleep(0.3)

        if GPIO.input(DOWN) == GPIO.LOW:
            current = (current - 1) % len(PAGES)
            show_page(current)
            print(f"Showing {PAGES[current]}")
            time.sleep(0.3)

        time.sleep(0.05)

except KeyboardInterrupt:
    device.cleanup()
    GPIO.cleanup()
    print("\nDone.")

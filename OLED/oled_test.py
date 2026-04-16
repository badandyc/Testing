#!/usr/bin/env python3
# =============================================================================
# oled_test.py
# Basic OLED SSD1306 display test using luma.oled
# I2C address: 0x3C, bus: 1
# =============================================================================

from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306
from luma.core.render import canvas
from PIL import ImageFont
import time

serial = i2c(port=1, address=0x3C)
device = ssd1306(serial)

with canvas(device) as draw:
    draw.rectangle(device.bounding_box, outline="white", fill="black")
    draw.text((10, 20), "BirdDog", fill="white")
    draw.text((10, 35), "OLED OK", fill="white")

print("Display initialized — check screen")
time.sleep(5)
device.cleanup()
print("Done")

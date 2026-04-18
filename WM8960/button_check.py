#!/usr/bin/env python3
import RPi.GPIO as GPIO
import time

PTT  = 7
DOWN = 9
UP   = 11
FST  = 0

GPIO.setmode(GPIO.BCM)
for pin in [PTT, DOWN, UP, FST]:
    GPIO.setup(pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)

print("Button checker — press buttons (Ctrl+C to exit)")
print("PTT will NOT trigger TX")

try:
    while True:
        ptt  = "PTT"  if GPIO.input(PTT)  == GPIO.LOW else "---"
        down = "DOWN" if GPIO.input(DOWN) == GPIO.LOW else "----"
        up   = "UP"   if GPIO.input(UP)   == GPIO.LOW else "--"
        fst  = "FST"  if GPIO.input(FST)  == GPIO.LOW else "---"
        print(f"\r{ptt}  {down}  {up}  {fst}    ", end="", flush=True)
        time.sleep(0.1)
except KeyboardInterrupt:
    GPIO.cleanup()
    print("\nDone.")

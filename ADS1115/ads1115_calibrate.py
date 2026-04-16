#!/usr/bin/env python3
# =============================================================================
# ads1115_calibrate.py
# MH-48 handset button matrix calibration script
#
# Features:
#   - Per-axis std (A0_std, A1_std) with std floor
#   - Covariance (COV) for true 2D Mahalanobis distance
#   - Outlier rejection (2.5 sigma, stats recomputed after)
#   - Drift detection during sampling
#   - Proper IDLE collection (50 samples)
#   - Cluster separation and cluster size sanity checks
#   - PTT std cap
#   - Full precision internally, rounded for output/file
#   - ~125Hz sample rate
#
# Output format:
#   Button  A0_avg  A1_avg  A0_std  A1_std  COV
#
# ADS1115 I2C address: 0x48, bus: 1
# MH-48 powered at 5V (GPIO Pin 4)
# SW1 -> ADS1115 A0
# SW2 -> ADS1115 A1
#
# Usage:
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
STD_FLOOR         = 0.0015   # minimum std per axis
OUTLIER_SIGMA     = 2.5      # reject samples beyond this many std devs
PTT_MAX_STD       = 0.050    # cap PTT std
CLUSTER_WARN_DIST = 0.005    # warn if buttons closer than this (V)
CLUSTER_SIZE_WARN = 0.020    # warn if cluster spread exceeds this
DRIFT_THRESHOLD   = 0.010    # warn if last-10-sample range exceeds this
SAMPLE_INTERVAL   = 0.008    # ~125Hz

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
    time.sleep(SAMPLE_INTERVAL / 2)
    data = bus.read_i2c_block_data(ADS1115_ADDR, REG_CONVERT, 2)
    raw = (data[0] << 8) | data[1]
    if raw > 32767:
        raw -= 65536
    return raw * 4.096 / 32767.0

def read_both(bus):
    v_a0 = read_voltage(bus, MUX_A0_GND)
    v_a1 = read_voltage(bus, MUX_A1_GND)
    return v_a0, v_a1

# =============================================================================
# Stats helpers
# =============================================================================
def mean(samples):
    return sum(samples) / len(samples)

def std(samples, avg):
    return (sum((x - avg) ** 2 for x in samples) / len(samples)) ** 0.5

def covariance(samples_a0, samples_a1, avg_a0, avg_a1):
    return sum(
        (x - avg_a0) * (y - avg_a1)
        for x, y in zip(samples_a0, samples_a1)
    ) / len(samples_a0)

def reject_outliers(samples, avg, std_dev):
    if std_dev < STD_FLOOR:
        return samples
    return [x for x in samples if abs(x - avg) <= OUTLIER_SIGMA * std_dev]

def compute_stats(samples_a0, samples_a1):
    # First pass
    avg_a0 = mean(samples_a0)
    avg_a1 = mean(samples_a1)
    s_a0   = std(samples_a0, avg_a0)
    s_a1   = std(samples_a1, avg_a1)

    # Reject outliers
    clean_a0 = reject_outliers(samples_a0, avg_a0, s_a0)
    clean_a1 = reject_outliers(samples_a1, avg_a1, s_a1)

    # Use shorter of the two to keep pairs aligned
    min_len = min(len(clean_a0), len(clean_a1))
    if min_len < 5:
        clean_a0 = samples_a0
        clean_a1 = samples_a1
        min_len  = len(samples_a0)

    clean_a0 = clean_a0[:min_len]
    clean_a1 = clean_a1[:min_len]

    # Recompute final stats
    avg_a0 = mean(clean_a0)
    avg_a1 = mean(clean_a1)
    s_a0   = max(std(clean_a0, avg_a0), STD_FLOOR)
    s_a1   = max(std(clean_a1, avg_a1), STD_FLOOR)
    cov    = covariance(clean_a0, clean_a1, avg_a0, avg_a1)

    return avg_a0, avg_a1, s_a0, s_a1, cov, clean_a0, clean_a1

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
    drift_warned = False

    while len(samples_a0) < SAMPLES_REQUIRED:
        v_a0, v_a1 = read_both(bus)
        samples_a0.append(v_a0)
        samples_a1.append(v_a1)
        print(f"    {len(samples_a0)}/{SAMPLES_REQUIRED}  A0={v_a0:.4f}V  A1={v_a1:.4f}V", end="\r")

        # Drift detection on last 10 samples
        if len(samples_a0) >= 10 and not drift_warned:
            recent_a0 = samples_a0[-10:]
            recent_a1 = samples_a1[-10:]
            drift_a0  = max(recent_a0) - min(recent_a0)
            drift_a1  = max(recent_a1) - min(recent_a1)
            if drift_a0 > DRIFT_THRESHOLD or drift_a1 > DRIFT_THRESHOLD:
                print(f"\n    WARNING: signal drifting (A0 range={drift_a0:.4f}V, A1 range={drift_a1:.4f}V) — hold more steadily")
                drift_warned = True

    avg_a0, avg_a1, s_a0, s_a1, cov, _, _ = compute_stats(samples_a0, samples_a1)

    # Cap PTT std
    if button == "PTT":
        s_a0 = min(s_a0, PTT_MAX_STD)
        s_a1 = min(s_a1, PTT_MAX_STD)

    print(f"    Done.                                              ")
    print(f"    A0 avg={avg_a0:.4f}V  std={s_a0:.4f}V")
    print(f"    A1 avg={avg_a1:.4f}V  std={s_a1:.4f}V")
    print(f"    COV={cov:.6f}")

    if prompt:
        input("    Release button and press Enter to continue...")
    print()

    return avg_a0, avg_a1, s_a0, s_a1, cov

# =============================================================================
# Sanity checks
# =============================================================================
def check_separation(calibration):
    print("  Cluster separation check:")
    buttons  = [b for b in calibration if b != "IDLE"]
    warnings = 0
    for i in range(len(buttons)):
        for j in range(i + 1, len(buttons)):
            b1, b2 = buttons[i], buttons[j]
            dx   = calibration[b1]["A0"] - calibration[b2]["A0"]
            dy   = calibration[b1]["A1"] - calibration[b2]["A1"]
            dist = (dx ** 2 + dy ** 2) ** 0.5
            if dist < CLUSTER_WARN_DIST:
                print(f"    WARNING: [{b1}] and [{b2}] are very close ({dist:.4f}V)")
                warnings += 1
    if warnings == 0:
        print("    All buttons have sufficient separation.")
    print()

def check_cluster_size(calibration):
    print("  Cluster size check:")
    warnings = 0
    for button, v in calibration.items():
        size = (v["STD_A0"] ** 2 + v["STD_A1"] ** 2) ** 0.5
        if size > CLUSTER_SIZE_WARN:
            print(f"    WARNING: [{button}] cluster is large ({size:.4f}V)")
            warnings += 1
    if warnings == 0:
        print("    All clusters within acceptable size.")
    print()

# =============================================================================
# Main
# =============================================================================
def main():
    bus          = smbus2.SMBus(BUS)
    calibration  = {}

    print("=" * 60)
    print("  MH-48 Button Matrix Calibration")
    print("  ADS1115 @ 0x48, bus 1")
    print(f"  Samples: {SAMPLES_REQUIRED}  |  Outlier rejection: {OUTLIER_SIGMA}σ")
    print(f"  Std floor: {STD_FLOOR}V  |  Sample rate: {int(1/SAMPLE_INTERVAL)}Hz")
    print("=" * 60)
    print()

    # IDLE — full collection
    avg_a0, avg_a1, s_a0, s_a1, cov = collect_button(bus, "IDLE", prompt=False)
    calibration["IDLE"] = {"A0": avg_a0, "A1": avg_a1, "STD_A0": s_a0, "STD_A1": s_a1, "COV": cov}

    for button in BUTTONS:
        avg_a0, avg_a1, s_a0, s_a1, cov = collect_button(bus, button)
        calibration[button] = {"A0": avg_a0, "A1": avg_a1, "STD_A0": s_a0, "STD_A1": s_a1, "COV": cov}

    bus.close()

    print("=" * 80)
    print("  Calibration Complete")
    print("=" * 80)
    print()
    print(f"  {'Button':<6} {'A0_avg':>8} {'A1_avg':>8} {'A0_std':>8} {'A1_std':>8} {'COV':>10}")
    print(f"  {'-'*6} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*10}")
    for button, v in calibration.items():
        print(f"  {button:<6} {v['A0']:>8.4f}V {v['A1']:>8.4f}V {v['STD_A0']:>8.4f}V {v['STD_A1']:>8.4f}V {v['COV']:>10.6f}")

    check_separation(calibration)
    check_cluster_size(calibration)

    # Save to file
    outfile = "/home/birddog/ads1115_calibration.txt"
    with open(outfile, "w") as f:
        f.write(f"{'Button':<6} {'A0_avg':>8} {'A1_avg':>8} {'A0_std':>8} {'A1_std':>8} {'COV':>10}\n")
        f.write(f"{'-'*6} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*10}\n")
        for button, v in calibration.items():
            f.write(f"{button:<6} {v['A0']:>8.4f}V {v['A1']:>8.4f}V {v['STD_A0']:>8.4f}V {v['STD_A1']:>8.4f}V {v['COV']:>10.6f}\n")

    print(f"  Saved to {outfile}")

if __name__ == "__main__":
    main()

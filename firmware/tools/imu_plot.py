#!/usr/bin/env python3
"""Live plot of the imu_stream sketch's CSV output.

Usage: imu_plot.py /dev/cu.usbmodemXXXX [--seconds 5]

Top panel: accelerometer (g). Bottom: gyroscope (deg/s). Needs pyserial and
matplotlib:  pip install pyserial matplotlib
"""
import argparse
import collections
import sys

import serial
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

ap = argparse.ArgumentParser()
ap.add_argument("port")
ap.add_argument("--seconds", type=float, default=5.0, help="window shown")
a = ap.parse_args()

RATE = 50
N = int(a.seconds * RATE)
cols = ["ax", "ay", "az", "gx", "gy", "gz"]
buf = {c: collections.deque([0.0] * N, maxlen=N) for c in cols}
t = collections.deque([0.0] * N, maxlen=N)

ser = serial.Serial(a.port, 115200, timeout=0.05)

fig, (axa, axg) = plt.subplots(2, 1, sharex=True, figsize=(9, 6))
fig.suptitle(f"XIAO nRF52840 Sense Plus IMU, {a.port}")
la = [axa.plot([], [], label=c)[0] for c in cols[:3]]
lg = [axg.plot([], [], label=c)[0] for c in cols[3:]]
axa.set_ylabel("accel (g)"); axa.set_ylim(-4, 4); axa.legend(loc="upper left")
axg.set_ylabel("gyro (deg/s)"); axg.set_ylim(-1000, 1000); axg.legend(loc="upper left")
axg.set_xlabel("time (s)")


def read_pending():
    while ser.in_waiting:
        line = ser.readline().decode(errors="replace").strip()
        if not line or line.startswith("#") or line.startswith("t_ms"):
            if line.startswith("#"):
                print(line, file=sys.stderr)
            continue
        parts = line.split(",")
        if len(parts) != 7:
            continue
        try:
            vals = [float(p) for p in parts]
        except ValueError:
            continue
        t.append(vals[0] / 1000.0)
        for c, v in zip(cols, vals[1:]):
            buf[c].append(v)


def update(_):
    read_pending()
    xs = list(t)
    for ln, c in zip(la + lg, cols):
        ln.set_data(xs, list(buf[c]))
    if xs[-1] > xs[0]:
        axa.set_xlim(xs[0], xs[-1])
    return la + lg


ani = FuncAnimation(fig, update, interval=40, blit=False, cache_frame_data=False)
plt.tight_layout()
plt.show()

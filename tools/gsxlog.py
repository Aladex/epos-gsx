#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Passive logger for EPOS GSX 1000: raw HID reports + ALSA hw volume + PipeWire sink volume.

Does not grab anything, only observes. Run as root (hidraw is root-only).
  gsxlog.py <hidraw-device> <alsa-card> <desktop-user-uid>
Find the hidraw node of the card with:  udevadm info /dev/hidraw* | grep -B3 GSX
"""
import os, select, subprocess, sys, time, threading

if len(sys.argv) != 4:
    sys.exit(__doc__)
HIDRAW, CARD, USER_UID = sys.argv[1], sys.argv[2], int(sys.argv[3])
T0 = time.monotonic()


def ts():
    return f"{time.monotonic() - T0:8.3f}"


def alsa_vol():
    out = subprocess.run(["amixer", "-c", CARD, "cget", "numid=9"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.strip().startswith(": values="):
            return line.split("=", 1)[1]
    return "?"


def pw_vol():
    out = subprocess.run(["sudo", "-u", f"#{USER_UID}", "env", f"XDG_RUNTIME_DIR=/run/user/{USER_UID}",
                          "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"], capture_output=True, text=True).stdout
    return out.strip().replace("Volume: ", "")


def poller():
    last = None
    while True:
        cur = (alsa_vol(), pw_vol())
        if cur != last:
            print(f"{ts()} STATE alsa_raw={cur[0]} pw={cur[1]}", flush=True)
            last = cur
        time.sleep(0.05)


threading.Thread(target=poller, daemon=True).start()
fd = os.open(HIDRAW, os.O_RDONLY)
names = {0x01: "VOL_UP", 0x02: "VOL_DOWN", 0x04: "MUTE"}
while True:
    select.select([fd], [], [])
    data = os.read(fd, 64)
    if data and data[0] == 2:
        bits = data[1] if len(data) > 1 else 0
        label = "+".join(v for k, v in names.items() if bits & k) or "release"
        print(f"{ts()} HID id=2 {data.hex()} {label}", flush=True)
    else:
        print(f"{ts()} HID id={data[0] if data else '?'} len={len(data)} {data.hex()}", flush=True)

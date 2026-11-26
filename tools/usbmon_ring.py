#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Decode usbmon text capture of GSX 1000: ring HID requests vs FU12 SET_CUR."""
import re
import sys

TABLE_RE = re.compile(r"-?\d+")


def load_table(path):
    src = open(path).read()
    body = src[src.index("snd_gsx1000_vol_table"):]
    body = body[body.index("{") + 1:body.index("}")]
    return [int(x) for x in TABLE_RE.findall(body)]


def main(cap, quirks):
    inv = {v: i for i, v in enumerate(load_table(quirks))}
    t0 = last = None
    for line in open(cap):
        f = line.split()
        t = int(f[1]) / 1e6
        t0 = t if t0 is None else t0
        t -= t0
        if f[2] == "C" and f[3].startswith("Ii:") and "=" in f:
            data = f[f.index("=") + 1]
            if data != "0200":
                print(f"{t:8.3f} HID {dict(a='UP', b='DOWN').get({'0201': 'a', '0202': 'b'}.get(data), data)}")
                last = t
        elif f[2] == "S" and f[3].startswith("Co:") and f[5:9] == ["21", "01", "0201", "0c03"]:
            raw = int.from_bytes(bytes.fromhex(f[-1]), "little", signed=True)
            lat = f"  (+{(t - last) * 1000:.1f} ms)" if last is not None and t - last < 0.2 else ""
            print(f"{t:8.3f}     SET {inv.get(raw, raw)}{lat}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

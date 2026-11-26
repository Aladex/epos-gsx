#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Minimal USBPcap (linktype 249) decoder for GSX 1000 captures.

Prints class SET_CUR/GET_* control requests with their data and HID interrupt reports.
"""
import struct
import sys

REQ = {0x01: "SET_CUR", 0x81: "GET_CUR", 0x82: "GET_MIN", 0x83: "GET_MAX", 0x84: "GET_RES"}
CS = {1: "MUTE", 2: "VOL"}


def packets(path):
    with open(path, "rb") as f:
        hdr = f.read(24)
        endian = "<" if hdr[:4] == b"\xd4\xc3\xb2\xa1" else ">"
        while True:
            ph = f.read(16)
            if len(ph) < 16:
                return
            sec, usec, incl, _ = struct.unpack(endian + "IIII", ph)
            yield sec + usec / 1e6, f.read(incl)


def main(path):
    t0 = None
    pending = {}
    for t, p in packets(path):
        t0 = t if t0 is None else t0
        hlen, irp, status, func, info, bus, dev, ep, xfer, dlen = struct.unpack_from("<HQIHBHHBBI", p)
        payload = p[hlen:]
        rel = t - t0
        to_host = bool(info & 1)
        if xfer == 2:  # control
            stage = p[27] if hlen > 27 else None
            if stage == 0 and len(payload) >= 8:  # setup
                bm, breq, wval, widx, wlen = struct.unpack_from("<BBHHH", payload)
                if bm & 0x60 == 0x20:  # class request
                    pending[irp] = (bm, breq, wval, widx, wlen, rel)
                    data = payload[8:]
                    if breq == 0x01 and len(data) >= wlen and wlen:
                        report(rel, dev, breq, wval, widx, data[:wlen])
                        pending.pop(irp, None)
            elif irp in pending and payload:
                bm, breq, wval, widx, wlen, _ = pending.pop(irp)
                report(rel, dev, breq, wval, widx, payload[:wlen])
        elif xfer == 1 and to_host and payload:  # interrupt IN
            print(f"{rel:9.3f} dev{dev} HID {payload.hex()}")


def report(rel, dev, breq, wval, widx, data):
    cs, ch = wval >> 8, wval & 0xFF
    unit, iface = widx >> 8, widx & 0xFF
    val = ""
    if cs == 2 and len(data) == 2:
        raw = struct.unpack("<h", data)[0]; val = f"{raw / 256:.2f} dB raw={raw}"
    elif data:
        val = data.hex()
    print(f"{rel:9.3f} dev{dev} {REQ.get(breq, hex(breq))} unit{unit}/if{iface} {CS.get(cs, cs)} ch{ch} = {val}")


if __name__ == "__main__":
    main(sys.argv[1])

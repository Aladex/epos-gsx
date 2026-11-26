#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Emit the 0..100 % -> UAC volume (1/256 dB) table measured from Windows.

Source: captures/sweep-table.csv (Windows sweep 0->100->0, 1 % steps).
Every value is cross-checked against the SET_CUR FU 12 requests in the USBPcap dump.
Windows computes raw = trunc(dB * 256).
"""
import csv
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CSV = ROOT / "captures/sweep-table.csv"
PCAP = ROOT / "captures/08-sweep.pcap"


def main():
    rows = list(csv.DictReader(open(CSV)))
    table = [int(r["raw_up"]) for r in rows]
    assert [int(r["percent"]) for r in rows] == list(range(101))
    assert all(int(r["raw_up"]) == int(r["raw_down"]) for r in rows)
    assert all(a < b for a, b in zip(table, table[1:]))

    dump = subprocess.run([sys.executable, "-I", str(ROOT / "tools/usbpcap_dump.py"), str(PCAP)],
                          capture_output=True, text=True, check=True).stdout
    seen = {int(l.rsplit("raw=", 1)[1]) for l in dump.splitlines() if "unit12/if3 VOL ch1" in l}
    missing = [v for v in table if v not in seen]
    assert not missing, f"not in pcap: {missing}"

    print("static const s16 snd_gsx1000_vol_table[SND_GSX1000_VOL_STEPS + 1] = {")
    for i in range(0, 101, 10):
        print("\t" + " ".join(f"{v}," for v in table[i:i + 10]))
    print("};")


if __name__ == "__main__":
    main()

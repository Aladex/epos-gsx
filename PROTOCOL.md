# GSX 1000 volume protocol

This documents how the EPOS / Sennheiser GSX 1000 v2 (`1395:00b1`, firmware 2.13)
behaves on its USB audio control interface and its HID interface, and what the
Windows inbox driver does with it. Everything below was measured, not guessed: each
statement names the capture under `captures/` that shows it. The quirk in
`gsx1000-volume.patch` reproduces the Windows behaviour inside `snd-usb-audio`, so
the model here is also the specification for the patch.

Captures were taken with USBPcap 1.5.4 on Windows (no vendor driver, the inbox
`usbaudio.sys` and `HID_Inst.NT`), decoded with `tools/windows/decode.ps1` (tshark)
or `tools/usbpcap_dump.py`. Each `.pcap` has a `.txt` next to it with the decoded
requests. Notation: `unit12/if3` is Feature Unit 12 on interface 3, `ch0` is the
master channel, `ch1`/`ch2` are left/right, and a volume value is an `int16` in
1/256 dB.

## USB topology

Full speed device, one configuration with six interfaces
(`captures/linux/lsusb-v.txt`):

| Interface | Class | Purpose |
|---|---|---|
| 0 | UAC1 AudioControl | chat output and microphone controls: Feature Unit **2** (chat volume), Feature Unit **6** (mic), Selector Unit 5 |
| 1 | UAC1 AudioStreaming | microphone capture to the host, 1 channel, 48 kHz, 16 bit, EP `0x81` IN (linked to Output Terminal 4, the USB-streaming output of the mic path) |
| 2 | UAC1 AudioStreaming | chat playback from the host, 1 channel, 48 kHz, 16 bit, EP `0x01` OUT (linked to Input Terminal 1, which feeds FU 2) |
| 3 | UAC1 AudioControl | game 7.1 control: Input Terminal 11 (8 ch), Feature Unit **12**, Output Terminal 13 (Speaker) |
| 4 | UAC1 AudioStreaming | game output, 8 channels, 48 kHz, 16 bit, EP `0x02` OUT, 768 byte frames |
| 5 | HID | EP `0x82` IN interrupt, `wMaxPacketSize` 64 bytes (the endpoint's maximum packet size; report 2 is 2 bytes), 1 ms interval |

Descriptor-claimed volume ranges, as returned by `GET_MIN`/`GET_MAX`/`GET_RES`
after enumeration (`captures/01-reconnect.txt`, 67.1 s onward):

| Unit | Channels | CUR after reconnect | MIN | MAX | RES |
|---|---|---|---|---|---|
| 12 (game) | 1, 2 | -1 dB | -74 dB | 0 dB | 1 dB |
| 2 (chat) | 1 | 0 dB | **-0.10 dB** | 0 dB | **0.10 dB** |
| 2 (chat) | 2 | 0 dB | -74 dB | 0 dB | 1 dB |
| 6 (mic) | 0 | -1 dB | -30 dB | +5 dB | 1 dB |

`MUTE` CUR is 0 on all three units. The chat channel 1 range of -0.1..0 dB looks
like a firmware quirk; the Windows driver never writes anything but tiny values
there (-0.06 or -0.07 dB) and it is not relevant to the game volume.

### HID reports

Interface 5 has a 54 byte report descriptor (`captures/linux/hid_report_descriptor.txt`):

- **Report ID 1**: vendor report, 61 bytes IN and OUT. The device never sent one
  in any capture, and no host software is known to use it.
- **Report ID 2**: 2 bytes, bit 0 `Vol+`, bit 1 `Vol-`, bit 2 `Mute`. The device
  sends `02 01` / `02 02` on a press and `02 00` on release. The Mute bit is
  defined but was never observed; there is no mute button on the device.

## The ring sends "correction requests", not direction

The ring is an encoder, but it does not report rotation direction. It sends
`Vol+`/`Vol-` events **until the host volume written to FU 12 matches the ring
position**. The host is expected to apply one fixed step per event and write the
new value back; the device compares and keeps asking until it agrees.

Evidence:

- `captures/04-ring-fast.pcap` (down, 60 -> 4): 27 `Vol-` were captured but
  Windows took 29 steps, down to 2 %. About 80 ms after the last burst the device
  sent **one `Vol+`** and Windows went back up to 4 %, exactly the number on the
  ring. That is the device correcting an overshoot, which only makes sense if it
  tracks the host volume.
- `captures/04-ring-fast.pcap` (up, 4 -> 48): 23 `Vol+` and 1 `Vol-`; Windows went
  4 -> 6 -> 8 -> **6 -> 8** -> ... -> 48. The `Vol+ Vol- Vol+` chatter at the start
  of the turn came from the device itself.
- `captures/05-windows-slider.pcap`: the tray slider was moved from 48 to 24 and
  back to 30 %. **No HID event at all** from the device. It simply displays
  whatever the host last wrote to FU 12. A host write without a ring turn becomes
  the new target, so no correction follows.

This is also why a 1 dB grid does not work: the device compares with 1/256 dB
precision (see the table below), and `snd-usb-audio` with the stock control only
writes whole dB, so the written value never lands on the one the ring expects and
the device keeps sending `Vol+`/`Vol-` forever.

## What Windows writes

Windows treats the device as a regular HID consumer-volume device and an endpoint
with hardware volume and mute (`QueryHardwareSupport` mask 0x3). For every volume
change, whether from the ring or from the slider, it issues:

```
SET_CUR unit12 VOL ch1 = <value>
SET_CUR unit12 VOL ch2 = <value>
```

- **Channels 1 and 2 get the same value; the master channel (ch0) is never
  written.** Seen in every capture, e.g. `captures/08-sweep.pcap` (204 pairs,
  ch1 == ch2 everywhere).
- The value is the Windows volume taper in 1/256 dB, `raw = trunc(dB * 256)`,
  where `dB` is what `IAudioEndpointVolume::GetMasterVolumeLevel` reports for the
  scalar percent. See the table below.
- On the first change after a longer idle period Windows first re-sends the
  current values of all units (chat ch1/ch2, mic, current game volume) and then
  the new one. On subsequent changes it re-sends only chat (unchanged) and game.
  (`captures/02-ring-slow-down.txt` first event vs. the rest;
  `captures/03-ring-slow-up.txt` same; `captures/04-ring-fast.txt` had no resync
  after a 5.5 s pause, so the threshold is longer.)
- Mute: `SET_CUR unit12 MUTE ch0 = 1/0`; chat and mic are not touched. The
  **first** mute after a pause (`captures/06-mute.txt`) re-sends the current
  volume first (`SET_CUR` ch1/ch2 = -18.03 dB, the same resync as after an
  idle period) and then `MUTE = 1`; the later tray toggles
  (`captures/06b-mute-again.txt`) are mute-only, no volume write. When
  `VolumeStepUp` unmutes, the new volume is sent **before** `MUTE = 0`.
- After a reconnect the device resets FU 12 to -1 dB and Windows immediately
  restores its state (`captures/01-reconnect.txt`, 67.9 s): `SET_CUR unit2 MUTE=0`,
  `VOL ch1/ch2 = -0.06`, `unit6 VOL ch0 = -1.00`, `unit12 MUTE = 0`,
  `unit12 VOL ch1/ch2 = -7.68` (= 60 %).

## Volume table

One ring detent is one HID event and **2 %** on the Windows scale
(`captures/02-ring-slow-down.txt`: five `Vol-`, 60 -> 50 % in five steps of 2 %).
The slider moves in 1 % steps. `captures/08-sweep.pcap` is a scripted 0 -> 100 -> 0
sweep in 1 % steps (`tools/windows/sweep.ps1`); its log is
`captures/sweep-volumes.csv`, the derived table is `captures/sweep-table.csv`.

- Up and down runs produce identical values for all 101 percentages.
- `raw = trunc(dB * 256)` for every point, truncation toward zero, no rounding.
  Example: 2 %, `dB = -54.60539`, `x 256 = -13978.98` -> `-13978`.
- Every FU 12 value seen in captures 01, 02, 04 and 05 appears byte for byte in
  this table.
- The curve is strongly non-linear at the bottom: 1 % is -61.4 dB, 50 % is
  -10.42 dB, 99 % is -0.15 dB. The scale is Windows' audio taper, not the
  device's; the device only stores and displays what it is given.

`tools/gen_table.py` regenerates the C array in `gsx1000-volume.patch` from
`sweep-table.csv` and verifies every value against the pcap; `tests/run.sh` fails
if the two diverge.

## Display

The number on the device is derived from the FU 12 value, not from the ring
position:

- In the middle of the scale it equals the Windows percent (scenarios 02-05).
- Near the top it diverges by one or two, in either direction: at 100 % (0 dB)
  the device shows **99** (one behind), at 97 % it shows **98** (one ahead)
  (`captures/09-manual-100-99-98.txt`). It never shows more than 99. This is the
  device's own dB -> number scale and is not a bug in the host; the patch
  therefore does not try to compensate for it.
- Mute is shown as `--` and follows the FU 12 `MUTE` control only.

## Buttons

The 7.1 button, the output switch and the other front-panel buttons are handled
inside the device. In `captures/07-buttons.pcap` and
`captures/07b-buttons-again.pcap` (buttons pressed with 5 s pauses) the device
sent **nothing**: no HID report (neither ID 1 nor ID 2) and no control request.
The host is not informed about button state and Windows does not react.

## Implications for the quirk

1. Expose one 0..100 control without a dB TLV, so user space maps its percent
   linearly onto the steps and the device shows the same number as the desktop.
2. On every change write the table value to ch1 and ch2 of FU 12; leave ch0 alone.
3. Treat `Vol+`/`Vol-` from this device's HID interface as "step by 2 %", apply it
   in the driver, and swallow the event so the desktop does not apply its own
   global step size to it.
4. On probe and resume re-send the current value, because the device has reset to
   -1 dB.

# Captures

USB traffic of the EPOS / Sennheiser GSX 1000 v2 (`1395:00b1`, firmware 2.13),
recorded to reverse-engineer the Windows volume behaviour. Each `.pcap` was taken
with USBPcap 1.5.4 on Windows (inbox `usbaudio.sys` + `HID_Inst.NT`, no vendor
driver) and comes with a `.txt` decoded by `tools/windows/decode.ps1` (tshark).
`PROTOCOL.md` explains what they show. The device serial in `linux/lsusb-v.txt`
has been replaced by a same-length placeholder; the pcaps contain no string
descriptor with a serial.

Ring events are HID Report ID 2 on EP `0x82`: `02 01` = Vol+, `02 02` = Vol-,
`02 00` = release. `SET_CUR unit12/if3 VOL ch1/ch2` is the game volume write,
values in dB (1/256 dB units in the raw data).

| File | What was done | What it shows |
|---|---|---|
| `01-reconnect.pcap` | Card at 60, Windows at 60 %. Ring turned a little, then the USB cable was unplugged and replugged (address 4 -> 5). | Descriptor ranges via `GET_MIN/MAX/RES/CUR`; the device resets FU 12 to -1 dB after reconnect and Windows restores all units. |
| `02-ring-slow-down.pcap` | Ring slowly down 5 detents, 0.6-1.2 s apart. 60 -> 50 %. | One detent = one HID event = 2 %. Windows answers each with a `SET_CUR` pair on ch1/ch2. Full resync of all units on the first event after idle. |
| `03-ring-slow-up.pcap` | Ring slowly up 5 detents. 50 -> 60 %. | Mirror of 02 with the same values. No extra events. |
| `04-ring-fast.pcap` | Ring snapped down (60 -> 4), then up (4 -> 48). | Bursts of 2-5 events per ~100 ms. 27 `Vol-` vs. 29 Windows steps, then one `Vol+` from the device corrects an overshoot: the "correction request" model. Encoder chatter `Vol+ Vol- Vol+` at the start of a turn. |
| `05-windows-slider.pcap` | Tray slider 48 -> 24 -> 30 %. | No HID event from the device; it displays whatever the host writes. 1 % steps, odd percentages 25-47. Large file: the volume-change sound put isochronous audio in the capture; the decoder skips it. |
| `06-mute.pcap` | Mute from Windows at 30 %. | Windows first re-sends the current volume (`SET_CUR` ch1/ch2 = -18.03 dB, the same resync as after an idle period), then `SET_CUR unit12 MUTE ch0 = 1`. |
| `06b-mute-again.pcap` | Mute/unmute from the tray at 30 %. | Only `MUTE = 1/0`, volume not re-sent. The first two events in the file (30 -> 32 %, unmute) were caused by a mis-called `VolumeStepUp` in the probing script, not by the user; they show that `VolumeStepUp` is +2 % and unmutes, volume before `MUTE = 0`. |
| `07-buttons.pcap` | Front-panel buttons pressed (7.1, output switch). | Nothing: no HID report, no control request. |
| `07b-buttons-again.pcap` | Same with 5 s pauses. | Nothing, again. |
| `08-sweep.pcap` | `tools/windows/sweep.ps1`: volume 0 -> 100 -> 0 in 1 % steps, 300 ms each, then back to 60 %. | 204 `SET_CUR` pairs, ch1 == ch2, no ring events. Up and down identical for all 101 values. Source of `sweep-table.csv`. |
| `09-manual-100-99-98.pcap` | Tray slider dragged 60 -> 100, then 100 -> 99 -> 98 -> 97 -> ... -> 97. | Values match the table; device shows 99 at 100 % and 98 at 97 %; no HID events. Large file (volume-change sound). |
| `sweep-table.csv` | Derived from 08: `percent, raw_up, raw_down, db, windows_db_readback`. | The 101 volume values used by the patch. `raw = trunc(dB * 256)`. |
| `sweep-volumes.csv` | Log written by `sweep.ps1` during 08: `direction, percent, scalar_readback, db_readback`. | What Windows reported for each step. |
| `linux/lsusb-v.txt` | `lsusb -v` of the card on Linux. | Descriptors for all six interfaces. Serial replaced by `0000000000000000`. |
| `linux/hid_report_descriptor.txt` | `hexdump` of the HID report descriptor (54 bytes). | Report 1: 61 bytes IN/OUT, vendor. Report 2: bits for Vol+ (0xe9), Vol- (0xea), Mute (0xe2). |
| `linux/gsx.log` | `tools/gsxlog.py` on Linux with the STOCK `snd-usb-audio` control, ring turned slowly, both directions (taken before the quirk existed). | HID events next to the stock 0..74 ALSA control (`alsa_raw=61,61 (of 74)`) and the desktop volume in 5 % steps; it illustrates the pre-quirk behaviour, not the final driver. |

Tools: `tools/usbpcap_dump.py` decodes a pcap without tshark; `tools/gen_table.py`
regenerates the patch table from `sweep-table.csv` and verifies it against
`08-sweep.pcap`; `tools/usbmon_ring.py` decodes a Linux usbmon text capture;
`tools/gsxlog.py` logs HID + ALSA + PipeWire state live; `tools/windows/` holds
the PowerShell capture, decode and sweep scripts.

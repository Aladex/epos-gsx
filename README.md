# epos-gsx: EPOS / Sennheiser GSX 1000 v2 on Linux, volume like on Windows

A kernel module quirk that makes the volume ring and the display of the
**EPOS / Sennheiser GSX 1000 v2** USB DAC (`1395:00b1`) behave on Linux as on
Windows: the ring moves the desktop volume in 2 % steps and the device shows
the desktop percent, except at the very top of the scale (see Limitations).
Packaged for DKMS, rebuilt on every kernel update.

Tested on: GSX 1000 v2, firmware 2.13, CachyOS kernel 7.3.6, PipeWire, KDE.

## The problem and the fix

The ring does not report a direction; it keeps asking the host to correct the
volume until the value written to the device matches the ring position. Stock
`snd-usb-audio` answers with whole dB on a 0..74 control and passes the ring
events to the desktop as global volume keys, so the value never matches and
the volume oscillates (`PROTOCOL.md` has the measurements).

`gsx1000-volume.patch` is a quirk for `sound/usb/mixer_quirks.c` and
`mixer_maps.c`: it replaces the stock control with one 0..100 control on the
Windows scale, writes the matching Windows table value to the device on every
change, and handles the ring's `Vol+`/`Vol-` **only from this card's HID
interface** in the driver (+-2 %, swallowed before evdev).

## Supported device

| Model | USB id | Status |
|---|---|---|
| GSX 1000 v2 | `1395:00b1` | supported, firmware 2.13 tested |
| GSX 1000 v1 | `1395:005e`, `1395:00a0` | not tested, see below |
| GSX 1200 | `1395:005f`, `1395:00a1` | not tested, see below |

## Requirements

Linux 7.x (`BUILD_EXCLUSIVE_KERNEL="^7\."`; 6.x is skipped on purpose),
`dkms`, `curl`, `patch`, `tar`, `xz`, kernel headers for the running kernel,
and PipeWire or PulseAudio (anything that maps a TLV-less control linearly).

## Install

```sh
paru -S epos-gsx1000-dkms                     # from the AUR (packaging/aur/)
# or from a checkout:
git clone https://github.com/Aladex/epos-gsx.git && cd epos-gsx
scripts/dkms-install.sh                       # register, build, install
```

DKMS builds and installs the module for the running kernel; its pacman hooks
rebuild it on kernel upgrades. Uninstall: `sudo pacman -R epos-gsx1000-dkms`
or `scripts/dkms-install.sh --remove`. Build without installing:
`scripts/build-module.sh`.

**Reboot to load it**, and reboot again after removing it to get the stock
module back: the `.ko` on disk changes, not the `snd_usb_audio` code already
resident in the kernel. If nothing uses the module, unloading and reloading it
also works: `sudo modprobe -r snd_usb_audio && sudo modprobe snd_usb_audio`.

## How the build works

`dkms/dkms-build.sh` derives the kernel version from the running release,
downloads the full `linux-<ver>.tar.xz` (about 150 MB) from `cdn.kernel.org`,
keeps only `sound/usb` (about 2 MB) in `/var/cache/epos-gsx1000` and drops the
tarball, so each new kernel version downloads its tarball once. It applies the
patch and builds `sound/usb` out-of-tree with the kernel's own config; the
module lands in `/lib/modules/<kernel>/updates/dkms/snd-usb-audio.ko` and
overrides the in-tree one.

## Limitations

- **Kernel 7.x only.** If a future kernel changes `mixer_quirks.c` so the patch
  no longer applies, DKMS reports it on upgrade and the stock module stays.
- **Module signing.** DKMS signs the module only if it has a MOK (Machine Owner
  Key) set up; with enforced signatures (`sig_enforce=1`, e.g. Secure Boot) the
  key must be enrolled or the module will not load. On the tested machine the
  module was **not** signed and still loaded, because `sig_enforce` is off
  there ("module verification failed: signature and/or required key missing").
- **The display shows 99 at 0 dB and 98 at 97 %**, the device's own scale;
  Windows shows the same (`captures/09-manual-100-99-98.pcap`).

## Optional: `system/` extras

Three optional files, not installed by the AUR package; the quirk does not
depend on them, and whether the stock configuration is sufficient **has not
been verified**. A WirePlumber rule and an ACP profile set (`51-epos-gsx1000-v2.conf`,
`epos-gsx1000-v2.conf`) exposing the game output as 7.1 plus mono chat (which
channel order maps to the physical outputs is **unconfirmed**), and a `.hwdb`
(`90-epos-gsx1000-v2.hwdb`) mapping the ring's HID keys for evdev, useful only
**without** the module. Copy the rule to `/etc/wireplumber/wireplumber.conf.d/`,
the profile to `/etc/alsa-card-profile/mixer/profile-sets/`, the `.hwdb` to
`/etc/udev/hwdb.d/` (WirePlumber 0.5 or later); then `sudo systemd-hwdb update`
and restart WirePlumber.

## Other models, layout, tests

For the v1 and GSX 1200 ids above, open an issue with `lsusb -v -d 1395:<id>`
(serial replaced by a placeholder), a USBPcap (or usbmon) capture of a slow ring
turn in both directions and a slider move (`tools/windows/` does the capture and
the decoding), and the numbers the device shows at 0, 50 and 100 %.

- `gsx1000-volume.patch`: the quirk. `dkms/`, `scripts/`: build and install.
  `packaging/aur/`: `PKGBUILD` and `.SRCINFO`.
- `tools/` (capture decoders, table generator, live logger, Windows scripts)
  and `captures/` (raw USB captures and derived tables behind `PROTOCOL.md`).
- `tests/run.sh` (`bash tests/run.sh`): the volume table in the patch is
  reproduced by `tools/gen_table.py` from the captures, `.SRCINFO` matches the
  `PKGBUILD`, and the package installs exactly the three files under
  `/usr/src/epos-gsx1000-$pkgver/`.
- `system/`: optional extras, see above.

## License

GPL-2.0-only, see `LICENSE`. The ACP profile in `system/` is derived from
PulseAudio's profile sets and keeps its LGPL-2.1-or-later header.

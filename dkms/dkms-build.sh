#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the patched snd-usb-audio module for a given kernel release.
# Used by DKMS (MAKE[0]) and by scripts/build-module.sh.
#   dkms-build.sh <kernel-release> <work-dir> <patch-file>
# The kernel.org tarball matching the kernel version is downloaded once and cached.
set -euo pipefail

KREL=$1
WORK=$(cd "$2" && pwd)
PATCH=$(realpath "$3")
KBUILD=/lib/modules/$KREL/build

# 7.3.6-1-arch -> 7.3.6; a zero patch level (7.4.0) maps to the 7.4 tarball
KVER=$(echo "$KREL" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')
KVER=${KVER%.0}
KMAJ=${KVER%%.*}

if [ "$(id -u)" = 0 ]; then
    CACHE=${EPOS_GSX_CACHE:-/var/cache/epos-gsx1000}
else
    CACHE=${EPOS_GSX_CACHE:-$WORK/cache}
fi
mkdir -p "$CACHE"

src="$CACHE/linux-$KVER/sound/usb"
if [ ! -d "$src" ]; then
    tarball="$CACHE/linux-$KVER.tar.xz"
    if [ ! -f "$tarball" ]; then
        curl -sSfL -o "$tarball.part" "https://cdn.kernel.org/pub/linux/kernel/v$KMAJ.x/linux-$KVER.tar.xz"
        mv "$tarball.part" "$tarball"
    fi
    tar -C "$CACHE" -xf "$tarball" "linux-$KVER/sound/usb"
    # Only the sound/usb subtree is needed; drop the large tarball afterwards
    rm -f "$tarball"
fi

rm -rf "$WORK/usb"
cp -r "$src" "$WORK/usb"
patch -d "$WORK/usb" -p3 < "$PATCH"

llvm=()
grep -q '^CONFIG_CC_IS_CLANG=y' "$KBUILD/.config" && llvm=(LLVM=1)
make -C "$KBUILD" M="$WORK/usb" "${llvm[@]}" -j"$(nproc)" modules

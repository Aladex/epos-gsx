#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the patched snd-usb-audio for the running kernel into build/usb (no install).
# For a persistent install that survives kernel updates use scripts/dkms-install.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$ROOT/build"
bash "$ROOT/dkms/dkms-build.sh" "$(uname -r)" "$ROOT/build" "$ROOT/gsx1000-volume.patch"
echo "Built: $ROOT/build/usb/snd-usb-audio.ko"

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Register the module with DKMS so it is rebuilt on every kernel update.
#   scripts/dkms-install.sh            install / upgrade
#   scripts/dkms-install.sh --remove   remove from DKMS
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=epos-gsx1000
VERSION=$(cat "$ROOT/VERSION")

for old in $(dkms status -m "$NAME" 2>/dev/null | grep -oE "^$NAME/[^,:]+" | sort -u); do
    sudo dkms remove "$old" --all
done
[ "${1:-}" = "--remove" ] && exit 0

dest=/usr/src/$NAME-$VERSION
sudo rm -rf "$dest"
sudo install -d "$dest"
sudo install -m644 "$ROOT/gsx1000-volume.patch" "$dest/"
sudo install -m755 "$ROOT/dkms/dkms-build.sh" "$dest/"
sed "s/@VERSION@/$VERSION/" "$ROOT/dkms/dkms.conf" | sudo tee "$dest/dkms.conf" >/dev/null

sudo dkms install "$NAME/$VERSION" -k "$(uname -r)"
dkms status -m "$NAME"

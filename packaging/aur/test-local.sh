#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the AUR package from the WORKING TREE instead of the GitHub tag, for
# local testing before the tag exists. The committed PKGBUILD keeps the GitHub
# URL; this script copies it to a temporary build directory and rewrites source=
# to a tarball made from the tracked files plus untracked non-ignored files, so
# uncommitted work is what gets tested.
#
#   packaging/aur/test-local.sh [pkgbuild-dir] [out-dir]
#     pkgbuild-dir  directory holding PKGBUILD and the .install (default: this dir)
#     out-dir       where the .pkg.tar.zst lands (default: a temp dir, printed)
#
# Exit status: makepkg's. Nothing is installed.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PKGDIR=$(cd "${1:-$HERE}" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${2:-$(mktemp -d)}
mkdir -p "$OUT"

VER=$(cat "$ROOT/VERSION")
TARBALL="$OUT/epos-gsx-$VER.tar.gz"

# Tracked files plus untracked files that are not ignored, archived under the
# directory name makepkg expects for the GitHub tarball. Only files that exist
# on disk are listed, so a staged deletion cannot break tar.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
( cd "$ROOT" && git ls-files -z --cached --others --exclude-standard ) \
    | ( cd "$ROOT" && while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done ) \
    | ( cd "$ROOT" && tar --null -T - -cf - ) | tar -C "$STAGE" -xf -
tar -C "$STAGE" -czf "$TARBALL" --transform "s,^,epos-gsx-$VER/," .

BUILD=$(mktemp -d)
trap 'rm -rf "$STAGE" "$BUILD"' EXIT
cp "$PKGDIR/PKGBUILD" "$PKGDIR"/epos-gsx1000-dkms.install "$BUILD/"
# makepkg only accepts local sources inside the build directory.
cp "$TARBALL" "$BUILD/"
# Point source at the local tarball; keep everything else identical.
sed -i "s#^source=(.*)#source=(\"epos-gsx-$VER.tar.gz\")#" "$BUILD/PKGBUILD"
sed -i "s#^sha256sums=(.*)#sha256sums=('SKIP')#" "$BUILD/PKGBUILD"

echo "test-local: building $VER from the working tree into $OUT" >&2
( cd "$BUILD" && makepkg -f --nodeps --noconfirm )
mv "$BUILD"/*.pkg.tar.zst "$OUT/"
echo "$OUT"

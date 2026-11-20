#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the kernel for Henge's Linux machine (docs/linux-machine.md): arm64
# defconfig plus tools/linux/henge-kernel.config, whose main point is 16 KB
# pages (HengeVM's software TLB keeps 16 KB pages; smaller guest pages take
# the slow path on every access).
#
#   tools/linux/build-kernel.sh OUTDIR [--source DIR] [--version 6.12.x]
#
# OUTDIR gets Image (uncompressed, what the machine loads), config, and the
# modules under lib/modules/<release>. Without --source the source comes from
# kernel.org: --version, or the newest 6.12 long-term release. On a host that
# is not arm64, set CROSS_COMPILE (aarch64-linux-gnu-). Needs gcc, make, bc,
# bison, flex, libssl-dev, libelf-dev.
set -euo pipefail

OUT=""; SRC=""; VERSION=""; SERIES=${SERIES:-6.12}
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SRC=$2; shift ;;
        --version) VERSION=$2; shift ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) OUT=$1 ;;
    esac
    shift
done
[ -n "$OUT" ] || { echo "usage: $0 OUTDIR [--source DIR] [--version X.Y.Z]" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
if [ "$(uname -m)" != aarch64 ] && [ -z "${CROSS_COMPILE:-}" ]; then
    export CROSS_COMPILE=aarch64-linux-gnu-
fi

if [ -z "$SRC" ]; then
    if [ -z "$VERSION" ]; then
        VERSION=$(curl -fsSL https://www.kernel.org/releases.json | python3 -c '
import json, sys
series = sys.argv[1]
for r in json.load(sys.stdin)["releases"]:
    if r["version"] == series or r["version"].startswith(series + "."):
        print(r["version"]); break' "$SERIES")
        VERSION=${VERSION:-$SERIES}
    fi
    echo "== Linux $VERSION from kernel.org"
    SRC="${TMPDIR:-/tmp}/linux-$VERSION"
    if [ ! -f "$SRC/Makefile" ]; then
        mkdir -p "$SRC"
        curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${VERSION%%.*}.x/linux-$VERSION.tar.xz" | tar -xJ -C "$SRC" --strip-components=1
    fi
fi

cd "$SRC"
export ARCH=arm64
echo "== configuring: defconfig + henge-kernel.config"
make -s defconfig
scripts/kconfig/merge_config.sh -m .config "$HERE/tools/linux/henge-kernel.config" >/dev/null
make -s olddefconfig
# Every line of the fragment must have survived (a dependency it lacks drops it silently).
missing=0
while IFS= read -r line; do
    case "$line" in CONFIG_*=*) ;; *) continue ;; esac
    key=${line%%=*}; want=${line#*=}
    if [ "$want" = n ]; then
        grep -q "^$key=" .config && { echo "   still set: $line"; missing=1; }
    elif ! grep -qx "$key=$want" .config; then
        echo "   not taken: $line (got: $(grep "^$key=" .config || echo unset))"; missing=1
    fi
done < "$HERE/tools/linux/henge-kernel.config"
[ "$missing" = 0 ] || echo "   (some options were not taken; see above)"

echo "== building ($(nproc) jobs)"
make -s -j"$(nproc)" Image modules
RELEASE=$(make -s kernelrelease)
rm -rf "$OUT/lib/modules/$RELEASE"
make -s modules_install INSTALL_MOD_PATH="$OUT" INSTALL_MOD_STRIP=1
rm -f "$OUT/lib/modules/$RELEASE/build" "$OUT/lib/modules/$RELEASE/source"
cp arch/arm64/boot/Image "$OUT/Image"
cp .config "$OUT/config"
echo "$RELEASE" > "$OUT/release"
echo "== done: Linux $RELEASE in $OUT ($(du -sh "$OUT" | cut -f1))"

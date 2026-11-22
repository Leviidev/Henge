#!/bin/zsh
# Copies the prebuilt iOS pieces Henge links into ios/deps (not in git):
#   StikJIT.xcframework   Built-in StikJIT (MPL-2.0), as Husk vendors it
#   libhusk_rppairing.a   on-device pairing (Husk's src/rppairing-ios, scripts/build_rppairing_ios.sh)
#   libslirp, glib, intl, pcre2 (arm64 iOS static libraries, Husk's scripts/build_ios.sh)
set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# A checkout inside this repository (deps/Husk, ignored by git) first, then the usual place.
if [ -z "$HUSK" ]; then
    if [ -d "$REPO/deps/Husk" ]; then HUSK="$REPO/deps/Husk"; else HUSK="$HOME/Documents/Coding/Husk"; fi
fi
DEPS="$REPO/ios/deps"
mkdir -p "$DEPS/lib"
rm -rf "$DEPS/StikJIT.xcframework"
ditto "$HUSK/src/app/Frameworks/StikJIT.xcframework" "$DEPS/StikJIT.xcframework"
cp "$HUSK/build/ios-arm64/lib/libhusk_rppairing.a" "$DEPS/lib/"
for l in libslirp libglib-2.0 libintl libpcre2-8; do cp "$HUSK/build/ios-arm64/sysroot/lib/$l.a" "$DEPS/lib/"; done
echo "deps in $DEPS"

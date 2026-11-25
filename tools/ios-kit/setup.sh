#!/bin/bash
# Makes ~/iosdev: the part of Xcode that builds an iPhone app (the compilers and the iPhone SDK, about 1 GB), and the
# command `iosapp`. Run in the Mac after downloading Xcode from developer.apple.com/download (sign in there yourself):
#   bash setup.sh                 finds ~/Downloads/Xcode*.xip, or /Applications/Xcode*.app
#   bash setup.sh PATH            an Xcode .xip or .app
# Nothing of Apple's is in this script or in Henge: it is copied from the Xcode you downloaded, on this Mac.
set -e
D=$HOME/iosdev; SRC=$1
if [ -z "$SRC" ]; then SRC=$(ls -dt "$HOME"/Downloads/Xcode*.xip "$HOME"/Downloads/Xcode*.app /Applications/Xcode*.app 2>/dev/null | head -1) || true; fi
[ -e "$SRC" ] || { echo "Xcode isn't here. Download it (an Apple silicon .xip) from https://developer.apple.com/download/all and run this again."; exit 1; }
echo "From: $SRC"
TMP=
case "$SRC" in
*.xip)
  free=$(df -g "$HOME" | awk 'NR==2 {print $4}'); size=$(( $(stat -f %z "$SRC") / 1073741824 + 1 )); need=$(( size * 4 ))
  if [ "$free" -lt "$need" ]; then echo "$free GB free; unpacking needs about $need GB. Make room and run this again."; exit 1; fi
  TMP=$HOME/.iosdev-unpack; mkdir -p "$TMP"
  echo "Unpacking (this takes a while; the Mac may look stuck)..."
  (cd "$TMP" && xip --expand "$SRC")
  APP=$(ls -d "$TMP"/Xcode*.app | head -1) ;;
*) APP=$SRC ;;
esac
X=$APP/Contents/Developer; T=$X/Toolchains/XcodeDefault.xctoolchain; P=$X/Platforms/iPhoneOS.platform/Developer
[ -d "$P/SDKs" ] || { echo "This Xcode has no iPhone SDK."; exit 1; }
N=$D/new; mkdir -p "$N/tc/usr/bin" "$N/tc/usr/lib" "$N/sdk" "$N/plugins"
echo "Copying what builds iPhone apps..."
for b in swift-frontend swift swiftc clang clang++ ld codesign_allocate libtool ar swift-plugin-server; do
  [ -e "$T/usr/bin/$b" ] && cp -a "$T/usr/bin/$b" "$N/tc/usr/bin/"
done
for l in swift/iphoneos swift/host swift/shims swift/apinotes swift/clang swift/pm clang; do
  [ -e "$T/usr/lib/$l" ] && mkdir -p "$N/tc/usr/lib/$(dirname $l)" && cp -a "$T/usr/lib/$l" "$N/tc/usr/lib/$(dirname $l)/"
done
cp -a "$T"/usr/lib/*.dylib "$N/tc/usr/lib/" 2>/dev/null || true
cp -a "$P"/SDKs/* "$N/sdk/"
cp -a "$P"/usr/lib/swift/host/plugins/* "$N/plugins/" 2>/dev/null || true
for x in tc sdk plugins; do
  if [ -d "$D/$x" ]; then mv "$D/$x" "$N/old-$x"; fi
  mv "$N/$x" "$D/$x"
done
rm -rf "$HOME/iosdev/new"
if [ -n "$TMP" ]; then rm -rf "$HOME/.iosdev-unpack"; fi
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$D/bin"
if [ -f "$HERE/iosapp" ]; then cp "$HERE/iosapp" "$D/bin/iosapp"; else
  curl -fsSL https://raw.githubusercontent.com/Leviidev/Henge/main/tools/ios-kit/iosapp -o "$D/bin/iosapp"; fi
chmod +x "$D/bin/iosapp"
grep -qs 'iosdev/bin' "$HOME/.zprofile" || echo 'export PATH="$HOME/iosdev/bin:$PATH"' >> "$HOME/.zprofile"
echo "Done: $(du -sh "$D" | cut -f1) in $D. Open a new Terminal window, then: iosapp new MyApp"
[ -z "$TMP" ] || echo "The .xip itself is not needed any more: $SRC"

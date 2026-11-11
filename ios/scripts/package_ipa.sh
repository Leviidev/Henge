#!/bin/zsh
# Builds Henge for iOS and writes ~/Desktop/Henge.ipa (or ~/Desktop/Henge.tipa with --trollstore).
# Unsigned build, then signed ad hoc inside out with the entitlements file named by the
# HENGE_ENTITLEMENTS environment variable (default Henge/Henge.entitlements), as Husk's
# package_ipa.sh does: the sideloader (SideStore, AltStore, Impactor) re-signs it
# with the user's own certificate and keeps the entitlements it can.
# --trollstore strips the entitlements TrollStore bans under PPL/TXM.
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
TROLLSTORE=false
[ "$1" = "--trollstore" ] && TROLLSTORE=true
OUT="$HOME/Desktop/Henge.ipa"
[ "$TROLLSTORE" = true ] && OUT="$HOME/Desktop/Henge.tipa"
OUT="${HENGE_IPA_OUTPUT:-$OUT}"
mkdir -p "$(dirname "$OUT")"
[ -d "$IOS/deps/StikJIT.xcframework" ] || "$IOS/scripts/fetch_deps.sh"
[ -f "$IOS/deps/lib/libHGOnDeviceShader.a" ] || {
    echo "Missing on-device shader provider. See compat/ondevice-shaders/README.md and tools/compat/build_ondevice_provider.py." >&2
    exit 1
}
python3 "$IOS/../tools/compat/check_ondevice_provider.py"
cd "$IOS"
xcodegen generate >/dev/null
DD="${HENGE_DERIVED_DATA:-$IOS/build/DerivedData}"
mkdir -p "$IOS/build"
xcodebuild -project Henge.xcodeproj -scheme Henge -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build > "$DD.buildlog" 2>&1 || {
    # Never package what an older build left behind.
    grep -E "error:|BUILD" "$DD.buildlog" | sort -u
    echo "==> the build failed; nothing packaged" >&2
    exit 1
}
grep -E "BUILD" "$DD.buildlog" || true
APP="$DD/Build/Products/Release-iphoneos/Henge.app"
rc=0
for f in "$APP/Henge" "$APP/henge-jit.js" "$APP/PlugIns/HengeJITHelper.appex/HengeJITHelper" \
         "$APP/Frameworks/StikJIT.framework/StikJIT" "$APP/Frameworks/StikJIT.framework/Info.plist"; do
    if [ -f "$f" ]; then printf "  ok       %s\n" "${f#$APP/}"; else echo "  MISSING  ${f#$APP/}" >&2; rc=1; fi
done
[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/henge-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
ENT="$STAGE/entitlements.plist"
# HENGE_ENTITLEMENTS picks another file, as for xcodebuild (Henge/Henge.personal.entitlements for a free team).
cp "$IOS/${HENGE_ENTITLEMENTS:-Henge/Henge.entitlements}" "$ENT"
if [ "$TROLLSTORE" = true ]; then
    # App-context persona qualification. The helper exposes verified probes,
    # read-only inspection and discard-only private-copy recovery. Original
    # guest mutation and mounting remain unavailable.
    # Entitlement names are literal dictionary keys, not plutil dotted key paths.
    python3 - "$ENT" <<'PY'
import plistlib
import sys
from pathlib import Path
path = Path(sys.argv[1])
entitlements = plistlib.loads(path.read_bytes())
for key in ('com.apple.private.cs.debugger', 'dynamic-codesigning',
            'com.apple.private.skip-library-validation'):
    entitlements.pop(key, None)
entitlements['com.apple.private.security.no-sandbox'] = True
entitlements['com.apple.private.persona-mgmt'] = True
path.write_bytes(plistlib.dumps(entitlements))
PY
fi
SAPP="$STAGE/Payload/Henge.app"
xattr -rc "$SAPP"
plutil -insert HengeBuildCommit -string "$(git -C "$IOS/.." rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" "$SAPP/Info.plist"
plutil -insert HengeBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SAPP/Info.plist"
# Apple's boot ROM is fetched on the device (BootROM.swift) and must never ship. An older build folder can still
# hold a copy from when the app bundled it, so it goes, and nothing is packaged if any is left.
rm -f "$SAPP/AVPBooter.vmapple2.bin"
if [ -n "$(find "$STAGE" -iname 'AVPBooter*' -o -iname 'AVPSEPBooter*')" ]; then
  echo "Apple's boot ROM is in the app: not packaging." >&2
  exit 1
fi
sign() { codesign --force --sign - --timestamp=none "$@"; }
GUEST_BUILD_ARGS=(--output "$STAGE/guest-build")
[ -n "${HENGE_VLC_ARCHIVES:-}" ] && GUEST_BUILD_ARGS+=(--vlc-archives "$HENGE_VLC_ARCHIVES")
python3 "$IOS/../tools/compat/build_guest_payload.py" "${GUEST_BUILD_ARGS[@]}"
cp "$STAGE/guest-build/henge-guest-payload.tar.gz" "$SAPP/"
cp "$STAGE/guest-build/henge-guest-payload.json" "$SAPP/"
if [ "$TROLLSTORE" = true ]; then
    # Bind validation to this package's exact resources, independently of any
    # caller-supplied manifest or path. Constants are inside the signed helper.
    PAYLOAD_HEADER="$STAGE/HengeGuestPayloadIdentity.h"
    python3 - "$STAGE/guest-build" "$PAYLOAD_HEADER" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys
root, header = map(Path, sys.argv[1:])
descriptor = json.loads((root / 'henge-guest-payload.json').read_text())
manifest = json.loads((root / 'payload/manifest.json').read_text())
values = {
    'HG_PAYLOAD_DESCRIPTOR_SHA': hashlib.sha256((root / 'henge-guest-payload.json').read_bytes()).hexdigest(),
    'HG_PAYLOAD_RECIPE': descriptor['compiler_recipe'],
    'HG_PAYLOAD_ID': descriptor['payload_id'],
    'HG_PAYLOAD_VLC_CORE': manifest['vlc']['reference_core_sha256'],
    'HG_PAYLOAD_VLC_LOCK': manifest['vlc']['reference_lock_sha256'],
}
assert all(re.fullmatch('[0-9a-f]{64}', value) for value in values.values())
header.write_text(''.join('#define ' + key + ' ' + json.dumps(value) + '\n' for key, value in values.items()))
PY
    xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 \
        -Wall -Wextra -Werror -O2 -fobjc-arc -include "$PAYLOAD_HEADER" \
        "$IOS/../compat/guest-provisioning/root_helper.c" \
        "$IOS/../compat/guest-provisioning/HGGuestPayload.m" \
        "$IOS/../compat/guest-provisioning/HGGuestDisk.c" \
        "$IOS/../compat/guest-provisioning/HGGuestAPFS.c" \
        "$IOS/../compat/guest-provisioning/HGGuestClone.c" \
        "$IOS/../compat/guest-provisioning/HGGuestRoles.c" \
        "$IOS/../compat/guest-provisioning/HGGuestRoleWrite.c" \
        "$IOS/../compat/guest-provisioning/HGGuestWorkspace.c" \
        "$IOS/../compat/guest-provisioning/HGGuestAttachment.m" \
        "$IOS/../compat/guest-provisioning/HGGuestMedia.m" -framework Foundation -lz \
        -o "$SAPP/henge-root-helper"
    HELPER_ENT="$STAGE/helper-entitlements.plist"
    python3 - "$HELPER_ENT" <<'PY'
import plistlib
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'com.apple.private.security.no-sandbox': True}))
PY
    sign --entitlements "$HELPER_ENT" "$SAPP/henge-root-helper"
fi
for fw in "$SAPP"/Frameworks/*.framework; do [ -d "$fw" ] && sign "$fw"; done
for ex in "$SAPP"/PlugIns/*.appex; do [ -d "$ex" ] && sign "$ex"; done
sign --entitlements "$ENT" "$SAPP"
EMBEDDED=$(codesign -d --entitlements - "$SAPP" 2>&1 || true)
# Every key the entitlements file asks for must be in the signature.
for k in $(plutil -convert json -o - "$ENT" | python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)))'); do
    grep -q "$k" <<< "$EMBEDDED" || { echo "==> $k did not embed; refusing to package" >&2; exit 1; }
done
( cd "$STAGE" && zip -qry "$STAGE/package.tmp" Payload )
mv -f "$STAGE/package.tmp" "$OUT" # atomic: a half-written IPA never sits where the good one was
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"

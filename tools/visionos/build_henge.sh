#!/bin/zsh
# Builds Henge's iPad app signed for development with your team, to install directly on an Apple Vision Pro
# (where it runs as a "Designed for iPad" app) or any iPhone or iPad registered to the team.
#   TEAM=XXXXXXXXXX BUNDLE_ID=com.example.henge tools/visionos/build_henge.sh
# Needs a built Husk at deps/Husk (or HUSK=...): see README.md, Building. Writes build/visionos/Henge.app.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEAM=${TEAM:?your Apple developer team id is required (TEAM=...)}
BUNDLE_ID=${BUNDLE_ID:?a bundle identifier of your own is required (BUNDLE_ID=...)}
cd "$ROOT"
[ -f ios/deps/lib/libslirp.a ] || zsh ios/scripts/fetch_deps.sh
[ -f build/ios/libhengerestore.a ] || zsh tools/build_ios_restore.sh
cd ios
xcodegen generate >/dev/null
DD="$ROOT/build/visionos/DerivedData"
mkdir -p "$DD"
xcodebuild -project Henge.xcodeproj -scheme Henge -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic HENGE_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    HENGE_ENTITLEMENTS="$ROOT/tools/visionos/Henge.development.entitlements" build > "$DD.buildlog" 2>&1 || {
    grep -E "error:|BUILD" "$DD.buildlog" | sort -u
    echo "==> the build failed (full log: $DD.buildlog)" >&2
    exit 1
}
rm -rf "$ROOT/build/visionos/Henge.app"
ditto "$DD/Build/Products/Release-iphoneos/Henge.app" "$ROOT/build/visionos/Henge.app"
echo "==> $ROOT/build/visionos/Henge.app"

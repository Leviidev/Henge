#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# ios/scripts/build-gpu-deps.sh [out]
#
# Builds the Linux machine's 3D renderer for iOS (arm64), as UTM builds its
# own, from UTM's iOS-ready forks at the commits UTM pins:
#
#   ANGLE (WebKit's tree)  OpenGL ES 3 and EGL on Metal    BSD
#   libepoxy               GL function loading, over EGL   MIT
#   virglrenderer          virgl (Gallium) commands to GL  MIT
#
# Each library becomes a framework in <out>/Frameworks (the app embeds them);
# their headers go to <out>/include. On a Mac with Xcode; meson, ninja and
# pkg-config from Homebrew. Henge's engine uses them through
# devices/vgpu_virgl.c (HV_VIRGL, HV_VIRGL_ANGLE).
set -euo pipefail

OUT=$(mkdir -p "${1:-ios/deps-gpu}" && cd "${1:-ios/deps-gpu}" && pwd)
WORK=${WORK:-$PWD/build/gpu-deps}
MINVER=${MINVER:-17.0}
NCPU=$(sysctl -n hw.ncpu)

WEBKIT_REPO=https://github.com/utmapp/WebKit.git
WEBKIT_COMMIT=ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10
EPOXY_REPO=https://github.com/utmapp/libepoxy.git
EPOXY_COMMIT=bf98587477fe68d07b93319ece7b40a7d0e2eabe
VIRGL_REPO=https://github.com/utmapp/virglrenderer.git
VIRGL_COMMIT=dd0652b13e589c4c124ea79123a3adcd85173f4f

mkdir -p "$WORK"
# Python for the code generators, in an environment of its own: virglrenderer's format tables need PyYAML
# (UTM's build checks for it, and for mako, which Mesa's generators use).
[ -x "$WORK/venv/bin/python3" ] || python3 -m venv "$WORK/venv"
"$WORK/venv/bin/python3" -m pip install -q --disable-pip-version-check pyyaml mako
export PATH="$WORK/venv/bin:$PATH"
PY="$WORK/venv/bin/python3"
"$PY" -c 'import yaml, mako; print("python:", __import__("sys").version.split()[0], "with yaml and mako")'
PREFIX="$WORK/prefix"
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"

SDKPATH=$(xcrun --sdk iphoneos --show-sdk-path)
TARGET="-target arm64-apple-ios$MINVER"
export CFLAGS="$TARGET -isysroot $SDKPATH -O2"
export LDFLAGS="$TARGET -isysroot $SDKPATH"
CC=$(xcrun --sdk iphoneos -f clang)
CXX=$(xcrun --sdk iphoneos -f clang++)

# One commit of a repository (only some directories of it, if given).
fetch() {
    local repo=$1 commit=$2 dir=$3
    shift 3
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then return; fi
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" remote add origin "$repo"
    if [ $# -gt 0 ]; then
        git -C "$dir" config core.sparseCheckout true
        git -C "$dir" sparse-checkout set --no-cone "$@"
    fi
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$commit"
    git -C "$dir" checkout -q FETCH_HEAD
}

echo "== sources"
fetch "$WEBKIT_REPO" "$WEBKIT_COMMIT" "$WORK/WebKit" /Source/ThirdParty/ANGLE /Configurations /Tools/ccache
fetch "$EPOXY_REPO" "$EPOXY_COMMIT" "$WORK/libepoxy"
fetch "$VIRGL_REPO" "$VIRGL_COMMIT" "$WORK/virglrenderer"
# Henge's changes to it (ios/patches): 4x multisampling reported on ANGLE's OpenGL ES 3.0, which Chrome needs.
git -C "$WORK/virglrenderer" reset -q --hard FETCH_HEAD
for p in "$(cd "$(dirname "$0")/.." && pwd)"/patches/virglrenderer-*.patch; do
    [ -f "$p" ] && git -C "$WORK/virglrenderer" apply "$p" && echo "   patched: $(basename "$p")"
done
[ -d "$WORK/depot_tools" ] || git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"

echo "== ANGLE"
(
    cd "$WORK/WebKit/Source/ThirdParty/ANGLE"
    rm -rf ANGLE.xcarchive
    env -i PATH="$WORK/depot_tools:$PATH" HOME="$HOME" xcodebuild archive -archivePath ANGLE -scheme ANGLE \
        -sdk iphoneos -arch arm64 -configuration Release \
        WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR="" CODE_SIGNING_ALLOWED=NO \
        GCC_TREAT_WARNINGS_AS_ERRORS=NO IPHONEOS_DEPLOYMENT_TARGET="$MINVER" \
        WK_LIBCPP_ASSERTIONS_CFLAGS= -quiet
    # (WebKit's configuration asks for _LIBCPP_ENABLE_ASSERTIONS, which Xcode 27's libc++ refuses outright.)
    find ANGLE.xcarchive/Products -maxdepth 4 | head -40
    rsync -a ANGLE.xcarchive/Products/usr/local/lib/ "$PREFIX/lib/"
    rsync -a include/ "$PREFIX/include/"
)
ls -la "$PREFIX/lib"
ls "$PREFIX/include" "$PREFIX/include/EGL"
# pkg-config files for what epoxy and virglrenderer look for.
for pc in egl:EGL glesv2:GLESv2; do
    name=${pc%%:*} lib=${pc##*:}
    cat > "$PREFIX/lib/pkgconfig/$name.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $name
Description: ANGLE's $lib
Version: 1.5
Libs: -L\${libdir} -l$lib
Cflags: -I\${includedir}
EOF
done

# meson's description of the target: iOS on arm64, a Darwin kernel (virglrenderer's Apple code keys on 'darwin').
cross() {
    cat > "$WORK/ios-$1.cross" <<EOF
[properties]
needs_exe_wrapper = true
has_function_pipe2 = false
has_function_dup3 = false
[built-in options]
c_args = ['-target', 'arm64-apple-ios$MINVER', '-isysroot', '$SDKPATH', '-O2', '-I$PREFIX/include']
cpp_args = ['-target', 'arm64-apple-ios$MINVER', '-isysroot', '$SDKPATH', '-O2', '-I$PREFIX/include']
objc_args = ['-target', 'arm64-apple-ios$MINVER', '-isysroot', '$SDKPATH', '-O2', '-I$PREFIX/include']
c_link_args = ['-target', 'arm64-apple-ios$MINVER', '-isysroot', '$SDKPATH', '-L$PREFIX/lib']
cpp_link_args = ['-target', 'arm64-apple-ios$MINVER', '-isysroot', '$SDKPATH', '-L$PREFIX/lib']
objc_link_args = ['-target', 'arm64-apple-ios$MINVER', '-isysroot', '$SDKPATH', '-L$PREFIX/lib']
[binaries]
c = ['$CC']
cpp = ['$CXX']
objc = ['$CC']
ar = ['$(xcrun --sdk iphoneos -f ar)']
nm = ['$(xcrun --sdk iphoneos -f nm)']
ranlib = ['$(xcrun --sdk iphoneos -f ranlib)']
strip = ['$(xcrun --sdk iphoneos -f strip)', '-x']
pkg-config = ['$(command -v pkg-config)']
python = ['$PY']
python3 = ['$PY']
[host_machine]
system = '$1'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
    if [ "$1" = darwin ]; then printf "kernel = 'xnu'\nsubsystem = 'ios'\n" >> "$WORK/ios-$1.cross"; fi
}
cross ios
cross darwin
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=

meson_build() {
    local system=$1 src=$2
    shift 2
    (
        cd "$src"
        rm -rf henge-build
        meson setup henge-build --prefix="$PREFIX" --buildtype=release --cross-file "$WORK/ios-$system.cross" "$@"
        meson compile -C henge-build -j "$NCPU"
        meson install -C henge-build
    )
}

echo "== libepoxy"
meson_build ios "$WORK/libepoxy" -Dtests=false -Dglx=no -Degl=yes -Dx11=false -Ddocs=false

echo "== virglrenderer"
meson_build darwin "$WORK/virglrenderer" -Dtests=false -Dcheck-gl-errors=false -Dvenus=false -Dneptune=false \
    -Dplatforms=egl -Dvideo=false -Dvtest=false

echo "== frameworks"
# Each library as <name>.framework (what an iOS app may carry), named by @rpath, its imports of the others too.
rm -rf "$OUT/Frameworks" "$OUT/include"
mkdir -p "$OUT/Frameworks" "$OUT/include"
libs=$(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.dylib')
fwname() { local b; b=$(basename "$1"); b=${b%%.*}; echo "${b#lib}"; }
for f in $libs; do
    name=$(fwname "$f")
    fw="$OUT/Frameworks/$name.framework"
    mkdir -p "$fw"
    cp "$f" "$fw/$name"
    install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
    cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>com.henge.gpu.$(echo "$name" | tr '_' '-')</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>$MINVER</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
EOF
done
for fw in "$OUT"/Frameworks/*.framework; do
    bin="$fw/$(basename "$fw" .framework)"
    for dep in $(otool -L "$bin" | tail -n +2 | awk '{print $1}'); do
        case "$dep" in /usr/lib/* | /System/*) continue ;; esac
        name=$(fwname "$dep")
        [ -d "$OUT/Frameworks/$name.framework" ] && install_name_tool -change "$dep" "@rpath/$name.framework/$name" "$bin"
    done
    otool -L "$bin" | tail -n +2
done
rsync -a "$PREFIX/include/" "$OUT/include/"
cat > "$OUT/VERSIONS" <<EOF
ANGLE (WebKit) $WEBKIT_REPO $WEBKIT_COMMIT
libepoxy $EPOXY_REPO $EPOXY_COMMIT
virglrenderer $VIRGL_REPO $VIRGL_COMMIT
iOS $MINVER arm64
EOF
ls -la "$OUT/Frameworks"
du -sh "$OUT/Frameworks"/*

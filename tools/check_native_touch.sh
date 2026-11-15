#!/bin/bash
# Select the latest installed Xcode with DEVELOPER_DIR. This does not need the external iOS build dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
failures=0
check() {
    if "$@"; then :; else
        local status=$?
        printf 'Native touch check failed (%s):' "$status" >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        failures=$((failures+1))
    fi
}
check python3 tests/test_native_touch_packaging.py
check make -k test-native-touch test-guest-connection test-usb-touchscreen build/henge-agent.gz build/henge-touch-agent.tar.gz build/share.o build/native_touch.o
check build/henge-touch-agent --check-launch
check python3 tools/verify_native_touch_package.py build/henge-touch-agent.tar.gz
check xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -parse-as-library -typecheck tools/henge-touch-agent.swift tools/native-touch/*.swift
check xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -parse-as-library tools/native-touch-probe.swift tools/native-touch/*.swift -o build/native-touch-probe
check python3 tools/typecheck_app.py --sdk iphonesimulator
for source in native_touch share; do
    check xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -Wall -Wextra -Werror \
        -Ihost -c "host/$source.c" -o "build/${source}_ios.o"
done

if (( failures )); then exit 1; fi

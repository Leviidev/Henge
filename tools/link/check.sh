#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/link
cc -std=c11 -Wall -Wextra -Werror -Idevices tests/test_pvg_display.c -o build/link/test_pvg_display
build/link/test_pvg_display
make build/pvg_lite.o build/pvg_metal.o
python3 tests/test_surface_sync.py
python3 tests/test_surface_hash_limit.py
python3 tests/test_display_snapshot.py
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Idevices tests/test_planar_registry.m -framework Foundation -framework IOSurface -framework Metal -o build/link/test_planar_registry
build/link/test_planar_registry
cc -std=c11 -Wall -Wextra -O1 -g -fsanitize=address,undefined -Idevices -Icore -Ihost tests/test_pvg_ports.c -framework CoreFoundation -Wl,-dead_strip -o build/link/test_pvg_ports
build/link/test_pvg_ports
xcrun -sdk macosx metal -c devices/pvg_screen.metal -o build/link/screen.air
xcrun -sdk macosx metallib build/link/screen.air -o build/link/screen.metallib
swiftc -swift-version 5 ios/Henge/Controls/GamepadState.swift ios/Henge/Link/LinkProtocol.swift ios/Henge/Link/LinkReconnectPolicy.swift ios/Henge/Link/LinkPairing.swift ios/Henge/Link/LinkTransport.swift ios/Henge/Link/LinkVideo.swift ios/Henge/Link/LinkFlowControl.swift ios/Henge/Link/LinkDecodeWorker.swift tests/link_flow_checks.swift tests/link_pairing_checks.swift tests/test_link.swift -framework Network -framework Security -framework Metal -framework CoreMedia -framework CoreVideo -framework VideoToolbox -o build/link/test_link
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos swiftc -typecheck -swift-version 5 -target arm64-apple-ios17.0 -sdk "$SDK" -import-objc-header tests/link_bridge_fixture.h ios/Henge/Components/InterfaceStyle.swift ios/Henge/Controls/*.swift ios/Henge/Link/*.swift tests/link_ui_fixture.swift
build/link/test_link build/link/screen.metallib

python3 tests/test_link_control_services.py

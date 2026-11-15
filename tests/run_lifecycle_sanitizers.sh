#!/bin/bash
# Collect independent failures in one diagnostic pass; any failure blocks the IPA.
set -uo pipefail
cd "$(dirname "$0")/.."
failures=0
check() {
    local status
    printf '\nChecking:'
    printf ' %q' "$@"
    printf '\n'
    "$@"
    status=$?
    if (( status )); then
        printf 'CHECK FAILED (%d): %s\n' "$status" "$*" >&2
        failures=$((failures + 1))
    fi
    return "$status"
}
flags='-std=c11 -Wall -Wextra -O1 -g -fno-omit-frame-pointer -Icore -Ihost -Idevices'
# Separate objects: release code has no sanitizer flags or diagnostic spills.
if check make -j3 B=build/asan ASFLAGS=-DHV_SANITIZER_HELPERS=1 CFLAGS="$flags -fsanitize=address,undefined" build/asan/test_vm_lifecycle build/asan/test_pvg_lifecycle build/asan/test_jit build/asan/test_mem; then
    check env HV_DEADLINE_KICKS=1 ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 build/asan/test_vm_lifecycle
    for binary in test_vm_lifecycle test_pvg_lifecycle test_jit test_mem; do
        check env ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "build/asan/$binary"
    done
fi
# These paths do not depend on the JIT/snapshot tests passing.
if check make -j3 B=build/tsan CFLAGS="$flags -fsanitize=thread" build/tsan/test_dns_lifecycle build/tsan/test_idle_ticker; then
    check env TSAN_OPTIONS=halt_on_error=1 build/tsan/test_dns_lifecycle
    check env TSAN_OPTIONS=halt_on_error=1 build/tsan/test_idle_ticker
fi
check python3 tests/test_gpu_copy_bounds.py
check python3 tests/test_group_copy_sharing.py
check python3 tests/test_jit_allocation.py
check python3 tests/test_simulator_profiles.py
check python3 tests/test_gpu_upload.py
check python3 tests/test_surface_hash_limit.py
check python3 tests/test_display_snapshot.py
check python3 tests/test_stats_lifecycle.py
if check cc -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -Icore -Ihost -Idevices tests/test_optimization_primitives.c -o build/test_optimization_primitives; then
    check build/test_optimization_primitives
fi
# Keep this independent check self-contained when an earlier Link stage fails.
if [[ ! -s build/link/screen.metallib ]]; then
    mkdir -p build/link
    check xcrun -sdk macosx metal -c devices/pvg_screen.metal -o build/link/screen.air
    check xcrun -sdk macosx metallib build/link/screen.air -o build/link/screen.metallib
fi
if check xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -fsanitize=address,undefined -Idevices tests/test_metal_library_cache.m -framework Foundation -framework Metal -o build/test_metal_library_cache; then
    check build/test_metal_library_cache build/link/screen.metallib
fi
if check swiftc -parse-as-library -swift-version 5 ios/Henge/Controls/GamepadState.swift ios/Henge/Controls/GamepadTuning.swift ios/Henge/Controls/GamepadLayout.swift ios/Henge/Controls/PadInput.swift ios/Henge/Controls/TouchpadTuning.swift ios/Henge/Controls/ControllerPostureLayout.swift ios/Henge/Controls/GyroSteeringMath.swift tests/test_gamepad_tuning.swift -o build/test_gamepad_tuning; then
    check build/test_gamepad_tuning
fi
if check make build/test_display_router; then check build/test_display_router; fi
if check swiftc -parse-as-library -swift-version 5 ios/Henge/EngineTuning.swift tests/test_engine_tuning.swift -o build/test_engine_tuning; then
    check build/test_engine_tuning
fi
printf '\nExpanded diagnostic pass: %d failed checks\n' "$failures"
test "$failures" -eq 0

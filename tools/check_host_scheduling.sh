#!/bin/bash
# Native tests + iPhoneOS SDK type checking. Does not build an app or IPA.
set -euo pipefail
cd "$(dirname "$0")/.."
for test in input_ring native_touch_encoder env_flag cache_line_set; do
    cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -Ihost -Idevices "tests/test_$test.c" -o "/tmp/henge-$test"
    "/tmp/henge-$test"
done
cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -pthread -Ihost tests/test_native_touch_host.c host/native_touch.c -o /tmp/henge-native-touch-host
cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -pthread -DHV_NATIVE_TOUCH_TEST_CLOCK -Ihost tests/test_native_touch_watchdog.c host/native_touch.c -o /tmp/henge-touch-watchdog
/tmp/henge-touch-watchdog
/tmp/henge-native-touch-host
python3 tests/test_write_hint.py
python3 tests/test_restore_archive.py
python3 tests/test_clipboard_notify.py
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined tests/test_sharing_agent.m -framework AppKit -o /tmp/henge-test-sharing-agent
/tmp/henge-test-sharing-agent
swiftc -parse-as-library -swift-version 5 ios/Henge/ClipboardDelivery.swift tests/test_clipboard_delivery.swift -o /tmp/henge-test-clipboard-delivery
/tmp/henge-test-clipboard-delivery
python3 tests/test_display_pulses.py
python3 tests/test_pacing_scheduler.py
make build/test_pvg_task_memory
build/test_pvg_task_memory
mkdir -p build
cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -Idevices tests/test_gamepad.c -o build/test_gamepad
build/test_gamepad
mkdir -p build/scheduling-check
task_out="$PWD/build/scheduling-check"
exec > >(tee "$task_out/checks.log") 2>&1
trap 'task_rc=$?; echo "Scheduling check failed: exit=$task_rc line=$LINENO command=$BASH_COMMAND" >&2' ERR
set -x
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -pthread -Ihost \
    host/scheduling.c tests/test_scheduling.c -o "$task_out/test_scheduling"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -Ihost \
    tests/test_resource_policy.c -o "$task_out/test_resource_policy"
"$task_out/test_resource_policy"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -Ihost tests/test_system_memory.c -o "$task_out/test_system_memory"
"$task_out/test_system_memory"
"$task_out/test_scheduling"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O2 -Ihost -c host/scheduling.c -o "$task_out/scheduling.o"
swiftc -parse-as-library -swift-version 5 -import-objc-header host/scheduling.h \
    ios/Henge/HostScheduling.swift tests/test_host_scheduling.swift "$task_out/scheduling.o" -o "$task_out/test_host_bridge"
"$task_out/test_host_bridge"
swiftc -parse-as-library -swift-version 5 ios/Henge/SessionStatistics.swift tests/test_session_statistics.swift -o "$task_out/test_session_statistics"
"$task_out/test_session_statistics"
swiftc -parse-as-library -swift-version 5 -sanitize=address ios/Henge/NativeReportPump.swift tests/test_native_report_pump.swift -o "$task_out/test_native_report_pump"
"$task_out/test_native_report_pump"
swiftc -parse-as-library -swift-version 5 -sanitize=address ios/Henge/NativeReportPump.swift ios/Henge/SessionDiagnosticCapture.swift tests/test_diagnostic_capture.swift -o "$task_out/test_diagnostic_capture"
"$task_out/test_diagnostic_capture"
swiftc -parse-as-library -swift-version 5 -sanitize=address ios/Henge/SessionWakeups.swift tests/test_session_wakeups.swift -o "$task_out/test_session_wakeups"
"$task_out/test_session_wakeups"
swiftc -parse-as-library -swift-version 5 ios/Henge/EngineTuning.swift ios/Henge/GuestScreenSize.swift ios/Henge/M4Performance.swift tests/test_m4_defaults.swift -o "$task_out/test_m4_defaults"
"$task_out/test_m4_defaults"
swiftc -parse-as-library -swift-version 5 ios/Henge/GuestScreenSize.swift tests/test_guest_screen.swift -o "$task_out/test_guest_screen"
"$task_out/test_guest_screen"
swiftc -parse-as-library -swift-version 5 ios/Henge/PhysicalMouseButtons.swift tests/test_physical_mouse_buttons.swift -o "$task_out/test_physical_mouse_buttons"
"$task_out/test_physical_mouse_buttons"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -DHV_PROF_TEST -Icore -Ihost -Idevices \
    host/prof_ios.c host/scheduling.c tests/test_prof_ios.c -o "$task_out/test_prof_ios"
"$task_out/test_prof_ios"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -pthread -Ihost \
    tests/test_quiesce_wait.c -o "$task_out/test_quiesce_wait"
"$task_out/test_quiesce_wait"
xcrun --sdk macosx clang -fobjc-arc -std=c11 -Wall -Wextra -Werror -O2 -Idevices \
    tests/test_display_settings.m -framework Foundation -o "$task_out/test_display_settings"
"$task_out/test_display_settings"
python3 tests/test_pipeline_bundle_plan.py
cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined tests/test_gpu_record_support.c -o "$task_out/test_gpu_record_support"
"$task_out/test_gpu_record_support"
for task_test in test_metal4_ordering test_pipeline_bundle; do
    xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -O1 -g -fsanitize=address,undefined "tests/$task_test.m" -framework Foundation -framework Metal -o "$task_out/$task_test"
    "$task_out/$task_test"
done
cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined tests/test_gpu_binding_cache.c -o "$task_out/test_gpu_binding_cache"
"$task_out/test_gpu_binding_cache"
cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined tests/test_pvg_store_action.c -o "$task_out/test_pvg_store_action"
"$task_out/test_pvg_store_action"
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations tests/test_pvg_store_action.m -framework AppKit -framework Metal -o "$task_out/test_pvg_store_action_metal"
"$task_out/test_pvg_store_action_metal" "$task_out/store-action.json"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -isysroot "$SDK" -std=c11 -Wall -Wextra \
    -Icore -Ihost -Idevices -fsyntax-only host/scheduling.c host/vm.c host/prof_ios.c host/usb_host.c
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -isysroot "$SDK" -std=c11 -Wall -Wextra \
    -fobjc-arc -Icore -Ihost -Idevices -fsyntax-only devices/pvg_metal.m
# Typecheck the actual app, not a rewritten Settings/Session fixture. There is
# no linking, .app output, packaging, signing, new entitlement or simulator job.
python3 tools/typecheck_app.py --sdk iphoneos

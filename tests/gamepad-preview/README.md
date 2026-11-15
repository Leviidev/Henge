# Production controller preview harness

Uses the shipping GamepadSurface, PadInput, settings form and wireless shell.
Callbacks are deterministic fixtures; no guest VM, pairing secrets or native
input injection is used. XCTest records real Simulator screenshots and taps /
drags the production UIKit controls. The root toolbar identifies this as a
component preview, not the complete Henge application.

Primary phone viewport: unfolded Duo 951 x 669 points, taken from device logs.
iPad viewport: M4 13-inch 1376 x 1032 points. The fixtures may scale to fit the
available Simulator window; metadata records actual device type/runtime. A
large iPad Simulator is the canvas when no Duo Simulator type exists. Neither
case emulates A20/M4 CPU frequency, P/E placement, memory limits or thermals.

`python3 tools/preview_gamepad.py --profile duo-unfolded` (or `m4-13`) selects
an installed runtime, generates the harness project and runs XCTest. It creates
and deletes only its own Simulator. Screenshots and xcresult remain in
preview-artifacts. Run in GitHub Actions; no local Mac is required by the user.

Cloud native Duo probe failure: run 43158389557/job 130983663525 retains
SpringBoard/XCTest launch failure and screenshots. Use `--profile duo-unfolded
--duo-layout-canvas` for the full 951x669 UI test on a working M4 canvas. This is
explicitly a viewport test, not a native fold test. Omit that option, or dispatch
workflow with native_duo=true, to retry strict native Duo geometry validation.

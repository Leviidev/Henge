# Apple Vision Pro tools

Experiments toward a Vision Pro version of Henge. On a TXM device only an attached debugger can give an app
executable memory. On iPhone that debugger is StikDebug or the built-in StikJIT helper. Neither has been
built for visionOS yet, so these tools let a Mac be the debugger instead, over the same trap protocol as
`ios/Henge/Resources/henge-jit.js`.

- `jitprobe/`: a minimal native visionOS app that asks for a JIT region the way Henge does
  (`brk #0x69`, then `brk #0xf00d` with `x16 = 1`). It then writes code through a `vm_remap` alias, runs it
  in every page, detaches the debugger, and runs new code again. Its report is on screen and in
  `Documents/jitprobe.txt`.
- `jit_service.py` and `run_jit.sh`: attach LLDB from this Mac to an app on a paired device and service those
  traps. The debugger allocates the region with `_M<size>,rx` and writes into every page.
- `build_henge.sh` and `Henge.development.entitlements`: build Henge's iPad app signed by Xcode with your
  own (paid) team, to install directly. On a Vision Pro it runs as a "Designed for iPad" app.
- `PLAN.md`: where the work stands and the next steps.

## Result so far

On an Apple Vision Pro (RealityDevice14,1) running visionOS 27.0.1, paired over the local network, the probe
passes every step. Debugger-granted JIT works on visionOS, and the region keeps working after the debugger
detaches.

Henge's iPad build, unchanged, runs there in compatibility mode. It sees itself as an `iPad13,4` on iPadOS
27.0 with 15.7 GB of RAM, and gets both memory entitlements (a 6139 MB limit). With `run_jit.sh --launch`
and a 512 MB code cache, it claimed its region, passed its own self-test, and let the debugger go.
It then installed macOS Sequoia 15.6.1. The restore took about 7½ minutes once a Vision Pro address-space
fix was in (`GuestMemory.prepare`). What comes next is in [PLAN.md](PLAN.md).

Preparing the region is limited by Wi-Fi. One write a page manages about 42 pages a second (a 24 ms round
trip each). Bulk writes, the default, manage about 1.6 MB/s. A 512 MB code cache therefore takes about
6 minutes, and Henge's default on a Vision Pro (1.5 GB, from its memory limit) about 16. To go faster, many
writes would have to share one round trip, as StikJIT's 128-packet batches do, which LLDB can't send.
Keep the headset awake throughout: a 1.5 GB run lost its connection about 4 minutes in.

After attaching to an app launched suspended, LLDB's own register writes fail, so registers are set with
the raw `P` packets that `henge-jit.js` sends.

## Use

```bash
# The probe
cd tools/visionos/jitprobe && xcodegen generate
xcodebuild -project JITProbe.xcodeproj -scheme JITProbe -destination 'generic/platform=visionOS' \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=<team> JITPROBE_BUNDLE_ID=<your.bundle.id> build
xcrun devicectl device install app --device <udid> <path to JITProbe.app>
tools/visionos/run_jit.sh --launch <your.bundle.id>

# Henge (needs a built Husk at deps/Husk: see README.md, Building)
TEAM=<team> BUNDLE_ID=<your.bundle.id> tools/visionos/build_henge.sh
xcrun devicectl device install app --device <udid> build/visionos/Henge.app
tools/visionos/run_jit.sh --launch <your.bundle.id> -- -henge.perf.codeCacheMB '<integer>512</integer>'
```

`run_jit.sh` uses Xcode's LLDB through a standalone Python `SBDebugger` in synchronous mode. A loop inside the
`lldb` driver never sees the stops, because the driver's own event thread takes them. The first attach to a
new visionOS build is slow while LLDB reads the system libraries from the device. `JIT_BLESS=page` switches
to one write a page.

# Henge on Apple Vision Pro: plan

Where the Vision Pro work stands, and what comes next. The tools and the measurements are in
[README.md](README.md).

## Done

- **Debugger JIT works on visionOS.** On an Apple Vision Pro (visionOS 27.0.1), a debugger on a Mac can
  give an app executable memory over the same trap protocol as `ios/Henge/Resources/henge-jit.js`
  (`jitprobe/`, `run_jit.sh`). The region keeps working after the debugger detaches.
- **Henge's iPad build runs there unchanged**, as a "Designed for iPad" app. It sees itself as an
  `iPad13,4` on iPadOS 27.0, gets both memory entitlements (a 6139 MB limit), and gets JIT from the Mac
  (`build_henge.sh`, `run_jit.sh --launch`).
- **macOS installs.** Sequoia 15.6.1 downloads, installs and restores in about 7½ minutes. One Vision Pro
  fix was needed first: the shared region fills the low address space there, so a virtual Mac now gets
  the high address blocks Henge holds for Mac apps when its RAM fits nowhere else
  (`GuestMemory.prepare`, `henge_ios_release_high_room`).
- **Build fixes along the way:** the `tl/` sample Mac programs are built with the macOS SDK (Xcode 27.1's
  iOS SDK broke them), and Husk can live in `deps/Husk` inside the repository.

## 1. Validate the iPad version

Underway. With a Mac giving JIT at each launch:

- [x] Install macOS (Sequoia 15.6.1)
- [ ] First boot and Setup Assistant
- [ ] The desktop, Safari, and an app such as Discord
- [ ] **Input in compatibility mode.** This is the main unknown. A look and pinch reaches an iPad app as a
      single touch, so the trackpad surface's two-finger scrolling and the Mac's gestures may not
      happen. Check a Bluetooth keyboard and Magic Trackpad too.
- [ ] Performance, heat and battery over a longer session
- [ ] What compatibility mode lacks: no volume buttons (`VolumeClicks.swift` has nothing to read), no
      haptics, no external display. Note the Mac's screen size and how the window resizes.

Region preparation over Wi-Fi is slow (about 1.6 MB/s, so 6 minutes for a 512 MB code cache and 16 for
Henge's 1.5 GB default there), and the headset must stay awake for it. That's fine for testing. Step 2
removes the wait. If it doesn't work out, the Mac side could batch its writes the way StikJIT does (128
packets per round trip), which needs its own debugserver connection, since LLDB can't send batches.

## 2. JIT on the headset, without a Mac (iPad version)

No new build is needed. The app is an iOS binary in compatibility mode, so the iOS StikJIT, the pairing
library and `HengeJITHelper.appex` already in it work as they are. The helper extension installs on
visionOS.

- [ ] Is **LocalDevVPN** in the App Store on the Vision Pro? iPad apps are listed there unless their
      developer opted out. If it isn't, write a small loopback VPN that does the same thing (traffic for
      `10.7.0.1` returned to the device, so its developer services take it for a computer on the network).
- [ ] **Pairing:** Henge's on-device pairing (`JITPairing.swift`, advertising
      `_remotepairing-pairable-host._tcp`), or a pairing file made on the Mac and imported.
- [ ] **Developer disk image:** StikJIT downloads iOS images (`DeveloperDiskImageService.swift`). Check
      whether the headset needs the xrOS one, which Xcode keeps in
      `/Library/Developer/DeveloperDiskImages/xrOS_DDI`.
- [ ] Does the helper extension (`com.apple.ar.viewer`) launch on visionOS? If not, a companion app could
      run StikJIT instead.
- [ ] **Turn On JIT** end to end. On the device the page writes have almost no round-trip time, so the
      wait should all but go away.

If this works, a Vision Pro user needs no Mac after the first pairing.

## 3. Input

Useful in compatibility mode already, so probably before step 4.

- [ ] An **absolute pointer** for the guest: a USB HID tablet on the xHCI bus (`devices/xhci.c`), the idea
      behind QEMU's `usb-tablet`, which macOS supports out of the box. Then a look and pinch clicks where
      you look, and pinch and drag drags. The guest has only a relative mouse (`devices/virtio_input.c`)
      and the Magic Trackpad 2 today. This is an engine change, and the iPad's touch mode could use it too.
- [ ] Scrolling, and the Mac's gestures (Mission Control, Spaces) from visionOS's own gestures, or from
      controls beside the window.
- [ ] A keyboard row (Esc, Tab, Control, Option, Command) that works without the iPhone's
      `inputAccessoryView`.

## 4. The native visionOS version

What it adds is the Vision Pro experience: windows, ornaments and gaze-driven input. Compatibility mode
already runs the engine, graphics and installer unchanged, so this can wait until the iPad version feels
limiting.

**C libraries (mostly mechanical):**
- [ ] The engine: a visionOS variant of the `Makefile`'s `IOS_CC` and `IOS_SDK` (`xcrun --sdk xros`,
      `-target arm64-apple-xros`), and of the `libtool` call for `libhengetl.a`
- [ ] The restore stack: `tools/build_ios_restore.sh` with the `xros` SDK (libplist, libimobiledevice,
      libusbmuxd, libirecovery, idevicerestore, libtatsu, libzip, mbedtls)
- [ ] Husk's libffi, glib (with pcre2 and intl) and libslirp: meson cross files for `xros` in
      `scripts/build_ios.sh`

**Rust (the risky part, and only for JIT on the headset):**
- [ ] StikJIT's `idevice` (`libidevice_ffi.a` ships iOS-only) and Husk's `husk_rppairing` for
      `aarch64-apple-visionos`, a tier 3 Rust target (a nightly compiler and `-Zbuild-std`)
- [ ] StikJIT's Swift built for `xros`. The frameworks it uses (JavaScriptCore, Network, Security,
      IOKit) are in the visionOS SDK. Its embed script's `CFBundleSupportedPlatforms` says `iPhoneOS`.
- [ ] Until then, a native build can take JIT from a Mac (`run_jit.sh`) the way the iPad build does

**The app:**
- [ ] A visionOS target in `ios/project.yml` (this xcodegen needs `SDKROOT: xros` and
      `TARGETED_DEVICE_FAMILY: 7` on an iOS target, as `jitprobe/project.yml` does)
- [ ] Sizes from the window scene instead of `UIScreen.main` (`Hardware.swift`, `MacScreen.swift`,
      `Input.swift`, `BootDisplay.swift`). Haptics behind a check.
- [ ] No `VolumeClicks.swift` and no external display on visionOS (`DisplayRouter`,
      `ExternalDisplaySceneDelegate`, `LegacyExternalDisplay`, `ExternalScreenPlan`)
- [ ] A fixed Mac resolution (2560×1440, say) in a window that keeps its aspect as it's resized, instead of
      the iPad's screen-shaped Mac
- [ ] The keyboard row as an ornament, and the `#available(iOS 26, *)` checks that decide JIT behaviour
      (`JITBootstrap.swift`, `JITBuiltIn.swift`, `JITPairing.swift`) checked on visionOS
- [ ] Later: a large immersive screen through CompositorServices

## Not pursued

**Running without JIT.** Henge's translator copies most guest instructions unchanged and needs
executable memory. An interpreter would be a new CPU core, roughly 20–50× slower: minutes to reach the
lock screen. Debugger JIT works, so this isn't needed.

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
- **JIT on the headset, without a Mac.** Henge's built-in StikJIT helper runs there (step 2), with Henge's own
  VPN, pairing on the headset and the helper on another extension point.
- **Build fixes along the way:** the `tl/` sample Mac programs are built with the macOS SDK (Xcode 27.1's
  iOS SDK broke them), and Husk can live in `deps/Husk` inside the repository.

## 1. Validate the iPad version

Underway. With a Mac giving JIT at each launch:

- [x] Install macOS (Sequoia 15.6.1)
- [x] First boot, to Setup Assistant (8 GB of guest RAM, held outside Henge's footprint)
- [ ] Through Setup Assistant
- [ ] The desktop, Safari, and an app such as Discord
- [x] **Input in compatibility mode.** A look and pinch reaches an iPad app as one touch a hand, so the
      trackpad surface's gestures, and the four-finger tap that shows hidden controls, can't happen.
      Pointing (step 3) and an eye button for the hidden controls make it usable, though still awkward.
- [ ] A Bluetooth keyboard and Magic Trackpad
- [ ] Performance, heat and battery over a longer session
- [ ] What compatibility mode lacks: no volume buttons (`VolumeClicks.swift` has nothing to read), no
      haptics, no external display. Note the Mac's screen size and how the window resizes.

Region preparation from the Mac over Wi-Fi is slow (about 1.6 MB/s, so 6 minutes for a 512 MB code cache and
16 for Henge's 1.5 GB default there), and the headset must stay awake for it. Step 2's JIT on the headset
removes the wait.

## 2. JIT on the headset, without a Mac (iPad version)

Works. Henge's built-in StikJIT helper attached on the headset and macOS booted, far faster than with the Mac's
LLDB, since the page writes no longer cross Wi-Fi. Details in [README.md](README.md).

- [x] **LocalDevVPN** isn't in the headset's App Store, but its source builds unchanged with a paid team and
      connects in compatibility mode.
- [x] **Pairing:** visionOS pairs the other way round from iOS 27 (the headset advertises
      `_remotepairing-manual-pairing._tcp` and a computer connects), so Henge's on-device pairing has nothing to
      pair with. `pair/pair.sh` makes the file on a Mac.
- [x] **The helper extension:** visionOS has no `com.apple.ar.viewer` point, so the helper is registered under
      `com.apple.share-services` in the Vision Pro build (`HENGE_JIT_HELPER_EXTENSION_POINT`).
- [x] **Turn On JIT** end to end, with the developer disk image already mounted by the Mac.
- [ ] **Developer disk image after a restart.** StikJIT downloads iOS images (`DeveloperDiskImageService.swift`).
      Check whether it mounts one after the headset restarts with no Mac, or whether it needs the xrOS one that
      Xcode keeps in `/Library/Developer/DeveloperDiskImages/xrOS_DDI`.
- [x] **Pairing on the headset** (JIT setup › Pair on this Apple Vision Pro, `JITVisionPairing.swift`). Henge
      connects its VPN, finds the headset's own `_remotepairing-manual-pairing._tcp` once Settings › General ›
      Remote Devices is open beside it, connects at 10.7.0.1 and sends the code the user types. The client is
      `ios/rppairing-client` (`libhenge_rpclient.a`, idevice's `RemotePairingClient`), linked beside Husk's
      pairing library only in `project.tunnel.yml` builds. A Vision Pro now needs a Mac only to install Henge.
- [x] **A loopback VPN inside Henge**, so LocalDevVPN isn't needed: `ios/HengeTunnel`, a packet-tunnel extension
      based on LocalDevVPN's (credited in `third_party/LocalDevVPN`). Network extensions need a paid team, so it is
      added only by `xcodegen generate --spec project.tunnel.yml`, which `build_henge.sh` uses. Henge connects it
      before the helper needs it and disconnects it once JIT is on (`JITTunnel.swift`).
- [x] **The pairing service's port on a busy network.** Henge and its helper took the first
      `_remotepairing._tcp` that answered, which was once a nearby iPhone's, and timed out. Both now accept only a
      service on this device (`OwnAddresses.swift`). This affects iPhones too.
- [ ] Try `com.apple.share-services` on an iPhone. If the helper works there too, one point serves both, and an
      upstream IPA works on the headset as it is.
- [ ] Henge's own port lookup (`RemotePairingPortDiscovery`) finds nothing on the headset; the helper's
      (`RSDPortResolver`) does. Find out why.

## 3. Input

Useful in compatibility mode already, so probably before step 4.

- [x] An **absolute pointer** for the guest: a USB HID tablet on port 3 of the xHCI bus (`devices/xhci.c`,
      `tests/test_xhci.c`), as QEMU's `usb-tablet` is. macOS drives it with its own HID driver.
- [x] **Pointing** (Settings › Touch, on by default on the headset, `Trackpad.swift`). A look and a pinch
      clicks where you look, pinch and move drags, both hands moving together scroll, and a brief pinch
      with both right-clicks.
- [ ] Make it comfortable. It works but is still awkward: tune the press delay, the drag threshold and the
      scroll speed, and try visionOS's hover feedback in the native version, where the app can tell
      where you are looking before you pinch.
- [ ] The Mac's gestures (Mission Control, Spaces), which pointing gives up, from controls beside the
      window or visionOS's own gestures.
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

## 5. Mac windows as visionOS windows

The goal: each macOS window floats in its own visionOS window, so Mac apps sit in the room almost like
native ones. This is what Parallels' Coherence, VMware's Unity and VirtualBox's Seamless mode do: a helper in
the guest says where each window is, and the host shows each one by itself. It needs the native version
(step 4), where each window can be its own SwiftUI `WindowGroup` scene with its own size and ornaments.

**The virtual Mac:**
- [ ] **The window list.** `tools/henge-agent.m` already runs in macOS and long-polls `host/share.c` at
      `10.0.2.4` for the clipboard. A `/.henge/windows` endpoint would carry each window's ID, owner app,
      position, size and stacking order (`CGWindowListCopyWindowInfo`; titles need the Screen Recording
      permission).
- [ ] **One window, cut out.** Henge already renders the Mac's whole screen with Metal (`devices/pvg_metal.m`),
      so showing a window means copying its rectangle into its own visionOS window: a GPU copy each frame,
      and only window positions cross the network.
- [ ] **No overlaps.** A copied rectangle shows whatever is on top there, so the agent manages the windows:
      the Mac gets a large screen (5K, say), and the agent keeps its windows side by side, each the size of
      its visionOS window, through the Accessibility API (`AXUIElement`, a one-time permission). Resizing a
      visionOS window resizes its Mac window.
- [ ] **Input and focus.** A pinch in a visionOS window becomes a tablet position inside that window's
      rectangle (step 3's absolute pointer is what makes this simple). Focusing a visionOS window has the
      agent raise and activate its Mac window, so the keyboard goes there.
- [ ] **Menus.** A Mac app's menus are in the global menu bar. Read them through Accessibility and show them
      as an ornament on the app's windows, or keep one floating menu bar window.
- [ ] **Pop-ups.** Context menus, sheets, pop-overs and tooltips are windows of their own. Recognise them by
      level and owner, and attach them to their parent's visionOS window.
- [ ] **System UI.** Hide the Dock automatically, and keep a "whole desktop" window for notifications,
      Spotlight and anything left over.

Order: the window list and endpoint first, tried on an iPhone with the windows drawn as labelled
rectangles; then one visionOS window for one Mac window, with input; then the window manager and resizing;
then menus and pop-ups.

A deeper alternative: Henge's GPU replay sees WindowServer composite each window's own surface into the
screen, so in principle each window could be taken from that stream, overlaps and all. It would mean
reverse-engineering WindowServer's private compositing, so it would be fragile.

**Mac apps run directly (`tl/`):** more direct still. The translation layer's own AppKit already hands over
each window as a layer (`henge_tl_app_window_count`, `henge_tl_app_window_layer`, `henge_tl_app_window_frame`,
laid out by `MacScreen.swift`). Each layer could go into its own visionOS window, with no capture, tiling or
agent. The limit is which apps `tl/` runs.

## 6. Later: Xcode in the virtual Mac, deploying to the headset

The goal: Xcode running inside Henge's Mac installs and debugs apps on the Vision Pro it runs on. The virtual Mac
pairs as a computer of its own (Remote Devices, a code, as any Mac does), not with Henge's pairing: Xcode keeps
its pairings in macOS's private store. Henge carries its traffic to the headset the way the JIT helper's goes.

- [ ] **A route to the headset.** The guest's connections are made by Henge's network stack (Husk's libslirp),
      so a guest address can be mapped to 10.7.0.1 through Henge's VPN, where the headset takes it for a computer
      on the network.
- [ ] **Discovery.** Xcode finds network devices by Bonjour, which doesn't cross the guest's NAT. Henge answers
      the guest's mDNS queries itself: the headset's `_remotepairing._tcp`, and
      `_remotepairing-manual-pairing._tcp` while Remote Devices is open, pointing at the mapped address. Henge
      already finds both (`RSDPortResolver`).
- [ ] **CoreDevice's tunnel.** Pairing, then CoreDevice's encrypted tunnel, which carries installing, the disk
      image and debugging. Henge only forwards it (TCP, and UDP if CoreDevice uses it there).
- [ ] Unknowns: whether CoreDevice checks the advertised addresses against where it connects (then Henge rewrites
      them, IPv6 too); whether Xcode is usable in the virtual Mac (disk, RAM, speed; device builds don't need the
      Simulator); whether visionOS suspends Henge while the app being debugged is in front.

First test: the route and discovery, then whether the guest's Xcode lists the headset under Devices.

## Not pursued

**Running without JIT.** Henge's translator copies most guest instructions unchanged and needs
executable memory. An interpreter would be a new CPU core, roughly 20–50× slower: minutes to reach the
lock screen. Debugger JIT works, so this isn't needed.

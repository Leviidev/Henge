import SwiftUI
import UIKit
import GameController
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

/// What this device is, for what the app says and suggests.
enum Device {
    static let supportsDesktopMetalFX: Bool = {
#if canImport(MetalFX)
        guard #available(iOS 26.0, *),
              hv_host_is_m4_16gb() != 0 || hv_host_is_duo() != 0,
              let gpu = MTLCreateSystemDefaultDevice(), gpu.supportsFamily(.metal4) else { return false }
        return MTLFXSpatialScalerDescriptor.supportsMetal4FX(gpu)
#else
        // Apple's Simulator SDK omits MetalFX. Native Retina remains usable;
        // this does not change the supported physical-device upscaler path.
        return false
#endif
    }()
    static func fitting(for mac: VirtualMac) -> (width: Int, height: Int) {
        let size = mac.displaySize(in: displayViewport)
        return (size.width, size.height)
    }
    static var largeScreen: Bool { !isPad && min(displayViewport.width, displayViewport.height) >= 600 }
    static let sideStrip: CGFloat = 84
    static let sideStripCentre: CGFloat = 47.5
    static let sideStripTop: CGFloat = 114
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// The screen Henge is on, in points. An iPhone's window is its whole screen, so the window says which one:
    /// an iPhone Duo has two, and UIScreen.main can be the one Henge is not on (a Mac fitted on the inner screen
    /// got the outer screen's shape, 1920×1320, and thin bars above and below).
    static var screenSize: CGSize {
        if !isPad {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.session.role == .windowApplication }
            if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
                return scene.coordinateSpace.bounds.size
            }
        }
        return UIScreen.main.bounds.size
    }

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads and
    /// squarer phones (iPhone Duo, about 1.46:1) would get bars above and below at 16:9. Phones wider
    /// than 16:9 come out at 1920×1080, as before.
    static var fittingScreen: (width: Int, height: Int) {
        let size = GuestScreenSize.fitting(in: displayViewport)
        return (size.width, size.height)
    }

    static var displayViewport: CGSize {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication && $0.activationState != .background }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow)?.bounds.size ?? UIScreen.main.bounds.size
    }

    /// Desktop preserves the iPad panel's composition across window changes.
    /// Fit remains window-aware, and Duo uses the current inner/outer viewport.
    static func desktopRetina(in viewport: CGSize) -> GuestScreenSize {
        GuestScreenSize.desktopRetina(in: viewport, panel: isPad ? screenSize : nil)
    }

    /// Preserve the iPad's shape while reducing the virtual GPU's pixel work.
    static var performanceScreen: (width: Int, height: Int) {
        let fit = fittingScreen
        return (1600, Int((Double(fit.height) * 5 / 6 / 8).rounded()) * 8)
    }

    /// The panel itself, on its side: every physical pixel, and its real size in mm so that macOS
    /// sees a Retina density and draws at 2x (looks like half the pixels, sharp as the iPad's own UI).
    /// Every iPad with an M chip is 264 ppi.
    static var retinaScreen: (width: Int, height: Int) {
        let n = UIScreen.main.nativeBounds.size
        return (Int(max(n.width, n.height)) / 8 * 8, Int(min(n.width, n.height)) / 8 * 8)
    }
    static var retinaMM: (width: Int, height: Int) {
        let s = retinaScreen
        return (Int((Double(s.width) / 264 * 25.4).rounded()), Int((Double(s.height) / 264 * 25.4).rounded()))
    }

    /// How much memory to suggest for a new Mac: what leaves this device room for iOS.
    static var suggestedRAMGB: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        // m4 fork: an 8 GB iPad (7.4 GB usable) thrashes and kills the Mac at 6 GB: 16 GB devices only.
        // A 6 GB device (5.7 GB usable) could not build a 4 GB Mac, and installed a 3 GB one (#70); 4 GB devices, 2.
        return mb >= 14_000 ? 8 : mb >= 10_000 ? 6 : mb >= 7_000 ? 4 : mb >= 5_000 ? 3 : 2
    }

    /// The choices for a Mac's memory, in GB.
    static let memoryChoices = 1...16

    /// What a choice risks on this device, if anything. An install always gets at least 2 GB (Installer.install).
    static func memoryNote(_ gb: Int) -> String? {
        if gb < 4 { return "macOS has little room under 4 GB, so it can be very slow." }
        if gb > suggestedRAMGB { return "More than \(suggestedRAMGB) GB is a lot for this \(name): iOS may close Henge when macOS gets busy." }
        return nil
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS won't run on this \(name). Henge needs an A14 or M1 chip or newer."
}

/// A keyboard attached to the device. iOS reports each key going down and coming up by its HID usage,
/// which is what the Mac's USB keyboard sends, so every key and modifier goes straight across.
enum HardwareKeys {
    private static var held: Set<UInt8> = []
    private static var lastKey: CFTimeInterval = 0

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        held.contains { $0 < 0xe0 } || CACurrentMediaTime() - lastKey < 0.1
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        // A chord can arrive in one unordered Set. Press modifiers first and
        // release them last so the guest sees the intended shortcut.
        let ordered = presses.sorted { a, b in
            let aCode = a.key?.keyCode.rawValue ?? 0
            let bCode = b.key?.keyCode.rawValue ?? 0
            let aModifier = (0xe0...0xe7).contains(aCode)
            let bModifier = (0xe0...0xe7).contains(bCode)
            if aModifier != bModifier { return down ? aModifier : !aModifier }
            return aCode < bCode
        }
        for press in ordered {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            let usage = UInt8(raw)
            // Guest USB owns repeat. Ignore stale ups after focus cleanup and
            // keep hardware modifiers independent of on-screen shortcuts.
            if down { guard held.insert(usage).inserted else { continue } }
            else { guard held.remove(usage) != nil else { continue } }
            henge_vm_input_key(4, usage, down ? 1 : 0)
            if usage < 0xe0 { lastKey = CACurrentMediaTime() }
            if down {
                held.insert(usage)
            } else {
                held.remove(usage)
                if usage < 0xe0 { StickyKeys.shared.releaseAll() } // one key after a tap on ⌃, ⌥ or ⌘
            }
        }
        return rest
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for usage in held { henge_vm_input_key(4, usage, 0) }
        held.removeAll()
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private(set) static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { controller in
                    MainActor.assumeIsolated {
                        guard wanted, let scene = controller.viewIfLoaded?.window?.windowScene else { return false }
                        return scene.session.role == .windowApplication && scene.activationState == .foregroundActive
                    }
                }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    /// iPadOS only locks the pointer to an app that fills the screen: in a window (Stage Manager, or iPadOS 26's windows)
    /// the request is ignored and the system pointer stays separate from the Mac's (#18). An iPhone never locks it, and
    /// its apps are always full screen, so the hint is for iPad only.
    static var refused: Bool {
        guard Device.isPad, wanted, GCMouse.current != nil else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        return !scenes.isEmpty && !scenes.contains { $0.pointerLockState?.isLocked == true }
    }
}

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse.
final class HardwareMouse {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"
    static let scrollSpeedKey = "henge.mouse.scrollSpeed"

    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttons = PhysicalMouseButtons(swapsRightAndMiddle: false)
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollsLogged = 0 // the first few, to see what a device's raw values look like
    private var scrollState = HardwareScroll()
    private var scrollTimer: Timer?
    private var scrollScale = HardwareScroll.defaultSpeed
    private var acceptsInput = false
    private var scrollCallbacks: UInt64 = 0, scrollFrames: UInt64 = 0
    private var largestScroll: Int32 = 0
    private var buttonEdges: UInt64 = 0, buttonResets: UInt64 = 0, ignoredButtonEdges: UInt64 = 0

    func setAcceptsInput(_ enabled: Bool) {
        guard acceptsInput != enabled else { return }
        acceptsInput = enabled
        if !enabled {
            LocalPointerInput.cancel()
            for source in [UInt32(5), 6, 7] { henge_vm_input_release(source) }
            VolumeClicks.shared.releaseButtons()
            HardwareKeys.releaseAll()
            releaseButtons()
            scrollTimer?.invalidate(); scrollTimer = nil
            scrollState = HardwareScroll()
            restX = 0; restY = 0
        }
    }

    var scrollDiagnostics: String {
        "wheel: callbacks=\(scrollCallbacks) frames=\(scrollFrames) max_axis_units=\(largestScroll) cap=4 scale=\(scrollScale) accepting=\(acceptsInput) button_edges=\(buttonEdges) button_resets=\(buttonResets) ignored_button_edges=\(ignoredButtonEdges) held=\(buttons.held.count)"
    }

    func start() {
        // Session startup and restored-view attachment can both call start.
        // Reuse observers and handlers instead of registering a second pipeline.
        guard observers.isEmpty else { setAcceptsInput(true); return }
        acceptsInput = true
        scrollCallbacks = 0; scrollFrames = 0; largestScroll = 0
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        reverse = defaults.bool(forKey: Self.reverseKey)
        releaseButtons()
        buttons = PhysicalMouseButtons(swapsRightAndMiddle: defaults.bool(forKey: PhysicalMouseButtons.swapKey))
        HengeLog.log("input", "physical right/middle swap=\(buttons.swapsRightAndMiddle); touch and scrolling unchanged")
        scrollState = HardwareScroll()
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollScale = HardwareScroll.speed(defaults.object(forKey: Self.scrollSpeedKey) as? Double ?? HardwareScroll.defaultSpeed)
        HengeLog.log("input", "hardware scroll: raw movement batched before conversion, event-driven 60 Hz cap, max 4 units/event, speed=\(HardwareScroll.speed(scrollScale))")
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let d = UserDefaults.standard
            self.scrollScale = HardwareScroll.speed(d.object(forKey: Self.scrollSpeedKey) as? Double ?? HardwareScroll.defaultSpeed)
            self.reverse = d.bool(forKey: Self.reverseKey)
        })
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            for button in self.buttons.release(device: ObjectIdentifier(mouse)) {
                self.buttonResets &+= 1
                henge_vm_input_button(4, button, 0)
            }
            self.scrollState = HardwareScroll()
            self.scrollTimer?.invalidate()
            self.scrollTimer = nil
            self.mice.removeAll { $0 === mouse }
            if self.mice.isEmpty { PointerLock.set(false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            // The scene comes in the user info: the notification's object isn't it.
            let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene
            guard scene?.session.role == .windowApplication else { return }
            let locked = scene?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
            if !locked && PointerLock.wanted {
                self?.releaseForHandoff()
                LocalPointerInput.cancel()
                HardwareKeys.releaseAll()
                StickyKeys.shared.releaseAll()
            }
        })
        PointerLock.set(!mice.isEmpty)
    }

    func stop() {
        setAcceptsInput(false)
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollState = HardwareScroll()
        PointerLock.set(false)
        releaseButtons()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.valueChangedHandler = nil
            input.scroll.xAxis.valueChangedHandler = nil
            input.scroll.yAxis.valueChangedHandler = nil
        }
        mice.removeAll()
    }

    func releaseButtons() {
        if !buttons.held.isEmpty { buttonResets &+= 1 }
        _ = buttons.releaseAll()
        // Clear the whole source even when UIKit lost its matching release.
        for button in Int32(0)...2 { henge_vm_input_button(4, button, 0) }
    }

    func releaseForHandoff() {
        releaseButtons()
        scrollTimer?.invalidate(); scrollTimer = nil
        scrollState = HardwareScroll(); restX = 0; restY = 0
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        mouse.handlerQueue = .main
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        input.mouseMovedHandler = { [weak self, weak mouse] _, dx, dy in
            guard let self, let mouse, self.mice.contains(where: { $0 === mouse }) else { return }
            self.moved(dx, dy)
        }
        input.leftButton.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse, self.mice.contains(where: { $0 === mouse }) else { return }
            self.button(0, pressed, device: ObjectIdentifier(mouse))
        }
        input.rightButton?.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse, self.mice.contains(where: { $0 === mouse }) else { return }
            self.button(1, pressed, device: ObjectIdentifier(mouse))
        }
        input.middleButton?.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse, self.mice.contains(where: { $0 === mouse }) else { return }
            self.button(2, pressed, device: ObjectIdentifier(mouse))
        }
        input.scroll.valueChangedHandler = nil
        input.scroll.xAxis.valueChangedHandler = { [weak self, weak mouse] _, delta in
            guard let self, let mouse, self.mice.contains(where: { $0 === mouse }) else { return }
            self.scrolled(delta, 0)
        }
        input.scroll.yAxis.valueChangedHandler = { [weak self, weak mouse] _, delta in
            guard let self, let mouse, self.mice.contains(where: { $0 === mouse }) else { return }
            self.scrolled(0, delta)
        }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    private func moved(_ dx: Float, _ dy: Float) {
        guard acceptsInput, dx.isFinite, dy.isFinite, speed.isFinite else { return }
        guard dx != 0 || dy != 0 else { return }
        guard LocalPointerInput.hardware(.motion) else { return }
        restX += min(max(dx * speed, -32767), 32767)
        restY -= min(max(dy * speed, -32767), 32767)
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        henge_vm_mouse_move(Int32(x), Int32(y))
    }

    private func button(_ physicalButton: Int32, _ pressed: Bool, device: ObjectIdentifier) {
        guard acceptsInput else { ignoredButtonEdges &+= 1; return }
        if pressed { guard LocalPointerInput.hardware(.button) else { return } }
        guard let button = buttons.event(physicalButton, pressed: pressed, device: device) else { return }
        buttonEdges &+= 1
        henge_vm_input_button(4, button, pressed ? 1 : 0)
        if !pressed { StickyKeys.shared.releaseAll() }
    }

    /// GameController puts vertical motion on the first axis and horizontal on the second.
    /// macOS accelerates wheel units roughly quadratically, so use a tunable square root
    /// and cap each event to keep a small pad gesture from jumping across a page.
    private func scrolled(_ first: Float, _ second: Float) {
        guard acceptsInput, first.isFinite, second.isFinite, first != 0 || second != 0 else { return }
        guard LocalPointerInput.hardware(.scroll) else { return }
        scrollCallbacks &+= 1
        scrollState.push(first: Double(first), second: Double(second), scale: scrollScale, reversed: reverse)
        scheduleScrollIfNeeded()
    }

    private func scheduleScrollIfNeeded() {
        guard scrollTimer == nil, scrollState.needsDelivery else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.scrollTimer = nil
            self.flushScroll()
            self.scheduleScrollIfNeeded()
        }
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flushScroll() {
        let event = scrollState.take()
        guard event.x != 0 || event.y != 0 else { return }
        scrollFrames &+= 1
        largestScroll = max(largestScroll, max(abs(event.x), abs(event.y)))
        if scrollsLogged < 24 {
            scrollsLogged += 1
            HengeLog.log("input", "hardware scroll coalesced: units \(event.x), \(event.y) (60 Hz cap)")
        }
        henge_vm_mouse_scroll(event.x, event.y)
    }
}


/// Main-thread handoff between actual local input devices. It never restarts the
/// USB helper, pauses the VM, or interferes with keyboard/remote ownership.
enum LocalPointerInput {
    static let changed = Notification.Name("henge.localPointerChanged")
    static var ownership = LocalPointerOwnership()
    static var surfaceID: ObjectIdentifier?
    static var cancelSurface: (() -> Void)?
    static func owns(_ view: UIView) -> Bool { surfaceID == ObjectIdentifier(view) }
    static func install(_ view: UIView, cancel: @escaping () -> Void) {
        if surfaceID != ObjectIdentifier(view) { cancelSurface?(); ownership.reset() }
        surfaceID = ObjectIdentifier(view); cancelSurface = cancel
    }
    static func uninstall(_ view: UIView) {
        guard surfaceID == ObjectIdentifier(view) else { return }
        cancelSurface = nil; surfaceID = nil; ownership.reset()
    }
    static func direct() {
        guard ownership.claim(.direct) else { return }
        HardwareMouse.shared.releaseForHandoff()
        PointerLock.set(false)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func setDirectContacts(_ count: Int) { ownership.setDirectContacts(count) }
    @discardableResult static func hardware(_ intent: LocalPointerOwnership.HardwareIntent = .motion) -> Bool {
        guard ownership.permitsHardware(intent) else { return false }
        guard ownership.claim(.hardware) else { return true }
        cancelSurface?()
        PointerLock.set(true)
        NotificationCenter.default.post(name: changed, object: nil)
        return true
    }
    static func cancel() {
        ownership.reset(); cancelSurface?()
    }
}

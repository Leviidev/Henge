import SwiftUI
import UIKit
import GameController
import Metal

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads and
    /// squarer phones (iPhone Duo, about 1.46:1) would get bars above and below at 16:9. Phones wider
    /// than 16:9 come out at 1920×1080, as before.
    static var fittingScreen: (width: Int, height: Int) {
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
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

    /// The chip's name ("Apple A20 Pro"). iOS has no name for the CPU (machdep.cpu.brand_string is empty on an
    /// iPhone), but Metal names the GPU after the chip: "Apple A20 Pro GPU".
    static var chipName: String? {
        guard var name = MTLCreateSystemDefaultDevice()?.name.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if name.hasSuffix(" GPU") { name.removeLast(4) }
        return name.hasPrefix("Apple ") && name.count > 6 ? name : nil
    }

    /// How much memory to suggest for a new Mac: what leaves this device room for iOS.
    static var suggestedRAMGB: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        // m4 fork: an 8 GB iPad (7.4 GB usable) thrashes and kills the Mac at 6 GB: 16 GB devices only.
        // A 6 GB device (5.7 GB usable) could not build a 4 GB Mac, and installed a 3 GB one (#70); 4 GB devices, 2.
        return mb >= 14_000 ? 8 : mb >= 10_000 ? 6 : mb >= 7_000 ? 4 : mb >= 5_000 ? 3 : 2
    }

    /// The most CPUs a Mac can be given here: one per core this device has, up to the engine's HV_MAX_CPUS (8,
    /// core/machine.h). More virtual CPUs than cores would only take turns on them.
    static var maxCPUs: Int { min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8) }

    /// This device's cores by kind ("2 performance and 4 efficiency cores"), from the hw.perflevel sysctls; nil where
    /// the system doesn't say.
    static var coreDescription: String? {
        func count(_ name: String) -> Int? {
            var n: Int32 = 0, size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &n, &size, nil, 0) == 0 ? Int(n) : nil
        }
        guard let fast = count("hw.perflevel0.physicalcpu") else { return nil }
        guard let slow = count("hw.perflevel1.physicalcpu"), slow > 0 else { return "\(fast) cores" }
        return "\(fast) performance and \(slow) efficiency cores"
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

    /// What this device is called and the chip it has, for a Mac that reports its host
    /// (MacSettingsView → About This Mac). The table and the icon-snapping live in
    /// DeviceIdentity.swift (pure Foundation, so the Mac tests can compile it).
    static var modelIdentifier: String { HengeLog.deviceModel }
    static var marketingName: String { DeviceIdentity.name(modelIdentifier) }
    static var chipName: String? { DeviceIdentity.chip(modelIdentifier) }

    /// The model identifier to report for a matching icon: the real one when the guest
    /// macOS knows it, else the newest equivalent it recognises (see DeviceIdentity).
    static func snappedModelIdentifier(forOS osName: String?) -> String {
        DeviceIdentity.snappedIdentifier(modelIdentifier, forOS: osName)
    }
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
            henge_vm_key_hid(usage, down ? 1 : 0)
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
        for usage in held { henge_vm_key_hid(usage, 0) }
        held.removeAll()
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        // iPad only, as in Madeira: on iPhone the pointer belongs to AssistiveTouch and lock is not for it.
        wanted = on && Device.isPad
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { vc in wanted && fillsScreen(vc.viewIfLoaded?.window) }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
            if window.isKeyWindow {
                let ask = on && fillsScreen(window)
                if ask != lastAsked {
                    lastAsked = ask
                    HengeLog.log("input", "pointer lock \(ask ? "asked for" : "not asked for"): window \(Int(window.bounds.width))x\(Int(window.bounds.height)) of \(Int(window.screen.bounds.width))x\(Int(window.screen.bounds.height))")
                }
            }
        }
    }
    private static var lastAsked: Bool?

    /// Only an app that fills the screen asks for the lock. In a Stage Manager window iPadOS can grant it and still
    /// move its hidden pointer to the screen's edges, bringing out the stage strip and the dock at every move; there
    /// the Mac's pointer follows the iPad's instead (AbsolutePointer).
    static func fillsScreen(_ window: UIWindow?) -> Bool {
        guard let window else { return false }
        let mine = window.bounds.size, screen = window.screen.bounds.size
        return abs(mine.width - screen.width) < 1 && abs(mine.height - screen.height) < 1
    }

    /// Whether iPadOS has the pointer locked to the Mac right now.
    static var isLocked: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .contains { $0.activationState == .foregroundActive && $0.pointerLockState?.isLocked == true }
    }

    /// iPadOS only locks the pointer to an app that fills the screen: in a window (Stage Manager, or iPadOS 26's windows)
    /// the request is ignored and the system pointer stays separate from the Mac's (#18). An iPhone never locks it, and
    /// its apps are always full screen, so the hint is for iPad only.
    static var refused: Bool {
        guard Device.isPad, wanted, GCMouse.current != nil else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        let full = scenes.contains { $0.windows.contains { $0.isKeyWindow && fillsScreen($0) } }
        return full && !scenes.contains { $0.pointerLockState?.isLocked == true }
    }
}

/// On iPhone, UIKit keeps its pointer machinery for iPad: a pointer interaction's drivers stay detached from
/// its view, so the hidden style the trackpad asks for over the Mac never reaches AssistiveTouch's pointer.
/// This attaches them after UIKit's own update, as on iPad, so the request is at least made. The idea comes
/// from Madeira's iPhone hover experiment (written anew here). Private: `_updateInteractionIsEnabled`, and the
/// interaction's `drivers` (or older `driver`) whose `setView:` takes the view. Each step checks it exists.
enum PhonePointer {
    private static var original: IMP?
    private(set) static var status = "not run"

    static func install() {
        // Madeira's way follows where iOS says AssistiveTouch's pointer is, which iOS says only with the drivers attached
        // (Madeira's MADEIRA_PHONE_HOVER). The trackpad asks for no pointer style on iPhone, so AssistiveTouch's stays.
        guard !Device.isPad, original == nil, AbsolutePointer.madeiraWay else {
            if !Device.isPad { status = "off"; HengeLog.log("input", "phone pointer: \(status)") }
            return
        }
        let selector = NSSelectorFromString("_updateInteractionIsEnabled")
        guard let method = class_getInstanceMethod(UIPointerInteraction.self, selector) else {
            status = "unavailable"
            HengeLog.log("input", "phone pointer: \(status)")
            return
        }
        typealias Update = @convention(c) (AnyObject, Selector) -> Void
        let replacement: @convention(block) (AnyObject) -> Void = { object in
            if let original { unsafeBitCast(original, to: Update.self)(object, selector) }
            guard let interaction = object as? UIPointerInteraction, interaction.isEnabled, let view = interaction.view else { return }
            for driver in drivers(of: interaction) where driver.responds(to: NSSelectorFromString("setView:")) {
                driver.setValue(view, forKey: "view")
            }
        }
        original = method_setImplementation(method, imp_implementationWithBlock(replacement))
        status = "installed"
        HengeLog.log("input", "phone pointer: drivers attach as on iPad (\(status))")
    }

    private static func drivers(of interaction: UIPointerInteraction) -> [NSObject] {
        if interaction.responds(to: NSSelectorFromString("drivers")), let list = interaction.value(forKey: "drivers") as? [NSObject] { return list }
        if interaction.responds(to: NSSelectorFromString("driver")), let one = interaction.value(forKey: "driver") as? NSObject { return [one] }
        return []
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
    private var buttonsLogged = 0
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollsLogged = 0 // the first few, to see what a device's raw values look like
    private var lastScrollFirst: Float = 0, lastScrollSecond: Float = 0
    private var vendorChannels: Set<UUID> = []
    private var vendorMovesLogged = 0

    func start() {
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        reverse = defaults.bool(forKey: Self.reverseKey)
        releaseButtons()
        let swapButtons = defaults.bool(forKey: PhysicalMouseButtons.swapKey)
        buttons = PhysicalMouseButtons(swapsRightAndMiddle: swapButtons)
        buttonsLogged = 0
        HengeLog.log("input", "physical mouse: swap right/middle \(swapButtons ? "on" : "off")")
        lastScrollFirst = 0
        lastScrollSecond = 0
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            self.releaseButtons()
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            // The scene comes in the user info: the notification's object isn't it.
            let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene
            let locked = scene?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
        })
        PointerLock.set(true)
        if !Device.isPad { VendorMice.shared.start() } // an iPhone passes on no mouse without AssistiveTouch
    }

    func stop() {
        PointerLock.set(false)
        if !Device.isPad { VendorMice.shared.stop() }
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
        }
        mice.removeAll()
    }

    func releaseButtons() {
        for button in buttons.releaseAll() { henge_vm_mouse_button(button, 0) }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        // While a mouse passes through its maker's channel (VendorMice), what iOS also hands GameController of it
        // (with AssistiveTouch on) is ignored, so no click arrives twice.
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self, self.vendorChannels.isEmpty else { return }
            self.moved(dx, dy)
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.gcButton(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.gcButton(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.gcButton(2, pressed) }
        input.scroll.valueChangedHandler = { [weak self] _, first, second in
            guard let self, self.vendorChannels.isEmpty else { return }
            self.scrolled(first, second)
        }
    }

    /// Whether GameController has a mouse attached now.
    var hasMouse: Bool { !mice.isEmpty }

    private func gcButton(_ physicalButton: Int32, _ pressed: Bool) {
        AbsolutePointer.mouseUsed(button: true)
        // A release still goes through, so nothing pressed before a vendor channel opened stays down.
        guard vendorChannels.isEmpty || !pressed else { return }
        button(physicalButton, pressed)
    }

    // MARK: A mouse read through its maker's own channel (VendorMice). Any thread; the work runs on the main one.

    /// A vendor channel opened or closed for this mouse; while any is open, GameController's copy is ignored.
    func vendorChannel(_ id: UUID, open: Bool) {
        DispatchQueue.main.async { [self] in
            if open { vendorChannels.insert(id) } else { vendorChannels.remove(id) }
        }
    }

    /// Whether any mouse passes through a vendor channel now. Main thread.
    var hasVendorChannel: Bool { !vendorChannels.isEmpty }

    /// Raw sensor counts, Y down, unscaled, so macOS's own mouse settings set the feel.
    func vendorMoved(_ dx: Int32, _ dy: Int32) {
        DispatchQueue.main.async { [self] in
            if vendorMovesLogged < 8 { vendorMovesLogged += 1; HengeLog.log("input", "vendor mouse moved \(dx), \(dy)") }
            henge_vm_mouse_move(dx, dy)
        }
    }

    /// 0 left, 1 right, 2 middle.
    func vendorButton(_ button: UInt32, _ pressed: Bool) {
        DispatchQueue.main.async { [self] in self.button(Int32(button), pressed) }
    }

    /// Whole wheel detents, positive away from the user (wheel) and to the right (pan).
    func vendorScrolled(wheel: Int32, pan: Int32) {
        DispatchQueue.main.async { [self] in
            let configured = UserDefaults.standard.object(forKey: Self.scrollSpeedKey) == nil
                ? 0.3 : UserDefaults.standard.double(forKey: Self.scrollSpeedKey)
            let scale = Float(configured.isFinite ? min(max(configured, 0.1), 1.5) : 0.3)
            let way: Int32 = reverse ? -1 : 1
            let units = { (n: Int32) in way * n.signum() * Self.wheelUnits(Float(abs(n)), scale: scale) }
            if scrollsLogged < 24 {
                scrollsLogged += 1
                HengeLog.log("input", "vendor scroll: wheel \(wheel), pan \(pan)")
            }
            henge_vm_mouse_scroll(units(pan), units(wheel))
        }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    /// While iPadOS won't lock the pointer, the Mac's pointer follows the iPad's (AbsolutePointer) instead.
    private func moved(_ dx: Float, _ dy: Float) {
        AbsolutePointer.mouseUsed(button: false)
        if AbsolutePointer.phoneMouse { AbsolutePointer.phoneMoved(dx * speed, -dy * speed); return }
        guard !AbsolutePointer.inUse else { return }
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        henge_vm_mouse_move(Int32(x), Int32(y))
    }

    private func button(_ physicalButton: Int32, _ pressed: Bool) {
        guard let guestButton = buttons.event(physicalButton, pressed: pressed) else { return }
        if buttonsLogged < 32 {
            buttonsLogged += 1
            HengeLog.log("input", "physical mouse button: raw=\(physicalButton) guest=\(guestButton) \(pressed ? "down" : "up")")
        }
        henge_vm_mouse_button(guestButton, pressed ? 1 : 0)
        if !pressed { StickyKeys.shared.releaseAll() }
    }

    /// GameController puts vertical motion on the first axis and horizontal on the second.
    /// macOS accelerates wheel units roughly quadratically, so use a tunable square root
    /// and cap each event to keep a small pad gesture from jumping across a page.
    private func scrolled(_ first: Float, _ second: Float) {
        // GameController reports both axis states when either one changes. On a
        // Magic Keyboard it calls us twice per movement, with one stale axis in
        // each call; sending both values doubles the scroll and adds sideways drift.
        let verticalChanged = first != lastScrollFirst
        let horizontalChanged = second != lastScrollSecond
        lastScrollFirst = first
        lastScrollSecond = second
        let mostlyVertical = abs(first) > 2 * abs(second)
        let mostlyHorizontal = abs(second) > 2 * abs(first)
        let verticalRaw = verticalChanged && !mostlyHorizontal ? -first : 0
        let horizontalRaw = horizontalChanged && !mostlyVertical ? second : 0
        let defaults = UserDefaults.standard
        let configured = defaults.object(forKey: Self.scrollSpeedKey) == nil
            ? 0.3 : defaults.double(forKey: Self.scrollSpeedKey)
        let scale = Float(configured.isFinite ? min(max(configured, 0.1), 1.5) : 0.3)
        let way: Int32 = reverse ? -1 : 1
        let horizontal = way * Self.wheelUnits(horizontalRaw, scale: scale)
        let vertical = way * Self.wheelUnits(verticalRaw, scale: scale)
        if scrollsLogged < 24 {
            scrollsLogged += 1
            HengeLog.log("input", "scroll raw: \(first), \(second); units: \(horizontal), \(vertical)")
        }
        if horizontal != 0 || vertical != 0 { henge_vm_mouse_scroll(horizontal, vertical) }
    }

    private static func wheelUnits(_ value: Float, scale: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        let units = Int32(min(32, (22 * scale * abs(value).squareRoot()).rounded()))
        return value < 0 ? -units : units
    }
}

/// In a window (Stage Manager, or iPadOS's windowed apps) iPadOS won't lock the pointer, so the iPad's pointer
/// stays on screen and the Mac's has to follow it: over the Mac's screen, the pointer's place goes to the Mac's
/// absolute pointer (a USB tablet), and the iPad's own is hidden there (Trackpad's pointer style). Clicks and
/// scrolling still come from GameController.
enum AbsolutePointer {
    /// Where the Mac's screen is, in the session's coordinates (the window's); nil when it isn't on this
    /// screen (an external display) or there is no session.
    static var screen: CGRect? {
        didSet { if screen == nil && drawing { drawing = false; henge_vm_cursor_at(-1, -1) } }
    }
    private static var lastInUse: Bool?

    static var inUse: Bool {
        let pad = Device.isPad && screen != nil && !PointerLock.isLocked
        let now = pad || phoneMouse
        if now != lastInUse {
            lastInUse = now
            HengeLog.log("input", "absolute pointer: \(now ? (pad ? "on (the pointer isn't locked)" : "on (iPhone mouse through AssistiveTouch)") : "off")")
        }
        return now
    }

    /// iPhone, as Madeira does it: a mouse reaches an iPhone app only through AssistiveTouch. The Mac's pointer goes where
    /// iOS says AssistiveTouch's pointer is (hover, through PhonePointer's drivers), and Henge draws the Mac's arrow
    /// there at once, as Madeira draws its own cursor where the pointer is; the Mac's own idea of the place (moved there
    /// through the USB tablet) only follows behind, so the drawn arrow never trails or jumps. While iOS says nothing,
    /// the mouse's own motion moves it, one to one. Clicks and scrolling come from GameController; AssistiveTouch's
    /// copies of the clicks are dropped (Trackpad.Surface). Settings > Mouse turns it off ("henge.mouse.followAT").
    static let followKey = "henge.mouse.followAT"
    static var phoneMouse: Bool {
        // Not UIAccessibility.isAssistiveTouchRunning (false on iOS 27 with it on), and not whether GameController
        // lists a mouse right now: a Dell receiver's comes and goes between clicks, and each gap fell back to moving
        // the Mac's pointer the old way. On iPhone any sign of a mouse at all is AssistiveTouch's.
        guard !Device.isPad, screen != nil, mouseSeen, !HardwareMouse.shared.hasVendorChannel else { return false }
        return UserDefaults.standard.object(forKey: followKey) as? Bool ?? true
    }

    /// A mouse has shown itself on this iPhone: motion, a button, or iOS saying where its pointer is.
    static var mouseSeen = false
    static func noteMouse(_ how: String) {
        guard !Device.isPad, !mouseSeen else { return }
        mouseSeen = true
        HengeLog.log("input", "iPhone mouse: here (\(how))")
    }
    /// Kept for SessionView's hint: a mouse that has shown itself is coming through.
    static var deltaSeen: Bool { mouseSeen }

    /// The mouse moved or clicked just now (seconds, the touch clock): AssistiveTouch's taps around then are its copies.
    static var lastMouseActivity: TimeInterval = 0
    static var lastMouseButton: TimeInterval = 0
    static var mouseRecentlyUsed: Bool { phoneMouse && ProcessInfo.processInfo.systemUptime - lastMouseActivity < 3 }

    /// Madeira's way (the default): follow where iOS says the pointer is. Off: the mouse's own motion only.
    static let madeiraKey = "henge.mouse.madeira"
    static var madeiraWay: Bool { UserDefaults.standard.object(forKey: madeiraKey) as? Bool ?? true }

    /// Where the pointer is, in the window's points.
    static var reckoned: CGPoint?
    /// When iOS last said where its pointer is: the mouse's motion waits while it keeps saying.
    private static var lastSeen: TimeInterval = 0
    /// Henge draws the Mac's arrow at `reckoned` (not where the Mac has it), until a finger takes over.
    private static var drawing = false

    // What moved the pointer, logged every 5 s while the mouse is in use: the next log says which path ran.
    private static var counts: [String: Int] = [:]
    private static var countsSince: TimeInterval = 0
    private static var summaries = 0
    private static func count(_ what: String) {
        counts[what, default: 0] += 1
        let now = ProcessInfo.processInfo.systemUptime
        if countsSince == 0 { countsSince = now }
        guard now - countsSince >= 5, summaries < 120 else { return }
        summaries += 1
        let list = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let at = reckoned.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-"
        HengeLog.log("input", "iPhone mouse, last \(Int(now - countsSince)) s: \(list); pointer at \(at)")
        counts.removeAll()
        countsSince = now
    }

    /// iOS says where its pointer is (hover, a pointer-region request): on iPhone that is AssistiveTouch's pointer.
    static func seen(_ p: CGPoint, from source: String) {
        noteMouse("iOS's pointer, \(source)")
        if phoneMouse {
            count(source)
            guard madeiraWay else { return }
            lastSeen = ProcessInfo.processInfo.systemUptime
            follow(p)
            return
        }
        guard inUse else { return }
        move(to: p)
    }

    /// GameController's motion (screen-down), on iPhone: it moves the pointer only while iOS says nothing.
    static func phoneMoved(_ dx: Float, _ dy: Float) {
        count("mouse motion")
        guard let screen else { return }
        if madeiraWay && ProcessInfo.processInfo.systemUptime - lastSeen < 0.25 { return }
        let bounds = UIScreen.main.bounds
        var p = reckoned ?? CGPoint(x: screen.midX, y: screen.midY)
        p.x = min(max(p.x + CGFloat(dx), bounds.minX), bounds.maxX - 1)
        p.y = min(max(p.y + CGFloat(dy), bounds.minY), bounds.maxY - 1)
        follow(p)
    }

    /// The pointer is at p: the Mac's goes there, and its arrow is drawn there now.
    private static func follow(_ p: CGPoint) {
        guard let screen, screen.width > 0, screen.height > 0 else { return }
        reckoned = p
        let x = Double(min(max((p.x - screen.minX) / screen.width, 0), 1))
        let y = Double(min(max((p.y - screen.minY) / screen.height, 0), 1))
        henge_vm_pointer_at(x, y)
        if !drawing {
            drawing = true
            henge_vm_hide_cursor(0)
            HengeLog.log("input", "iPhone mouse: the Mac's arrow is drawn where the mouse is, at once (\(madeiraWay ? "following iOS's pointer" : "by the mouse's motion"))")
        }
        henge_vm_cursor_at(x, y)
    }

    static func mouseUsed(button: Bool) {
        noteMouse(button ? "a button" : "motion")
        let t = ProcessInfo.processInfo.systemUptime
        lastMouseActivity = t
        if button { lastMouseButton = t }
    }

    /// A finger on the trackpad moves the Mac's pointer: its arrow is drawn where the Mac has it again.
    static func fingerUsed() {
        guard drawing else { return }
        drawing = false
        henge_vm_cursor_at(-1, -1)
    }

    /// The iPad's pointer is at p: put the Mac's there too, if p is over the Mac's screen. On iPhone: a drag with
    /// the mouse (iOS's pointer, a button held), which goes where it is.
    static func move(to p: CGPoint) {
        if phoneMouse {
            count("pointer drag")
            lastSeen = ProcessInfo.processInfo.systemUptime
            follow(p)
            return
        }
        guard inUse, let screen, screen.width > 0, screen.height > 0, screen.contains(p) else { return }
        henge_vm_pointer_at(Double((p.x - screen.minX) / screen.width), Double((p.y - screen.minY) / screen.height))
    }
}

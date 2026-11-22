import SwiftUI
import UIKit

/// A surface that works like a Mac's trackpad — it is one: the engine presents it on
/// the Mac's USB bus as a Magic Trackpad 2, so the Mac's own multitouch engine sees
/// the fingers: two scroll, three swipe between Spaces and to Mission Control, four
/// show the session's hidden controls.
///
/// Clicking depends on the input mode (Settings > Trackpad):
///  - Touchscreen: the surface itself clicks. A quick tap is a left click, a quick
///    two-finger tap is a right click, and touching then holding presses the button
///    down so moving drags. These go out as mouse buttons alongside the pad's fingers.
///  - Volume buttons: the surface only points and gestures; the clicks live on the
///    volume keys (VolumeClicks), so a tap here does nothing.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")
    /// Pointing (Settings): the surface is no trackpad but the Mac's screen. The pointer goes where a touch is,
    /// through the absolute pointer (a USB tablet) the Mac also has. On by default on Apple Vision Pro, where
    /// a look and a pinch touch the place looked at.
    static let pointingKey = "henge.trackpad.pointing"
    static var pointing: Bool { UserDefaults.standard.object(forKey: pointingKey) as? Bool ?? Device.isVision }

    /// Where the Mac's screen is, in the surface's own coordinates (for pointing).
    var screen: CGRect = .zero

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { view.macScreen = screen }

    final class Surface: UIView, UIPointerInteractionDelegate {
        /// The emulated pad's sensor, in the Magic Trackpad 2's own units.
        private static let sensorW: Int32 = 8134
        private static let sensorH: Int32 = 5206
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8

        private struct Finger { var touch: UITouch; var id: Int32 }

        private var fingers: [Finger] = []
        private var freeIds = Set<Int32>(1...5) /* a touch screen reports five fingers at most */
        private var started = Date()
        private var travelled: CGFloat = 0
        private var mostFingers = 0
        private var touchesLogged = 0

        /* Touchscreen-mode clicking. */
        private var holding = false
        private var holdTimer: Timer?
        private let buzz = UIImpactFeedbackGenerator(style: .medium)
        private var tapsClick: Bool { VolumeClicks.inputMode == .touchscreen }

        /* Pointing: the Mac's screen, here, and the state of the touch that points at it. */
        var macScreen: CGRect = .zero
        private var pointing = false            /* this gesture points (the setting when it began) */
        private var points: [UITouch] = []
        private var pressed = false             /* the left button is down: a press or a drag */
        private var pressTimer: Timer?
        private var scrolling = false           /* two hands: the gesture scrolls, and never clicks */
        private var scrollFrom = CGPoint.zero
        private var scrollLeft = CGPoint.zero   /* movement not yet sent as whole wheel steps */
        private var pointAt = (x: Int32(0), y: Int32(0))
        /* A pinch waits this long before it presses, so a second hand starting a scroll does not click first. */
        private static let pressDelay: TimeInterval = 0.12
        /* Points of hand movement for one wheel step. */
        private static let scrollStep: CGFloat = 6

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        /// Where the finger is on the pad's sensor, in its units.
        private func sensor(_ t: UITouch) -> (Int32, Int32) {
            let p = t.location(in: self)
            // One scale for both axes. The view and the pad's sensor are different
            // shapes, so stretching the view to fill the sensor would make a finger
            // move the pointer further on one axis than the other. Map the view to a
            // centred part of the sensor at a single scale instead.
            let w = max(Double(bounds.width), 1), h = max(Double(bounds.height), 1)
            let scale = min(Double(Self.sensorW) / w, Double(Self.sensorH) / h)
            let x = (Double(p.x) - w / 2) * scale + Double(Self.sensorW) / 2
            let y = (Double(p.y) - h / 2) * scale + Double(Self.sensorH) / 2
            return (Int32(min(max(x, 0), Double(Self.sensorW))),
                    Int32(min(max(y, 0), Double(Self.sensorH))))
        }

        /* A touch sample's own clock, in ms. The guest derives finger speed from the
           timestamp deltas, so reports must carry the sample time, not the moment we
           process the event -- otherwise a burst of samples reads as one enormous flick
           and scroll inertia goes wild on release. */
        private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: Int(t * 1000)) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            if points.isEmpty && fingers.isEmpty { pointing = Trackpad.pointing && macScreen.width > 0 }
            if pointing { pointBegan(touches); return }
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                mostFingers = 0
                if tapsClick { buzz.prepare() }
            }
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                fingers.append(Finger(touch: t, id: id))
                let (x, y) = sensor(t)
                henge_vm_touch(id, 0, x, y, Self.ms(t.timestamp))
                if touchesLogged < 12 {
                    touchesLogged += 1
                    HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                }
            }
            mostFingers = max(mostFingers, fingers.count)
            guard tapsClick else { return }
            if fingers.count >= 2 {
                cancelHold()
                if holding { /* a drag becomes a multi-finger gesture */
                    holding = false
                    henge_vm_mouse_button(0, 0)
                }
            } else {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if pointing { pointMoved(); return }
            var moved = false
            let ts = Self.ms(event?.timestamp ?? touches.first?.timestamp ?? 0)
            for t in touches where t.type != .indirectPointer {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                let (x, y) = sensor(t)
                henge_vm_touch(fingers[i].id, 1, x, y, ts)
                moved = true
            }
            /* Moving means pointing or a gesture, not a tap or a press-to-drag. */
            if tapsClick && travelled >= Self.tapDistance && !holding { cancelHold() }
            /* One frame with every finger that moved, so the guest sees a gesture's
               fingers move together rather than one at a time. */
            if moved { henge_vm_touch_frame(ts) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if pointing { pointEnded(touches, cancelled: false) } else { lift(touches) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if pointing { pointEnded(touches, cancelled: true) } else { lift(touches) }
        }

        // MARK: Pointing

        /// A place on the surface as the tablet's coordinates on the Mac's screen (0...32767 each way).
        private func tablet(_ p: CGPoint) -> (x: Int32, y: Int32) {
            let s = macScreen
            let nx = min(max((p.x - s.minX) / max(s.width, 1), 0), 1)
            let ny = min(max((p.y - s.minY) / max(s.height, 1), 0), 1)
            return (Int32(nx * 32767), Int32(ny * 32767))
        }

        private func centroid() -> CGPoint {
            let ps = points.map { $0.location(in: self) }
            guard !ps.isEmpty else { return .zero }
            return CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
        }

        /// One touch points, clicks and drags; a second one (the other hand) turns the gesture into scrolling.
        private func pointBegan(_ touches: Set<UITouch>) {
            if points.isEmpty {
                started = Date()
                travelled = 0
                scrolling = false
                scrollLeft = .zero
            }
            points.append(contentsOf: touches.filter { t in !points.contains(t) })
            if points.count == 1, let t = points.first {
                pointAt = tablet(t.location(in: self))
                henge_vm_tablet(pointAt.x, pointAt.y, 0) /* the pointer jumps to where the touch is */
                pressTimer?.invalidate()
                let timer = Timer(timeInterval: Self.pressDelay, repeats: false) { [weak self] _ in
                    guard let self, self.points.count == 1, !self.scrolling, !self.pressed else { return }
                    self.pressed = true
                    henge_vm_tablet(self.pointAt.x, self.pointAt.y, 1)
                }
                RunLoop.main.add(timer, forMode: .common)
                pressTimer = timer
            } else if points.count >= 2 && !scrolling {
                pressTimer?.invalidate()
                if pressed { /* a drag had begun: let go where it is, then scroll */
                    pressed = false
                    henge_vm_tablet(pointAt.x, pointAt.y, 0)
                }
                scrolling = true
                scrollFrom = centroid()
            }
        }

        private func pointMoved() {
            if scrolling {
                let c = centroid()
                travelled += abs(c.x - scrollFrom.x) + abs(c.y - scrollFrom.y)
                /* The content follows the hands, as macOS's natural scrolling (its default) shows a wheel's steps:
                   hands up is the wheel up. */
                scrollLeft.x += c.x - scrollFrom.x
                scrollLeft.y += scrollFrom.y - c.y
                scrollFrom = c
                let dx = Int32(scrollLeft.x / Self.scrollStep), dy = Int32(scrollLeft.y / Self.scrollStep)
                if dx != 0 || dy != 0 {
                    scrollLeft.x -= CGFloat(dx) * Self.scrollStep
                    scrollLeft.y -= CGFloat(dy) * Self.scrollStep
                    henge_vm_tablet_scroll(dx, dy)
                }
            } else if let t = points.first {
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                pointAt = tablet(now)
                henge_vm_tablet(pointAt.x, pointAt.y, pressed ? 1 : 0)
            }
        }

        private func pointEnded(_ touches: Set<UITouch>, cancelled: Bool) {
            points.removeAll { touches.contains($0) }
            guard points.isEmpty else { return } /* a hand still pinches: the gesture goes on */
            pressTimer?.invalidate()
            pressTimer = nil
            let quick = Date().timeIntervalSince(started) < Self.tapTime
            let still = travelled < Self.tapDistance
            if pressed {
                pressed = false
                henge_vm_tablet(pointAt.x, pointAt.y, 0)
            } else if scrolling {
                if quick && still && !cancelled { /* both hands, briefly: a right click where the first one pointed */
                    henge_vm_tablet(pointAt.x, pointAt.y, 2)
                    henge_vm_tablet(pointAt.x, pointAt.y, 0)
                }
            } else if !cancelled { /* let go before the press: a click */
                henge_vm_tablet(pointAt.x, pointAt.y, 1)
                henge_vm_tablet(pointAt.x, pointAt.y, 0)
            }
            scrolling = false
            StickyKeys.shared.releaseAll()
        }

        private func lift(_ touches: Set<UITouch>) {
            var lifted: [Int32] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type != .indirectPointer else { return false }
                freeIds.insert(finger.id)
                lifted.append(finger.id)
                return true
            }
            guard !lifted.isEmpty else { return }
            let ts = Self.ms(touches.map(\.timestamp).max() ?? 0)
            for id in lifted { henge_vm_touch(id, 2, 0, 0, ts) }
            guard fingers.isEmpty else { return } /* fingers still down: the gesture goes on */
            /* The whole gesture is over. */
            if tapsClick {
                cancelHold()
                let quick = Date().timeIntervalSince(started) < Self.tapTime
                let still = travelled < Self.tapDistance
                if holding {
                    holding = false
                    henge_vm_mouse_button(0, 0) /* let go of the drag */
                } else if quick && still {
                    if mostFingers == 1 { click(0) }      /* a tap is a left click */
                    else if mostFingers == 2 { click(1) } /* a two-finger tap is a right click */
                }
            }
            if mostFingers >= 4, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
            }
            StickyKeys.shared.releaseAll()
        }

        /// A brief press of a mouse button: down then up.
        private func click(_ button: Int32) {
            henge_vm_mouse_button(button, 1)
            henge_vm_mouse_button(button, 0)
            buzz.impactOccurred()
        }

        /// A finger that stays put presses the left button down, so moving it drags.
        private func armHold() {
            cancelHold()
            let timer = Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                henge_vm_mouse_button(0, 1)
                self.buzz.impactOccurred()
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }
}

/// One mouse button you can hold: down when touched, up when let go.
struct MouseButton: View {
    let title: String
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 15))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        StickyKeys.shared.releaseAll()
                    }
            )
            .accessibilityLabel(title)
    }
}
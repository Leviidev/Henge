import SwiftUI
import UIKit

/// A surface that works like a Mac's trackpad. One finger moves the pointer; a tap clicks; a finger
/// held still for a moment presses the button until it lifts, which is how to drag. Two fingers
/// scroll, and tapped together they right-click. Pointer speed suits a 1920-wide screen on a small
/// one. Only fingers count here: a real trackpad or mouse goes through HardwareMouse.
struct Trackpad: UIViewRepresentable {
    /// Two-finger wheel scaling; 1 preserves the original scroll speed.
    static let scrollSpeedKey = "henge.trackpad.scrollSpeed"
    static let defaultScrollSpeed = 0.2
    static var scrollSpeed: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: scrollSpeedKey) as? Double ?? defaultScrollSpeed)
    }

    /// Three fingers tapped together: the session shows its hidden controls.
    static let threeFingerTap = Notification.Name("henge.trackpad.threeFingerTap")

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {}
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.cancelInput(); LocalPointerInput.uninstall(view) }

    final class Surface: UIView, UIPointerInteractionDelegate {
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8
        private var fingers: [UITouch] = []
        private var started = Date()
        private var travelled: CGFloat = 0
        private var hadTwoFingers = false
        private var gestureCancelled = false
        private var mostFingers = 0
        private var holding = false
        private var holdTimer: Timer?
        private var wheel = WheelAccumulator(gain: 6)
        private var scrollTimer: Timer?
        private var motion = ContactMotion<ObjectIdentifier>()
        private var restX: CGFloat = 0
        private var restY: CGFloat = 0
        private let buzz = UIImpactFeedbackGenerator(style: .medium)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        /// A full-size iPad has more room to move a finger across than a phone does.
        private var speed: CGFloat { traitCollection.horizontalSizeClass == .regular ? 2 : 3 }

        required init?(coder: NSCoder) { fatalError("made in code") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            LocalPointerInput.direct()
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                hadTwoFingers = false
                gestureCancelled = false
                mostFingers = 0
                wheel = WheelAccumulator(gain: 6)
                scrollTimer?.invalidate(); scrollTimer = nil
                restX = 0
                restY = 0
                buzz.prepare()
            }
            fingers.append(contentsOf: touches)
            motion.reset(positions())
            mostFingers = max(mostFingers, fingers.count)
            if fingers.count >= 2 {
                hadTwoFingers = true
                cancelHold()
                if fingers.count > 2 { scrollTimer?.invalidate(); scrollTimer = nil; wheel = WheelAccumulator(gain: 6) }
                if holding { holding = false; henge_vm_input_button(5, 0, 0); StickyKeys.shared.releaseAll() }
            } else {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard !gestureCancelled, !fingers.isEmpty, touches.contains(where: fingers.contains) else { return }
            let movement = motion.update(positions())
            let dx = movement.x, dy = movement.y
            travelled += movement.travel
            if fingers.count == 2 {
                scroll(dx, dy)
            } else if fingers.count > 2 {
                scrollTimer?.invalidate(); scrollTimer = nil
                wheel = WheelAccumulator(gain: 6)
            } else {
                if travelled >= Self.tapDistance, !holding { cancelHold() }
                restX += dx * speed
                restY += dy * speed
                let moveX = restX.rounded(), moveY = restY.rounded()
                guard moveX != 0 || moveY != 0 else { return }
                restX -= moveX
                restY -= moveY
                henge_vm_mouse_move(Int32(moveX), Int32(moveY))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            gestureCancelled = true
            scrollTimer?.invalidate(); scrollTimer = nil
            wheel = WheelAccumulator(gain: 6)
            lift(touches, cancelled: true)
        }

        private func lift(_ touches: Set<UITouch>, cancelled: Bool = false) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            fingers.removeAll { touches.contains($0) }
            motion.reset(positions())
            guard fingers.isEmpty else { return }
            cancelHold()
            if holding {
                holding = false
                henge_vm_input_button(5, 0, 0)
                StickyKeys.shared.releaseAll()
                return
            }
            if mostFingers >= 3 {
                if !cancelled && !gestureCancelled, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                    NotificationCenter.default.post(name: Trackpad.threeFingerTap, object: nil)
                }
                return
            }
            guard !cancelled && !gestureCancelled, travelled < Self.tapDistance, Date().timeIntervalSince(started) < Self.tapTime else { return }
            let button: Int32 = hadTwoFingers ? 1 : 0
            henge_vm_input_button(5, button, 1)
            henge_vm_input_button(5, button, 0)
            StickyKeys.shared.releaseAll()
        }

        private func armHold() {
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, !self.gestureCancelled, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                henge_vm_input_button(5, 0, 1)
                self.buzz.impactOccurred()
            }
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }

        private func positions() -> [ObjectIdentifier: CGPoint] {
            Dictionary(uniqueKeysWithValues: fingers.map { (ObjectIdentifier($0), $0.location(in: self)) })
        }

        private func scroll(_ dx: CGFloat, _ dy: CGFloat) {
            wheel.push(x: -Double(dx), y: Double(dy), scale: Double(Trackpad.scrollSpeed))
            scheduleScroll()
        }

        private func scheduleScroll() {
            guard scrollTimer == nil, wheel.needsDelivery else { return }
            let timer = Timer(timeInterval: 1.0 / 60, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.scrollTimer = nil
                let units = self.wheel.take()
                if units.x != 0 || units.y != 0 { henge_vm_mouse_scroll(units.x, units.y) }
            }
            scrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func cancelInput() {
            gestureCancelled = true
            cancelHold()
            scrollTimer?.invalidate(); scrollTimer = nil
            wheel = WheelAccumulator(gain: 6)
            holding = false
            henge_vm_input_release(5)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                LocalPointerInput.install(self) { [weak self] in self?.cancelInput() }
                return
            }
            LocalPointerInput.uninstall(self)
            cancelInput()
            cancelHold()
            scrollTimer?.invalidate(); scrollTimer = nil
            wheel = WheelAccumulator(gain: 6)
            fingers.removeAll(); motion.reset()
            if holding { holding = false; henge_vm_input_button(5, 0, 0); StickyKeys.shared.releaseAll() }
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
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_input_button(6, button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_input_button(6, button, 0)
                        StickyKeys.shared.releaseAll()
                    }
            )
            .onDisappear {
                if down { down = false; henge_vm_input_button(6, button, 0) }
            }
            .accessibilityLabel(title)
    }
}

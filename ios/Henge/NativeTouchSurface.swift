import SwiftUI
import UIKit

/// Sends full snapshots of up to five contacts in the displayed Mac image.
/// The supplied rectangle is relative to this overlay, including zoom and letterboxing.
struct NativeTouchSurface: UIViewRepresentable {
    let imageRect: CGRect
    let revealsControls: Bool
    var acceptsInput = true
    @MainActor static var diagnostics: String { Surface.diagnostics }

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { view.configure(imageRect, revealsControls: revealsControls, acceptsInput: acceptsInput) }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.cancel(); LocalPointerInput.uninstall(view) }

    final class Surface: UIView {
        private struct Finger {
            let touch: UITouch
            let id: UInt8
            var point: CGPoint
        }
        private var fingers: [Finger] = []
        private var imageRect = CGRect.zero
        private var generation: UInt32 = 0
        private var heartbeat: Timer?
        private var waitForLift = false
        private var acceptsInput = true
        private var lastSend = ProcessInfo.processInfo.systemUptime
        private var held = Set<UITouch>()
        private var nextContact: UInt8 = 1
        private static var fingerBegins: UInt64 = 0, pencilBegins: UInt64 = 0
        private static var accepted: UInt64 = 0, rejected: UInt64 = 0
        static var diagnostics: String {
            "native-touch: finger_begins=\(fingerBegins) pencil_begins=\(pencilBegins) accepted=\(accepted) rejected=\(rejected) status=\(hv_native_touch_status()) (no coordinates or input contents)"
        }
        private let controlsTap = UITapGestureRecognizer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            controlsTap.numberOfTouchesRequired = 4
            controlsTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            controlsTap.cancelsTouchesInView = true
            controlsTap.isEnabled = false
            controlsTap.addTarget(self, action: #selector(revealControls))
            addGestureRecognizer(controlsTap)
        }
        required init?(coder: NSCoder) { fatalError("made in code") }

        func configure(_ rect: CGRect, revealsControls: Bool, acceptsInput: Bool) {
            if self.acceptsInput != acceptsInput {
                self.acceptsInput = acceptsInput
                if !acceptsInput { cancel() }
            }
            if controlsTap.isEnabled != revealsControls {
                controlsTap.isEnabled = revealsControls
            }
            if imageRect != rect {
                cancel()
                // Host letterboxing/rotation changes only the coordinate
                // transform. The guest display identity and USB mapping persist.
                imageRect = rect
                generation = hv_native_touch_epoch()
                waitForLift = !held.isEmpty
            }
            updateHeartbeat()
            if !fingers.isEmpty { send() }
        }

        private func updateHeartbeat() {
            guard window != nil, acceptsInput, !fingers.isEmpty else {
                heartbeat?.invalidate();heartbeat=nil;return
            }
            if heartbeat == nil {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.send() }
                RunLoop.main.add(timer, forMode: .common)
                heartbeat = timer
            }
        }

        @objc private func revealControls() {
            cancel()
            NotificationCenter.default.post(name: Trackpad.threeFingerTap, object: nil)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                cancel(); heartbeat?.invalidate(); heartbeat = nil
                held.removeAll(); waitForLift = false
                LocalPointerInput.uninstall(self)
            } else {
                LocalPointerInput.install(self) { [weak self] in self?.cancel() }
            }
        }

        func cancel() {
            fingers.removeAll()
            updateHeartbeat()
            if LocalPointerInput.owns(self) {
                LocalPointerInput.setDirectContacts(0)
                hv_native_touch_cancel(generation)
            }
            waitForLift = !held.isEmpty
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // UIKit can omit an end callback across window/focus transitions.
            // Never let a retained, already-ended UITouch block all future taps.
            held = held.filter { $0.phase != .ended && $0.phase != .cancelled }
            let oldCount = fingers.count
            fingers.removeAll { $0.touch.phase == .ended || $0.touch.phase == .cancelled }
            if oldCount != fingers.count {
                // Lift stale USB contacts before admitting the new stroke. An
                // ended Pencil must not keep palm rejection active indefinitely.
                LocalPointerInput.setDirectContacts(fingers.count)
                send()
            }
            if held.isEmpty { waitForLift = false }
            // Apple Pencil touches are stylus events, not .direct. Send their
            // absolute tip position through the same entitlement-free USB path.
            // Indirect pointer events remain owned by HardwareMouse.
            let stylus = touches.filter { $0.type == .pencil }
            // While Pencil is down, palm contacts do not become guest fingers.
            let hasPencil = !stylus.isEmpty || fingers.contains { $0.touch.type == .pencil }
            let direct = hasPencil ? stylus : touches.filter { $0.type == .direct }
            guard !direct.isEmpty else { return }
            Self.pencilBegins &+= UInt64(stylus.count)
            Self.fingerBegins &+= UInt64(direct.count - stylus.count)
            if !stylus.isEmpty && fingers.contains(where: { $0.touch.type != .pencil }) {
                fingers.removeAll()
                hv_native_touch_cancel(generation)
            }
            LocalPointerInput.direct()
            if !stylus.isEmpty { waitForLift = false }
            held.formUnion(direct)
            guard acceptsInput, !waitForLift, hv_native_touch_status() == 2 else { waitForLift = true; return }
            for touch in direct where fingers.count < 5 {
                let point = touch.location(in: self)
                guard imageRect.contains(point) else { continue }
                // Do not reuse contact1 for every quick Pencil stroke while
                // its prior USB slot is still delivering a lift.
                while fingers.contains(where: { $0.id == nextContact }) { nextContact = nextContact == 127 ? 1 : nextContact + 1 }
                let id = nextContact
                nextContact = nextContact == 127 ? 1 : nextContact + 1
                fingers.append(Finger(touch: touch, id: id, point: point))
            }
            LocalPointerInput.setDirectContacts(fingers.count)
            send()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard acceptsInput, !waitForLift else { return }
            for index in fingers.indices where touches.contains(fingers[index].touch) {
                let touch = fingers[index].touch
                let latest = touch.type == .pencil ? (event?.coalescedTouches(for: touch)?.last ?? touch) : touch
                fingers[index].point = latest.location(in: self)
            }
            send()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel(); lift(touches) }
        private func lift(_ touches: Set<UITouch>) {
            held.subtract(touches)
            fingers.removeAll { touches.contains($0.touch) }
            LocalPointerInput.setDirectContacts(fingers.count)
            if held.isEmpty { waitForLift = false }
            send()
        }
        private func send() {
            guard window != nil, LocalPointerInput.owns(self) else { return }
            guard acceptsInput, hv_native_touch_status() == 2 else { cancel(); return }
            let now = ProcessInfo.processInfo.systemUptime
            // A newly begun stroke follows an arbitrary idle interval. Only
            // an already-running heartbeat can indicate a stalled held stroke.
            if heartbeat != nil && now - lastSend > 0.65 { cancel() }
            lastSend = now
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            if generation != hv_native_touch_epoch() {
                fingers.removeAll(); waitForLift = !held.isEmpty
                LocalPointerInput.setDirectContacts(0)
                generation = hv_native_touch_epoch()
            }
            let ids = fingers.map(\.id)
            let x = fingers.map { min(1, max(0, Double(($0.point.x-imageRect.minX)/imageRect.width))) }
            let y = fingers.map { min(1, max(0, Double(($0.point.y-imageRect.minY)/imageRect.height))) }
            if hv_native_touch_submit(generation, ids, x, y, ids.count) != 0 { Self.accepted &+= 1 }
            else { Self.rejected &+= 1 }
            updateHeartbeat()
        }
    }
}

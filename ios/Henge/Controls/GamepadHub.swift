import UIKit
import Combine

@MainActor
final class GamepadHub: ObservableObject {
    static let shared = GamepadHub()
    @Published var keyboardMapping = UserDefaults.standard.bool(forKey: "henge.gamepad.keyboardMapping") {
        didSet {
            guard oldValue != keyboardMapping else { return }
            UserDefaults.standard.set(keyboardMapping,forKey: "henge.gamepad.keyboardMapping")
            releaseDelivered(); deliver()
        }
    }
    private var local = GamepadState.off, remote = GamepadState.off
    private var keys = Set<UInt8>(), mouse = Set<Int>()
    private var look: CADisplayLink?
    private var lastLook: CFTimeInterval = 0
    private var lookRemainder = CGPoint.zero
    private var proxy: LookProxy?
    func set(_ state: GamepadState, remote: Bool = false) {
        guard state.valid else { return }
        if remote { guard self.remote != state else { return }; self.remote = state }
        else { guard local != state else { return }; local = state }
        deliver()
    }
    func point(_ input:LinkControl) {
        guard henge_vm_state()==1 else { return }
        switch input.type {
        case "move":henge_vm_mouse_move(Int32(input.x ?? 0),Int32(input.y ?? 0))
        case "scroll":henge_vm_mouse_scroll(Int32(input.x ?? 0),Int32(input.y ?? 0))
        case "button":if let button=input.code,let down=input.down { henge_vm_input_button(3,Int32(button),down ? 1 : 0) }
        case "release":henge_vm_input_release(3)
        default:break
        }
    }
    func releaseAll() { local = .off; remote = .off; releaseDelivered();henge_vm_input_release(3) }
    private func releaseDelivered() {
        look?.invalidate(); look = nil; proxy = nil; lastLook = 0; lookRemainder = .zero
        henge_vm_input_release(2); keys.removeAll(); mouse.removeAll()
        _ = henge_vm_gamepad(0,0,0,0,0,0,0,0,8)
    }
    private var state: GamepadState { .merged(local,remote) }
    private func deliver() {
        guard henge_vm_state() == 1 else { releaseAll(); return }
        let s = state
        if !keyboardMapping {
            _ = henge_vm_gamepad(s.connected ? 1 : 0,s.buttons,s.lx,s.ly,s.rx,s.ry,s.left,s.right,s.hat)
            return
        }
        let next = s.mappedKeys
        for k in keys.subtracting(next) { henge_vm_input_key(2,k,0) }
        for k in next.subtracting(keys) { henge_vm_input_key(2,k,1) }
        keys = next
        var buttons = Set<Int>()
        if s.connected && s.right > 64 { buttons.insert(0) }
        if s.connected && s.left > 64 { buttons.insert(1) }
        if s.connected && (s.rx != 0 || s.ry != 0) { buttons.insert(1) }
        for b in mouse.subtracting(buttons) { henge_vm_input_button(2,Int32(b),0) }
        for b in buttons.subtracting(mouse) { henge_vm_input_button(2,Int32(b),1) }
        mouse = buttons
        let moving = s.connected && (s.rx != 0 || s.ry != 0)
        if moving && look == nil {
            let proxy = LookProxy(); proxy.owner = self; self.proxy = proxy
            let display = CADisplayLink(target: proxy,selector: #selector(LookProxy.tick(_:)))
            display.preferredFrameRateRange = CAFrameRateRange(minimum: 30,maximum: 60,preferred: 60)
            display.add(to: .main,forMode: .common); look = display
        } else if !moving { look?.invalidate(); look = nil; proxy = nil; lastLook = 0; lookRemainder = .zero }
    }
    fileprivate func tick(_ display: CADisplayLink) {
        guard UIApplication.shared.applicationState == .active, henge_vm_state() == 1 else { releaseAll(); return }
        let dt = lastLook > 0 ? min(0.05,display.timestamp-lastLook) : 1/60
        lastLook = display.timestamp
        let s = state
        let speed = Double(s.mouseSpeed ?? 900)
        lookRemainder.x += CGFloat(s.rx)/32767 * speed * dt
        lookRemainder.y += CGFloat(s.ry)/32767 * speed * dt
        let x = Int32(lookRemainder.x), y = Int32(lookRemainder.y)
        lookRemainder.x -= CGFloat(x); lookRemainder.y -= CGFloat(y)
        if x != 0 || y != 0 { henge_vm_mouse_move(x,y) }
    }
}
private final class LookProxy: NSObject {
    weak var owner: GamepadHub?
    @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { owner?.tick(link) } }
}

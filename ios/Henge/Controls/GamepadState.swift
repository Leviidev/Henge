import Foundation

/// Full-state packets make releases authoritative after coalescing. Integer
/// wire values avoid NaN/Infinity and have the same bounds as the USB report.
struct GamepadState: Codable, Equatable {
    var connected = true
    var buttons: UInt16 = 0
    var hat: UInt8 = 8
    var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
    var left: UInt8 = 0, right: UInt8 = 0
    var mouseSpeed: UInt16? = nil // additive wire field: older peers default to 900
    static var off: Self { Self(connected: false) }
    var valid: Bool { hat <= 8 && ![lx, ly, rx, ry].contains(Int16.min) && (mouseSpeed.map { (300...2400).contains(Int($0)) } ?? true) }
    static func merged(_ a: Self, _ b: Self) -> Self {
        let a = a.connected ? a : .off, b = b.connected ? b : .off
        return Self(connected: a.connected || b.connected, buttons: a.buttons | b.buttons,
            hat: a.hat < 8 ? a.hat : b.hat, lx: a.lx != 0 || a.ly != 0 ? a.lx : b.lx, ly: a.lx != 0 || a.ly != 0 ? a.ly : b.ly,
            rx: a.rx != 0 || a.ry != 0 ? a.rx : b.rx, ry: a.rx != 0 || a.ry != 0 ? a.ry : b.ry,
            left: max(a.left,b.left),right: max(a.right,b.right),
            mouseSpeed: a.rx != 0 || a.ry != 0 ? a.mouseSpeed : b.mouseSpeed)
    }
    /// Explicit Roblox-style keyboard fallback, not a native controller claim.
    var mappedKeys: Set<UInt8> {
        guard connected else { return [] }
        var keys = Set<UInt8>()
        if ly < -8000 || [0,1,7].contains(hat) { keys.insert(26) } // W
        if ly > 8000 || [3,4,5].contains(hat) { keys.insert(22) } // S
        if lx < -8000 || [5,6,7].contains(hat) { keys.insert(4) } // A
        if lx > 8000 || [1,2,3].contains(hat) { keys.insert(7) } // D
        let mapping: [(UInt16,UInt8)] = [(1,44),(2,6),(4,8),(8,21),(16,225),(32,224),(256,41),(512,43)]
        for (mask,key) in mapping {
            if buttons & mask != 0 { keys.insert(key) }
        }
        return keys
    }
}

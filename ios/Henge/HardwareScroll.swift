import Foundation

/// Axis-specific callbacks supply deltas; never replay the other axis's stale
/// value or discard a legitimate repeated delta because its magnitude is equal.
struct HardwareScroll {
    static let defaultSpeed = 0.15
    static let minimumSpeed = 0.02
    static let maximumSpeed = 1.5
    private var wheel = WheelAccumulator(gain: 8)
    var needsDelivery: Bool { wheel.needsDelivery }

    static func speed(_ value: Double) -> Double {
        value.isFinite ? min(max(value, minimumSpeed), maximumSpeed) : defaultSpeed
    }

    mutating func push(first: Double, second: Double, scale: Double, reversed: Bool) {
        let direction = reversed ? -1.0 : 1.0
        wheel.push(x: second * direction, y: -first * direction, scale: Self.speed(scale))
    }
    mutating func take() -> (x: Int32, y: Int32) { wheel.take() }
}

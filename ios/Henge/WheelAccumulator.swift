import Foundation

/// Accumulate raw movement before nonlinear wheel conversion. Applying sqrt to
/// every callback first makes scroll speed depend on callback count.
struct WheelAccumulator {
    static let eventLimit = 4.0
    private var rawX = 0.0, rawY = 0.0
    private var fractionX = 0.0, fractionY = 0.0
    private var scale = 0.15
    private let gain: Double

    init(gain: Double) { self.gain = gain }

    var needsDelivery: Bool { rawX != 0 || rawY != 0 }

    mutating func push(x: Double, y: Double, scale: Double) {
        guard x.isFinite, y.isFinite else { return }
        self.scale = scale.isFinite ? min(max(scale, 0.02), 1.5) : 0.15
        // Bound a stalled UI's backlog. One batch is consumed at the next tick;
        // capped output is not replayed later as an unexpected long tail.
        rawX = min(max(rawX + x, -1024), 1024)
        rawY = min(max(rawY + y, -1024), 1024)
    }

    mutating func take() -> (x: Int32, y: Int32) {
        var x = rawX, y = rawY
        rawX = 0; rawY = 0
        if abs(y) > 2 * abs(x) { x = 0 }
        else if abs(x) > 2 * abs(y) { y = 0 }
        let factor = gain * scale, limit = Self.eventLimit
        func convert(_ raw: Double, fraction: inout Double) -> Int32 {
            guard raw != 0 else { return 0 }
            let signed = (raw < 0 ? -1.0 : 1.0) * factor * abs(raw).squareRoot()
            let value = min(max(signed + fraction, -limit), limit)
            let whole = value.rounded(.towardZero)
            fraction = value - whole
            return Int32(whole)
        }
        return (convert(x, fraction: &fractionX), convert(y, fraction: &fractionY))
    }
}

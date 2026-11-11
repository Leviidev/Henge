import CoreGraphics

enum ScrollSensitivity {
    static let key = "henge.mouse.scrollSpeed"
    static let defaultValue = 0.3
    static let range = 0.05...1.5

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

struct WheelScroll {
    private var remainder = 0.0

    mutating func units(for value: Float, sensitivity: Double) -> Int32 {
        guard value.isFinite, value != 0 else { return 0 }
        // Bound bursts before scaling so that even fast inputs respect the slider.
        let bounded = min(max(Double(value), -4), 4)
        remainder += bounded * 2 * ScrollSensitivity.clamped(sensitivity)
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return Int32(whole)
    }
}

struct TwoFingerScroll {
    private var offset = CGPoint.zero

    mutating func apply(combinedMovement: CGPoint, sensitivity: Double) {
        // Adjust the motion common to both fingers. Their separation still
        // changes by the original amount, so pinch and rotate work as before.
        let correction = (CGFloat(ScrollSensitivity.clamped(sensitivity)) - 1) / 2
        offset.x += combinedMovement.x * correction
        offset.y += combinedMovement.y * correction
    }

    func position(for raw: CGPoint) -> CGPoint {
        CGPoint(x: raw.x + offset.x, y: raw.y + offset.y)
    }
}

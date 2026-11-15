import Foundation

@main struct HardwareScrollTests {
    static func main() {
        // Different callback partitions, identical raw total in one frame.
        for count in [1, 2, 4, 8, 16, 64] {
            var whole = HardwareScroll(), split = HardwareScroll()
            whole.push(first: 4, second: 0, scale: 0.15, reversed: false)
            for _ in 0..<count { split.push(first: 4 / Double(count), second: 0, scale: 0.15, reversed: false) }
            let a = whole.take(), b = split.take()
            precondition(a.x == b.x && a.y == b.y)
            precondition(!whole.needsDelivery && !split.needsDelivery)
        }
        // Repeated equal deltas are real movement on axis-specific callbacks.
        var repeated = HardwareScroll(), single = HardwareScroll()
        repeated.push(first: 4, second: 0, scale: 0.15, reversed: false)
        repeated.push(first: 4, second: 0, scale: 0.15, reversed: false)
        single.push(first: 8, second: 0, scale: 0.15, reversed: false)
        precondition(repeated.take().y == single.take().y)

        var scroll = HardwareScroll()
        for _ in 0..<100 { scroll.push(first: .infinity, second: 0, scale: .nan, reversed: false) }
        precondition(!scroll.needsDelivery)
        precondition(scroll.take().x == 0 && scroll.take().y == 0)
        var total: Int32 = 0
        for _ in 0..<20 {
            scroll.push(first: 0.01, second: 0, scale: 0.15, reversed: false)
            total += scroll.take().y
        }
        precondition(total < 0, "Fractional wheel units must accumulate")
        precondition(!scroll.needsDelivery)
        for _ in 0..<100 { precondition(scroll.take().y == 0) }

        for scale in [0.02, 0.15, 1.5, Double.nan] {
            scroll = HardwareScroll()
            for _ in 0..<10000 { scroll.push(first: 100, second: 100, scale: scale, reversed: true) }
            let event = scroll.take()
            precondition(abs(event.x) <= 4 && abs(event.y) <= 4)
            precondition(!scroll.needsDelivery)
            precondition(scroll.take().x == 0 && scroll.take().y == 0, "No capped backlog replay")
        }
        scroll = HardwareScroll()
        scroll.push(first: -4, second: 0.01, scale: 0.15, reversed: false)
        let forward = scroll.take()
        precondition(forward.y > 0 && forward.x == 0)
        var reverse = HardwareScroll()
        reverse.push(first: -4, second: 0.01, scale: 0.15, reversed: true)
        precondition(reverse.take().y == -forward.y)

        // Shared on-screen converter has the same batching and frame limits.
        var screen = WheelAccumulator(gain: 6)
        screen.push(x: 0, y: 4, scale: 0.2)
        precondition(screen.take().y == 2)
        precondition(!screen.needsDelivery)

        var motion = ContactMotion<Int>()
        motion.reset([1: CGPoint(x: 0, y: 0), 2: CGPoint(x: 100, y: 100)])
        var delta = motion.update([1: CGPoint(x: 0, y: 0), 2: CGPoint(x: 108, y: 104)])
        precondition(delta.x == 4 && delta.y == 2, "Movement of the second contact must contribute")
        delta = motion.update([1: CGPoint(x: 0, y: 0), 2: CGPoint(x: 108, y: 104)])
        precondition(delta.x == 0 && delta.y == 0, "Duplicate callbacks must not replay a stale first-finger delta")
        motion.reset([2: CGPoint(x: 108, y: 104)])
        delta = motion.update([2: CGPoint(x: 108, y: 104)])
        precondition(delta.x == 0 && delta.y == 0, "Membership changes must not jump")
        motion.reset([1: CGPoint(x: 0, y: 0), 2: CGPoint(x: 0, y: 0)])
        delta = motion.update([1: CGPoint(x: 10, y: 0), 2: CGPoint(x: -10, y: 0)])
        precondition(delta.x == 0 && delta.travel == 10, "Opposing contacts must not be classified as an unmoved tap")
        precondition(HardwareScroll.speed(-1) == 0.02 && HardwareScroll.speed(100) == 1.5 && HardwareScroll.speed(.nan) == 0.15)
        print("scroll regression: callback partition invariance, repeated deltas, 4-unit bounds, fractions, no idle tail, reversal and contact-centroid transitions passed")
    }
}

import Foundation

/// Centroid movement with explicit membership resets. Repeated callbacks for
/// already-observed positions contribute zero rather than repeating a delta.
struct ContactMotion<Key: Hashable> {
    private var previous: [Key: CGPoint] = [:]
    mutating func reset(_ positions: [Key: CGPoint] = [:]) { previous = positions }
    mutating func update(_ positions: [Key: CGPoint]) -> (x: CGFloat, y: CGFloat, travel: CGFloat) {
        guard !positions.isEmpty else { previous = [:]; return (0, 0, 0) }
        var dx: CGFloat = 0, dy: CGFloat = 0, travel: CGFloat = 0
        for (key, point) in positions {
            if let before = previous[key] {
                let x = point.x - before.x, y = point.y - before.y
                dx += x; dy += y
                travel = max(travel, abs(x) + abs(y))
            }
        }
        previous = positions
        return (dx / CGFloat(positions.count), dy / CGFloat(positions.count), travel)
    }
}

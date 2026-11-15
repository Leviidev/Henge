import Foundation

/// A counter belongs to one uninterrupted run. A reset, pause/continue, or
/// invalid timestamp establishes a baseline; it is never an unsigned wrap.
struct SessionCounter {
    struct Interval {
        let count: UInt64
        let seconds: TimeInterval
        var perSecond: Double { Double(count) / seconds }
    }
    private var previous: (count: UInt64, time: TimeInterval, epoch: UInt64)?

    mutating func reset() { previous = nil }

    mutating func sample(count: UInt64, time: TimeInterval, epoch: UInt64) -> Interval? {
        guard time.isFinite else { reset(); return nil }
        defer { previous = (count, time, epoch) }
        guard let prior = previous, prior.epoch == epoch,
              count >= prior.count, time > prior.time else { return nil }
        return Interval(count: count - prior.count, seconds: time - prior.time)
    }
}

/// Main-actor-owned sampling state, deliberately not ObservableObject/@Observable.
/// Sampling must not rebuild the display hierarchy while Details is closed.
final class SessionStatistics {
    private var counter = SessionCounter()
    private(set) var blocksPerSecond: Double = 0

    func reset(blocks: UInt64, time: TimeInterval, epoch: UInt64 = 0) {
        counter.reset()
        _ = counter.sample(count: blocks, time: time, epoch: epoch)
        blocksPerSecond = 0
    }

    func sample(blocks: UInt64, time: TimeInterval, epoch: UInt64 = 0) {
        blocksPerSecond = counter.sample(count: blocks, time: time, epoch: epoch)?.perSecond ?? 0
    }
}

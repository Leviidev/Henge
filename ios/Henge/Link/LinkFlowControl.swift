import Foundation

/// A send completion only means Network.framework accepted the bytes. A frame
/// credit is returned only after BOTH that completion and the peer's decoder
/// acknowledgement. Duplicate, future and retired acknowledgements do nothing.
final class LinkFrameCredits: @unchecked Sendable {
    static let capacity = 3
    struct Receipt { let sequence: UInt64; let consumed: Bool; let seconds: TimeInterval }
    private struct Frame { let began: TimeInterval; var sent = false; var consumed: TimeInterval? }
    private let lock = NSLock()
    private var frames: [UInt64: Frame] = [:]
    var pending: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    func begin(_ sequence: UInt64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sequence > 0, frames.count < Self.capacity, frames[sequence] == nil else { return false }
        frames[sequence] = Frame(began: now); return true
    }
    func sent(_ sequence: UInt64, success: Bool) -> Receipt? {
        lock.lock(); defer { lock.unlock() }
        guard var frame = frames[sequence] else { return nil }
        if !success {
            frames.removeValue(forKey: sequence)
            return Receipt(sequence: sequence, consumed: false, seconds: 0)
        }
        frame.sent = true
        if let at = frame.consumed {
            frames.removeValue(forKey: sequence)
            return Receipt(sequence: sequence, consumed: true, seconds: max(0, at - frame.began))
        }
        frames[sequence] = frame; return nil
    }
    func consumed(_ sequence: UInt64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Receipt? {
        lock.lock(); defer { lock.unlock() }
        guard var frame = frames[sequence], frame.consumed == nil else { return nil }
        frame.consumed = now
        if frame.sent {
            frames.removeValue(forKey: sequence)
            return Receipt(sequence: sequence, consumed: true, seconds: max(0, now - frame.began))
        }
        frames[sequence] = frame; return nil
    }
    func cancel() -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = frames.count; frames.removeAll(); return count
    }
}

/// Process-wide frame identities prevent a delayed ACK from an old mirror
/// encoder releasing credit in a replacement encoder on the same connection.
final class LinkFrameSequence {
    private static let lock=NSLock()
    private static var value:UInt64=0
    static func next()->UInt64 {
        lock.lock();defer { lock.unlock() }
        precondition(value<UInt64.max,"Link sequence exhausted")
        value += 1;return value
    }
}

/// Snapshot cadence is separate from transport credits. A denied final change
/// requests one fresh worker snapshot when its budget/credit becomes available.
struct LinkCaptureBudget {
    private var deadline=0.0
    func delay(now:Double)->Double { max(0,deadline-now) }
    mutating func accepted(now:Double,hz:Int) { deadline=now+1/Double(min(120,max(24,hz))) }
    mutating func reset() { deadline=0 }
}

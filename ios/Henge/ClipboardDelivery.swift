import Foundation

/// Only runs for an explicit Paste. Idle clipboard reception remains event driven.
enum ClipboardDelivery {
    enum Outcome: Equatable { case delivered, interrupted, timedOut }
    @MainActor static func wait(isCurrent: () -> Bool, isDelivered: () -> Bool,
                               attempts: Int = 80,
                               sleep: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }) async -> Outcome {
        for _ in 0..<attempts {
            guard !Task.isCancelled, isCurrent() else { return .interrupted }
            if isDelivered() { return .delivered }
            do { try await sleep() } catch { return .interrupted }
        }
        guard !Task.isCancelled, isCurrent() else { return .interrupted }
        return isDelivered() ? .delivered : .timedOut
    }
}

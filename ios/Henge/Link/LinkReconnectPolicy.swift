import Foundation

/// Bounded retries while a controller is visible. No polling or background task.
struct LinkReconnectPolicy {
    private(set) var attempts=0
    mutating func reset() { attempts=0 }
    mutating func nextDelay()->Double? {
        guard attempts<12 else { return nil }
        let delay=min(15,0.35*pow(2,Double(min(6,attempts))))
        attempts += 1;return delay
    }
}

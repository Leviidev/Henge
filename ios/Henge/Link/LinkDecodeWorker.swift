import Foundation
import CoreVideo

/// Protocol v2 bounds the entire capture/send/decode path to three frames.
/// Each generation owns its slots: cancelled work cannot starve a reconnect.
final class LinkDecodeWorker {
    private final class Run {
        let id = UUID()
        let slots = DispatchSemaphore(value: LinkFrameCredits.capacity)
        var decoder: LinkDecoder? // decoder queue only
        var pending = 0, peak = 0 // protected by lock
        var decoded = 0
        var totalMS = 0.0, maxMS = 0.0, maxWaitMS = 0.0 // decoder queue only
    }
    private let queue = DispatchQueue(label: "henge.link.decoder", qos: .userInitiated)
    private let lock = NSLock()
    private var run: Run?
    private let decodeOperation: ((Data) throws -> UInt64)?
    private let report: (String) -> Void
    // The injected operation lets tests suspend real queue work deterministically.
    init(decode: ((Data) throws -> UInt64)? = nil, report: @escaping (String) -> Void = { _ in }) {
        decodeOperation = decode; self.report = report
    }
    func start(mode: LinkMode, output: @escaping (CVPixelBuffer) -> Void) -> UUID {
        let next = Run()
        lock.lock(); let previous = run; run = next; lock.unlock()
        queue.async { [self, previous] in
            previous?.decoder = nil
            guard current(next) else { return }
            if decodeOperation == nil { next.decoder = LinkDecoder(mode: mode, output: output) }
        }
        return next.id
    }
    func consume(_ data: Data, generation g: UUID, consumed: @escaping (UInt64) -> Void, failed: @escaping (String) -> Void) {
        lock.lock()
        guard let active = run, active.id == g else { lock.unlock(); return }
        guard active.slots.wait(timeout: .now()) == .success else {
            lock.unlock(); stop(active); failed("Peer exceeded the negotiated three-frame video window"); return
        }
        active.pending += 1; active.peak = max(active.peak, active.pending)
        lock.unlock()
        let queued = ProcessInfo.processInfo.systemUptime
        queue.async { [self, active] in
            var sequence: UInt64?, failure: String?
            if current(active) {
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    if let decodeOperation { sequence = try decodeOperation(data) }
                    else if let decoder = active.decoder { sequence = try decoder.decode(data) }
                    else { throw LinkError.invalid("Decoder was not initialized") }
                    let ms = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    active.decoded += 1; active.totalMS += ms; active.maxMS = max(active.maxMS, ms)
                    active.maxWaitMS = max(active.maxWaitMS, (began - queued) * 1000)
                    if active.decoded == 1 || active.decoded % 600 == 0 {
                        lock.lock(); let peak = active.peak; lock.unlock()
                        report(String(format: "decode-consumed=%d queue-peak=%d/3 mean-ms=%.2f max-ms=%.2f max-queue-ms=%.2f; acknowledgement precedes presentation", active.decoded, peak, active.totalMS / Double(active.decoded), active.maxMS, active.maxWaitMS))
                    }
                } catch { failure = error.localizedDescription }
            }
            // Release the queue slot BEFORE acknowledging: a fast sender must
            // never reclaim its credit while this old job still owns our slot.
            lock.lock(); active.pending -= 1; lock.unlock()
            active.slots.signal()
            guard current(active) else { return }
            if let failure { stop(active); failed(failure) }
            else if let sequence { consumed(sequence) }
        }
    }
    func stop() {
        lock.lock(); let previous = run; run = nil; lock.unlock()
        queue.async { previous?.decoder = nil }
    }
    private func stop(_ active: Run) {
        lock.lock(); if run === active { run = nil }; lock.unlock()
        queue.async { active.decoder = nil }
    }
    private func current(_ active: Run) -> Bool {
        lock.lock(); defer { lock.unlock() }; return run === active
    }
}

/// If main is temporarily busy, retain just the latest decoded image instead of
/// posting an unbounded sequence of UI tasks. A superseded image is never
/// misrepresented as having reached the physical screen.
final class LinkPixelMailbox {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var queued = false
    private let deliver: @MainActor (CVPixelBuffer) -> Void
    init(deliver: @escaping @MainActor (CVPixelBuffer) -> Void) { self.deliver = deliver }
    func submit(_ pixel: CVPixelBuffer) {
        lock.lock(); latest = pixel
        if queued { lock.unlock(); return }
        queued = true; lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock(); let pixel = latest; latest = nil; queued = false; lock.unlock()
            if let pixel { deliver(pixel) }
        }
    }
}

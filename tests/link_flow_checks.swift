import Foundation

func linkFlowChecks(_ mode: LinkMode) {
    let credits = LinkFrameCredits()
    require(!credits.begin(0), "Zero sequence accepted")
    for n in UInt64(1)...3 { require(credits.begin(n, now: 10), "Missing initial credit") }
    require(!credits.begin(4), "Fourth frame bypassed decode backpressure")
    for n in UInt64(1)...3 { require(credits.sent(n, success: true) == nil, "Local send completion returned a decode credit") }
    require(!credits.begin(4), "TCP buffering bypassed decoder capacity")
    require(credits.consumed(999, now: 11) == nil, "Future ACK returned a credit")
    let receipt = credits.consumed(1, now: 11)
    require(receipt?.consumed == true && receipt?.seconds == 1, "Decoder consumption did not return the sent credit")
    require(credits.consumed(1) == nil && credits.sent(1, success: true) == nil, "Duplicate completion returned two credits")
    require(credits.begin(4), "Consumed frame failed to reopen window")
    require(credits.consumed(4) == nil && credits.pending == 3, "ACK before send completion retired too early")
    require(credits.sent(4, success: true)?.consumed == true, "Reversed callback order stranded a credit")
    require(credits.sent(2, success: false)?.consumed == false, "Send failure leaked a credit")
    require(credits.cancel() == 1 && credits.pending == 0, "Cancellation leaked pending frames")
    require(credits.consumed(3) == nil && credits.sent(3, success: true) == nil, "Late callbacks reopened cancelled window")

    // Both callbacks can run concurrently, and duplicate peer ACKs must never
    // oversignal the producer's semaphore. Test the production locked ledger.
    let countLock = NSLock(); var receipts = 0
    for n in UInt64(10)..<110 {
        require(credits.begin(n), "Concurrent test lost capacity")
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            let r = i % 2 == 0 ? credits.sent(n, success: true) : credits.consumed(n)
            if r != nil { countLock.lock(); receipts += 1; countLock.unlock() }
        }
        require(credits.pending == 0, "Concurrent callback stranded frame")
    }
    require(receipts == 100, "Concurrent callbacks returned duplicate credits")

    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let decoded = DispatchSemaphore(value: 0)
    let worker = LinkDecodeWorker(decode: { data in
        let n = UInt64(data[0])
        if n == 1 { entered.signal(); require(release.wait(timeout: .now() + 10) == .success, "Blocked decode timed out") }
        return n
    })
    let old = worker.start(mode: mode, output: { _ in fatalError("Injected decoder output") })
    let stale: (UInt64) -> Void = { _ in fatalError("Cancelled generation sent ACK") }
    worker.consume(Data([1]), generation: old, consumed: stale, failed: { fatalError($0) })
    require(entered.wait(timeout: .now() + 5) == .success, "Decoder did not start")
    worker.consume(Data([2]), generation: old, consumed: stale, failed: { fatalError($0) })
    worker.consume(Data([3]), generation: old, consumed: stale, failed: { fatalError($0) })
    worker.stop()
    let next = worker.start(mode: mode, output: { _ in })
    // New per-generation slots must be immediately available, even though all
    // three cancelled jobs still occupy the serial worker's queue.
    for n in UInt8(4)...6 {
        worker.consume(Data([n]), generation: next, consumed: { _ in decoded.signal() }, failed: { fatalError($0) })
    }
    worker.consume(Data([99]), generation: old, consumed: stale, failed: { fatalError($0) })
    release.signal()
    for _ in 0..<3 { require(decoded.wait(timeout: .now() + 5) == .success, "Reconnect starved behind cancelled generation") }
    // The consumed callback runs after the local slot is free, so returning a
    // sender credit cannot make the next valid frame overflow this worker.
    let fourth = DispatchSemaphore(value: 0)
    worker.consume(Data([7]), generation: next, consumed: { _ in fourth.signal() }, failed: { fatalError($0) })
    require(fourth.wait(timeout: .now() + 5) == .success, "Released slot not reusable")
    worker.stop()
    let failure = DispatchSemaphore(value: 0)
    let broken = LinkDecodeWorker(decode: { _ in throw LinkError.invalid("expected test failure") })
    let bad = broken.start(mode: mode, output: { _ in })
    broken.consume(Data([1]), generation: bad, consumed: { _ in fatalError("Failed decode acknowledged") }, failed: { _ in failure.signal() })
    require(failure.wait(timeout: .now() + 5) == .success, "Decode failure not surfaced")
    broken.stop()
    print("PASS decoder flow: TCP completion cannot exceed 3-frame window; ACK ordering/duplicates/concurrency/failure/cancel/reconnect")
}

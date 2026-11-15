import Foundation

private final class State: @unchecked Sendable {
    let lock=NSLock(), entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
    private var calls=0
    func work() {
        precondition(!Thread.isMainThread)
        lock.lock();calls+=1;lock.unlock()
        entered.signal();precondition(release.wait(timeout:.now()+5) == .success)
    }
    var count:Int {lock.lock();defer{lock.unlock()};return calls}
}
@main struct Check {
    @MainActor static func main() async {
        let state=State(),pump=NativeReportPump(work:{state.work()})
        pump.request()
        // This main-actor task completes while native reporting remains blocked.
        for _ in 0..<100 {pump.request()}
        for _ in 0..<1000 where state.count==0 {try? await Task.sleep(nanoseconds:1_000_000)}
        precondition(state.count==1)
        var uiRan=false
        await Task { @MainActor in uiRan=true }.value
        precondition(uiRan && state.count==1)
        state.release.signal()
        // Let the completion hop clear admission, without assuming a sleep is
        // enough to prove completion. Re-request until a second work item starts.
        for _ in 0..<1000 {
            await Task.yield();pump.request()
            if state.count==2 {break}
            try? await Task.sleep(nanoseconds:1_000_000)
        }
        precondition(state.count==2);state.release.signal()
        print("PASS native diagnostic reports: one utility worker, duplicate coalescing, main-actor responsiveness and later readmission")
    }
}

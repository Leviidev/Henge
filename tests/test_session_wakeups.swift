import Foundation

actor Counts {
    var value = 0
    func add() { value += 1 }
}
@main struct Check {
    static func main() async {
        let wakeups = SessionWakeups(), counts = Counts()
        // Pending events coalesce and survive registration order.
        for _ in 0..<100 { wakeups.signal() }
        await wakeups.wait()
        // Cancellation must release a no-deadline waiter promptly, including
        // cancellation before the continuation is installed.
        for _ in 0..<1000 {
            let task = Task { await wakeups.wait(); await counts.add() }
            task.cancel()
            await task.value
        }
        let cancelledCount = await counts.value
        precondition(cancelledCount == 1000)
        // Signals, zero-deadline timers and cancellation race for one resume.
        for _ in 0..<1000 {
            let task = Task { await wakeups.wait(seconds: 0); await counts.add() }
            wakeups.signal()
            task.cancel()
            await task.value
        }
        let racedCount = await counts.value
        precondition(racedCount == 2000)
        // Old cancelled timeout work cannot consume a later wait's continuation.
        for _ in 0..<100 {
            let task = Task { await wakeups.wait(seconds: 60) }
            wakeups.signal(); await task.value
        }
        let final = Task { await wakeups.wait(); await counts.add() }
        wakeups.signal(); await final.value
        let finalCount = await counts.value
        precondition(finalCount == 2001)
        print("session wakeups: coalescing, cancellation and timer/signal races passed")
    }
}

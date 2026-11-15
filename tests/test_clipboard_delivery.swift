import Foundation
@main struct Check {
    @MainActor static func main() async {
        var ticks=0
        let delayed=await ClipboardDelivery.wait(isCurrent:{true},isDelivered:{ticks>=7},attempts:10,sleep:{ticks+=1})
        precondition(delayed == .delivered && ticks==7)
        ticks=0
        let interrupted=await ClipboardDelivery.wait(isCurrent:{ticks<3},isDelivered:{ticks>=5},attempts:10,sleep:{ticks+=1})
        precondition(interrupted == .interrupted && ticks==3)
        ticks=0
        let timeout=await ClipboardDelivery.wait(isCurrent:{true},isDelivered:{false},attempts:4,sleep:{ticks+=1})
        precondition(timeout == .timedOut && ticks==4)
        let cancelled=await ClipboardDelivery.wait(isCurrent:{true},isDelivered:{false},sleep:{throw CancellationError()})
        precondition(cancelled == .interrupted)
        let task=Task { @MainActor in await ClipboardDelivery.wait(isCurrent:{true},isDelivered:{true}) }
        task.cancel();let result=await task.value;precondition(result == .interrupted)
        print("Clipboard delivery: acknowledgement latency, lifecycle change, timeout and cancellation passed")
    }
}

import Foundation

/// One cancellable maintenance wait. Signals coalesce and retain no VM memory.
/// Deadlines exist only for visible diagnostics/startup or useful maintenance.
final class SessionWakeups: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>, timeout: DispatchWorkItem?)?

    func signal() {
        lock.lock()
        let current = waiter
        waiter = nil
        if current == nil { pending = true }
        lock.unlock()
        current?.timeout?.cancel()
        current?.continuation.resume()
    }

    private func finish(_ id: UUID) {
        lock.lock()
        let current = waiter?.id == id ? waiter : nil
        if current != nil { waiter = nil }
        lock.unlock()
        current?.timeout?.cancel()
        current?.continuation.resume()
    }

    func wait(seconds: Double? = nil) async {
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if pending || Task.isCancelled {
                    pending = false
                    lock.unlock()
                    continuation.resume()
                    return
                }
                precondition(waiter == nil, "A session has one maintenance waiter")
                let timeout = seconds.map { _ in DispatchWorkItem { [weak self] in self?.finish(id) } }
                waiter = (id, continuation, timeout)
                if let seconds, let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, seconds), execute: timeout)
                }
                lock.unlock()
            }
        }, onCancel: { self.finish(id) })
    }
}

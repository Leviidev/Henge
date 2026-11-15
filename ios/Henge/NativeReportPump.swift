import Foundation

/// The UI only enqueues. One utility worker owns native log formatting/locks;
/// simultaneous capture and maintenance requests share one outstanding report.
@MainActor
final class NativeReportPump {
    private let queue = DispatchQueue(label: "henge.diagnostics.reports", qos: .utility)
    private let work: @Sendable () -> Void
    private var pending = false

    init(work: @escaping @Sendable () -> Void) { self.work = work }

    func request() {
        guard !pending else { return }
        pending = true
        let work = self.work
        queue.async { [weak self] in
            work()
            Task { @MainActor in self?.pending = false }
        }
    }
}

import Foundation

/// This singleton callback never enters the native bridge while it holds locks.
/// A coalesced main-queue event lets the current session read the final state.
enum SessionNativeEvents {
    static let changed = Notification.Name("henge.vm.stateChanged")
    private static let events: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(queue: .main)
        source.setEventHandler { NotificationCenter.default.post(name: changed, object: nil) }
        source.resume()
        return source
    }()
    static func start() {
        _ = events
        henge_vm_set_state_notify { SessionNativeEvents.events.add(data: 1) }
    }
}

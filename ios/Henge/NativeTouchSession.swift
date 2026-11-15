import Foundation
import Observation

/// Negotiates the optional guest companion. Trackpad remains the default and fallback.
@MainActor @Observable
final class NativeTouchSession {
    var requested = false {
        didSet { defaults.set(requested, forKey: Self.preferenceKey) }
    }
    private(set) var ready = false
    private(set) var status: Int32 = 0
    private static let preferenceKey = "nativeTouchRequested"
    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private var attempted = false
    private var wasActive = false
    private var retryAfter: TimeInterval?
    private var retryCount = 0
    private var readySince: TimeInterval?
    private var pollingID: UUID?
    private var hadCompanion = false

    func beginPolling() -> UUID {
        let id = UUID()
        pollingID = id
        return id
    }

    func endPolling(_ id: UUID) {
        guard pollingID == id else { return }
        pollingID = nil
        stop()
    }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.now = now
        requested = defaults.bool(forKey: Self.preferenceKey)
    }

    func changedRequest() {
        stop()
        status = 0
    }

    func poll(active: Bool, helperRunning: Bool) {
        let wantsInput = requested && active
        if !wantsInput {
            if wasActive { stop() }
            wasActive = false
            return
        }
        wasActive = true
        if status == 8 {
            // Clipboard traffic alone cannot prove the USB companion is
            // running. Stop repeating30-second negotiations with an absent
            // companion; actual companion traffic restarts setup immediately.
            guard hv_native_touch_helper_alive() != 0 else { return }
            attempted=false;status=1;hadCompanion=true
        }
        // Booting the guest can take much longer than the negotiation timeout.
        guard helperRunning else {
            // Sharing presence bootstraps setup. Once direct USB is mapped,
            // its epoch/liveness watchdog is authoritative through a short stall.
            if attempted && hv_native_touch_direct_mapping() != 0 {
                status=hv_native_touch_status();ready=status==2;return
            }
            if attempted { stop() }
            wasActive = true
            status = 1
            return
        }
        if let retryAfter {
            guard now() >= retryAfter else { return }
            self.retryAfter = nil
            attempted = false
        }
        if !attempted {
            attempted = true
            hv_native_touch_enable(1)
        }
        status = hv_native_touch_status()
        let companionAlive = hv_native_touch_helper_alive() != 0
        hadCompanion = hadCompanion || companionAlive || status == 2 || status == 7
        if status == 6 && !hadCompanion && !companionAlive {
            status=8;ready=false;retryAfter=nil;return
        }
        ready = status == 2
        if ready {
            if readySince == nil { readySince=now() }
            if now()-(readySince ?? now())>=10 { retryCount=0 }
        } else { readySince=nil }
        // Transport timeouts and device/display reattachment are recoverable.
        // Unsupported OS and permission failures remain explicit, without loops.
        if status == 6 || status == 5 {
            let base:TimeInterval = status == 6 ? 2 : 5
            retryAfter=now()+min(30,base*Double(1 << min(retryCount,4)))
            retryCount=min(retryCount+1,5)
        }
    }

    func stop() {
        hv_native_touch_enable(0)
        ready = false
        attempted = false
        wasActive = false
        retryAfter = nil
        retryCount=0;readySince=nil
        hadCompanion=false
    }
}

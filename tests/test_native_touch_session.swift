import Foundation

@main enum NativeTouchSessionTests {
    @MainActor static func main() {
        let suite = "NativeTouchSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var time: TimeInterval = 0
        let session = NativeTouchSession(defaults: defaults, now: { time })
        session.poll(active: true, helperRunning: true)
        precondition(!session.ready && hv_native_touch_status() == 0)
        session.requested = true
        precondition(NativeTouchSession(defaults: defaults).requested, "The choice must survive a new session")
        session.changedRequest()
        session.poll(active: true, helperRunning: false)
        precondition(session.status == 1 && hv_native_touch_status() == 0, "Wait for the guest helper before negotiating")
        session.poll(active: true, helperRunning: true)
        precondition(session.status == 1 && !session.ready)
        let first = hv_native_touch_epoch()
        hv_native_touch_report(first, 2)
        session.poll(active: true, helperRunning: true)
        precondition(session.ready)
        session.poll(active: false, helperRunning: true)
        precondition(!session.ready && hv_native_touch_status() == 0)
        session.poll(active: true, helperRunning: true)
        precondition(hv_native_touch_epoch() != first)
        hv_native_touch_report(hv_native_touch_epoch(), 4)
        session.poll(active: true, helperRunning: true)
        precondition(!session.ready && session.status == 4)
        let failed = hv_native_touch_epoch()
        time = 100
        session.poll(active: true, helperRunning: true)
        precondition(hv_native_touch_epoch() == failed, "Failures must not cause a retry loop")
        session.requested = false
        precondition(!NativeTouchSession(defaults: defaults).requested, "Disabling native touch must also persist")
        session.changedRequest()
        session.poll(active: true, helperRunning: true)
        precondition(!session.ready && session.status == 0)
        session.requested = true
        session.changedRequest()
        session.poll(active: true, helperRunning: true)
        hv_native_touch_report(hv_native_touch_epoch(), 2)
        session.poll(active: true, helperRunning: true)
        precondition(session.ready)

        // Exercise the real transport watchdog; advance only the reconnect delay.
        Thread.sleep(forTimeInterval: 0.8)
        session.poll(active: true, helperRunning: true)
        precondition(!session.ready && session.status == 6)
        let timedOut = hv_native_touch_epoch()
        time += 1.9
        session.poll(active: true, helperRunning: true)
        precondition(session.status == 6 && hv_native_touch_epoch() == timedOut, "Retries need a backoff")
        time += 0.2
        session.poll(active: true, helperRunning: true)
        precondition(session.status == 1 && hv_native_touch_epoch() != timedOut, "A timeout must reconnect without toggling")
        hv_native_touch_report(hv_native_touch_epoch(), 2)
        session.poll(active: true, helperRunning: true)
        precondition(session.ready)
        session.poll(active: true, helperRunning: false)
        precondition(!session.ready && hv_native_touch_status() == 0, "Losing the helper must release native input")
        session.poll(active: true, helperRunning: true)
        precondition(session.status == 1)
        session.stop()
        precondition(!session.ready && hv_native_touch_status() == 0)
        precondition(NativeTouchSession(defaults: defaults).requested, "Stopping must preserve the choice")
        session.poll(active: true, helperRunning: true)
        hv_native_touch_report(hv_native_touch_epoch(), 5)
        session.poll(active: true, helperRunning: true)
        let failedDevice = hv_native_touch_epoch()
        time += 4.9
        session.poll(active: true, helperRunning: true)
        precondition(hv_native_touch_epoch() == failedDevice, "Device errors need a backoff")
        time += 0.2
        session.poll(active: true, helperRunning: true)
        precondition(hv_native_touch_epoch() != failedDevice && session.status == 1,
                     "Reattaching a USB display must recover without changing the setting")
        session.stop()
        let older = session.beginPolling()
        let newer = session.beginPolling()
        session.poll(active: true, helperRunning: true)
        let epoch = hv_native_touch_epoch()
        session.endPolling(older)
        precondition(hv_native_touch_epoch() == epoch && hv_native_touch_status() == 1,
                     "An old task's cancellation cannot stop a newer polling owner")
        session.endPolling(newer)
        precondition(hv_native_touch_status() == 0)
        session.stop()
        session.poll(active:true,helperRunning:true)
        for delay in [5.0,10.0,20.0,30.0,30.0] {
            hv_native_touch_report(hv_native_touch_epoch(),5)
            session.poll(active:true,helperRunning:true)
            let failedEpoch=hv_native_touch_epoch()
            time += delay-0.1
            session.poll(active:true,helperRunning:true)
            precondition(hv_native_touch_epoch()==failedEpoch,"Repeated failures must back off")
            time += 0.2
            session.poll(active:true,helperRunning:true)
            precondition(hv_native_touch_epoch() != failedEpoch,"Bounded retry must still recover")
        }
        hv_native_touch_report(hv_native_touch_epoch(),2)
        session.poll(active:true,helperRunning:true)
        time += 11
        hv_native_touch_report(hv_native_touch_epoch(),2)
        session.poll(active:true,helperRunning:true)
        hv_native_touch_report(hv_native_touch_epoch(),5)
        session.poll(active:true,helperRunning:true)
        let stableEpoch=hv_native_touch_epoch()
        time += 5.1;session.poll(active:true,helperRunning:true)
        precondition(hv_native_touch_epoch() != stableEpoch,"Stable readiness resets retry backoff")
        session.stop()
        let absent = NativeTouchSession(defaults: defaults, now: { time })
        absent.requested=true;absent.changedRequest();absent.poll(active:true,helperRunning:true)
        // The real no-USB setup watchdog is5seconds; this is a timeout test,
        // not a delay added to the product's recovery path.
        Thread.sleep(forTimeInterval:5.1)
        absent.poll(active:true,helperRunning:true)
        precondition(!absent.ready&&absent.status==8,"Clipboard presence must not masquerade as a running USB companion")
        let missingEpoch=hv_native_touch_epoch();time += 60
        absent.poll(active:true,helperRunning:true)
        precondition(absent.status==8&&hv_native_touch_epoch()==missingEpoch,"An absent companion must not cause repeated setup loops")
        var hello=[CChar](repeating:0,count:1024)
        hello.withUnsafeMutableBufferPointer { precondition(hv_native_touch_next($0.baseAddress,$0.count)>0) }
        absent.poll(active:true,helperRunning:true)
        precondition(absent.status==1&&hv_native_touch_epoch() != missingEpoch,"Actual companion traffic restarts setup without a toggle")
        hv_native_touch_report(hv_native_touch_epoch(),2);absent.poll(active:true,helperRunning:true)
        precondition(absent.ready);absent.stop()
        print("native touch session: persistence, delayed helper, suspend, fallback and automatic retry passed")
        print("PASS touch companion recovery: absent-helper readiness, no repeated setup loop, real arrival and existing runtime timeout retry")
    }
}

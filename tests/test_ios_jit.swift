import Foundation
import JavaScriptCore
import SwiftUI
import UIKit

@main
struct IOSJITTests {
    @MainActor static func main() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--stik-script") {
            let script = try String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8)
            try checkScript(script, expectedProbe: "P0=E0000069;thread:1;")
        }
        if CommandLine.arguments.contains("--external-launch") {
            try await checkExternalLaunch()
            return
        }
        // This reproduces the screenshot: CS_DEBUGGED is set, but nobody
        // answers traps. Displaying On or allowing an install here is wrong.
        henge_test_debugged(true)
        precondition(JITBootstrap.debuggedFlag)
        precondition(!JITBootstrap.ready)
        precondition(!JITBootstrap.prewarm())
        precondition(!JITBootstrap.ready && !JITBootstrap.isLive)

        let jit = JITCoordinator.shared
        jit.method = .stikDebug
        // Reproduce build 4's device regression: no scene-phase callback,
        // and a visible app whose UIKit state has not become active.
        UIApplication.shared.applicationState = .inactive
        precondition(!jit.ready)
        // A manual request takes over the passive app-list watcher.
        jit.monitorExternalJIT()
        jit.monitorExternalJIT()
        precondition(!jit.busy && UIApplication.shared.openedURLs.isEmpty)
        let probesBeforeHandoff = henge_test_probe_count()
        jit.enable()
        precondition(jit.busy && !jit.ready && jit.attachGeneration == 0)
        precondition(UIApplication.shared.openedURLs.count == 1)
        let url = UIApplication.shared.openedURLs[0]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains { $0.name == "pid" && $0.value == String(getpid()) })
        let encoded = query.first { $0.name == "script-data" }!.value!
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let script = String(data: Data(base64Encoded: padded)!, encoding: .utf8)!
        try checkScript(script)

        // A stale flag can trigger a failed probe, but cannot report success.
        // A second tap must not issue a concurrent request.
        jit.enable()
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(henge_test_probe_count() >= probesBeforeHandoff)
        precondition(UIApplication.shared.openedURLs.count == 1)
        precondition(jit.busy && !jit.ready && jit.attachGeneration == 0)

        UIApplication.shared.applicationState = .background
        henge_test_debugged(false)
        let probesBeforeScript = henge_test_probe_count()
        if CommandLine.arguments.contains("--delayed-return") {
            // Model iOS suspending Henge while the user confirms the script.
            // No callbacks run during this interval, just as on a suspended app.
            simulateSuspension()
            precondition(jit.busy && jit.error == nil && jit.attachGeneration == 0)
        }
        UIApplication.shared.applicationState = .inactive
        // StikDebug can return to Henge before vAttach has set the flag.
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(jit.busy && !jit.ready && jit.attachGeneration == 0)
        precondition(henge_test_probe_count() == probesBeforeScript)
        henge_test_debugged(true)
        // Attachment can precede the script. This failed prewarm must not be
        // cached forever, and the UI must still not announce success.
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(jit.busy && !jit.ready && jit.attachGeneration == 0)
        guard henge_test_probe_count() > probesBeforeScript else {
            print("FAIL: explicit JIT request never prepares without active scene callbacks")
            exit(2)
        }

        // A trap responder can also fail the real allocation. Keep waiting for
        // a usable region rather than reporting success from the probe alone.
        henge_test_service_traps(true)
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(henge_test_allocation_count() > 0)
        precondition(jit.busy && !jit.ready && !JITBootstrap.isLive)
        henge_test_allow_allocation(true)
        try await Task.sleep(nanoseconds: 800_000_000)
        precondition(jit.ready && JITBootstrap.ready && JITBootstrap.isLive)
        precondition(!jit.busy && jit.error == nil && jit.attachGeneration == 1)
        precondition(henge_test_selftest_count() == 1)
        precondition(henge_test_detach_count() == 1)

        // The real allocator executed generated code through its RW/RX aliases.
        // Keep that region after detach, without another allocation or hand-off.
        let allocationCount = henge_test_allocation_count()
        precondition(!JITBootstrap.debuggedFlag)
        jit.scenePhaseChanged(.active)
        jit.enable()
        precondition(jit.ready && UIApplication.shared.openedURLs.count == 1)
        precondition(henge_test_allocation_count() == allocationCount)
        print("iOS JIT: missing lifecycle callbacks, inactive UIKit state, stale flag, allocation retry, execute self-test and detach checks passed")
    }

    private static func simulateSuspension() {
        Thread.sleep(forTimeInterval: 61)
    }

    @MainActor private static func checkExternalLaunch() async throws {
        UIApplication.shared.applicationState = .inactive
        henge_test_debugged(false)
        let jit = JITCoordinator.shared
        jit.method = .stikDebug
        jit.monitorExternalJIT()
        jit.monitorExternalJIT()
        precondition(!jit.busy && !jit.ready)
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(!jit.ready && UIApplication.shared.openedURLs.isEmpty)

        // The app list's flag can arrive before its assigned script starts.
        henge_test_debugged(true)
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(!jit.ready && !jit.busy && henge_test_probe_count() > 0)
        // universal.js writes the old byte-reversed probe value; the native
        // protocol intentionally accepts this as a serviced trap.
        henge_test_probe_value(0x690000E0)
        henge_test_service_traps(true)
        henge_test_allow_allocation(true)
        try await Task.sleep(nanoseconds: 800_000_000)
        precondition(jit.ready && JITBootstrap.isLive && !jit.busy)
        precondition(jit.attachGeneration == 1)
        precondition(UIApplication.shared.openedURLs.isEmpty)
        precondition(henge_test_selftest_count() == 1 && henge_test_detach_count() == 1)
        let allocations = henge_test_allocation_count()
        jit.monitorExternalJIT()
        precondition(henge_test_allocation_count() == allocations)
        print("iOS JIT: direct external launch prepares and tests the region without a second URL or button press")
    }

    static func checkScript(_ script: String, expectedProbe: String = "P0=690000e000000000;thread:1;") throws {
        for integerBridge in [false, true] {
            let context = JSContext()!
            var failure: String?
            var preparedRegions: [[Double]] = []
            context.exceptionHandler = { _, value in failure = value?.toString() }
            // Match StikJIT's real JavaScriptCore bridge, including BigInt conversion.
            let prepare: @convention(block) (Double, Double) -> String = { address, length in
                preparedRegions.append([address, length])
                return "OK"
            }
            let prepareInteger: @convention(block) (UInt64, UInt64) -> String = { address, length in
                preparedRegions.append([Double(address), Double(length)])
                return "OK"
            }
            if integerBridge { // StikDebug 3.2.1
                context.setObject(prepareInteger, forKeyedSubscript: "prepare_memory_region" as NSString)
            } else { // Built-in StikJIT
                context.setObject(prepare, forKeyedSubscript: "prepare_memory_region" as NSString)
            }
            context.evaluateScript("""
                let writes = [], stops = 0;
                function get_pid() { return 123; }
                function log() {}
                function send_command(command) {
                    if (command === 'c') {
                        ++stops;
                        if (stops > 3) throw new Error('The JIT script did not detach');
                        const commandRegister = stops === 2 ? '01' : '00';
                        return 'T05thread:1;20:0010000000000000;10:' + commandRegister
                            + '00000000000000;00:0000000000000000;01:0040000000000000;';
                    }
                    if (command === 'm1000,4') return stops === 1 ? '200d20d4' : 'a0013ed4';
                    if (command === '_M4000,rx') return '200000000';
                    if (command.startsWith('P0=')) writes.push(command);
                    return 'OK';
                }
                """)
            context.evaluateScript(script)
            precondition(failure == nil, failure ?? "")
            let writes = context.evaluateScript("writes")!.toArray() as! [String]
            precondition(writes == [expectedProbe, "P0=0000000002000000;thread:1;"])
            precondition(preparedRegions == [[Double(0x200000000), Double(0x4000)]])
        }
    }
}

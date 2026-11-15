import Foundation

/// Engine settings, without a rebuild. Defaults below, then the Performance settings,
/// then Documents/henge-env.txt overrides performance settings. Enabled session diagnostics owns instrumentation flags.
/// Applied at launch and again before each Mac starts, so changes need no relaunch.
enum EngineTuning {
    private static let applyLock = NSLock()
    private static var appliedKeys = Set<String>()
    static let fastmemKey = "henge.perf.fastmem"
    static let refreshKey = "henge.perf.hz"
    static let fastFlushKey = "henge.perf.fastFlush"
    static let graphicsBackendKey = "henge.perf.graphicsBackend"
    static let lowPowerGuestRefreshKey = "henge.perf.lowPowerGuestRefresh"
    static var diagnosticsEnabled: Bool {
        let stats = getenv("HV_STATS").flatMap { Int(String(cString: $0)) } ?? 0
        return stats > 0 || getenv("HV_FASTMEM_STATS").map { String(cString: $0) == "1" } == true
            || getenv("HV_GPU_TIMING").map { String(cString: $0) == "1" } == true
    }

    static let defaults: [String: String] = [
        // Default to60Hz; users retain120Hz. Higher guest animation cadence can
        // increase emulation/replay work; it does not halve app CPU time universally.
        "HV_HZ": "60",         // the refresh rate macOS is told its display has
        "HV_WFI_SPIN": "0",    // microseconds an idle CPU watches for work before sleeping
        "HV_FLUSH": "2",       // disk flush: F_BARRIERFSYNC, ordered but without a full fsync
        "HV_STW_WAIT": "1", // event-driven quiescence during global code flushes
        "HV_SYNC_WAIT": "1", // bounded sleep after short spin while awaiting CPU acknowledgement
        "HV_RECHECK": "1",    // exact same-page check before full memory helper at page tails
        "HV_STATS": "0",       // diagnostic counters/timing are opt-in on every host
        "HV_CPU_POLICY": "auto", // responsive vCPUs; utility QoS for noncritical housekeeping
        "HV_TIMER_DIRECT": "1", // timer register writes update the local timer directly
        "HV_DEADLINE_KICKS": "1", // preserve CPU0 I/O polling; secondary CPUs need only due timers
    ]

    static func apply() {
        applyLock.lock(); defer { applyLock.unlock() }
        var env = defaults
        env["HV_FASTMEM"] = (UserDefaults.standard.object(forKey:fastmemKey) as? Bool ?? true) ? "1" : "0"
        let d = UserDefaults.standard
        env["HV_METAL4_OFF"] = d.string(forKey: graphicsBackendKey) == "compatibility" ? "1" : "0"
        env["HV_STATS"] = M4Performance.statisticsEnabled ? "10" : "0"
        // Removed UI experiments do not keep silently overriding Automatic.
        // Save the user's old choices once for recovery, then retire the keys.
        let migrationKey = "henge.perf.retiredExperiments.v1"
        if d.object(forKey:migrationKey) == nil {
            let retired = ["henge.perf.cpuPolicy", "henge.perf.wfiSpin", "henge.perf.superblocks",
                           "henge.perf.groupedMemory", "henge.perf.cacheDiagnostics"]
            var previous = [String:Any]()
            for key in retired {
                if let value = d.object(forKey:key) { previous[key] = value }
                d.removeObject(forKey:key)
            }
            d.set(previous,forKey:migrationKey)
            for key in ["henge.runner.repository","henge.runner.name","henge.runner.mac",
                        "henge.runner.background","henge.runner.cpuBackground"] { d.removeObject(forKey:key) }
            HengeLog.log("tuning","Removed Runner mode and retired experimental UI overrides; Automatic restored. Explicit henge-env.txt overrides remain available.")
        }
        env["HV_FASTMEM_STATS"] = M4Performance.statisticsEnabled ? "1" : "0"
        if [30, 60, 120].contains(d.integer(forKey: refreshKey)) { env["HV_HZ"] = String(d.integer(forKey: refreshKey)) }
        if (d.object(forKey:lowPowerGuestRefreshKey) as? Bool ?? true), ProcessInfo.processInfo.isLowPowerModeEnabled,
           let requested = Int(env["HV_HZ"] ?? "60"), requested > 60 {
            env["HV_HZ"] = "60"
            HengeLog.log("power","Explicit Low Power guest session: requested=\(requested)Hz effective=60Hz; saved preference and Retina retained; next boot reevaluates; henge-env overrides remain authoritative")
        }
        env["HV_SUPERBLOCKS"] = "0"
        env["HV_GROUPS"] = "2" // bounded register reuse and checked stack spans; broad planner remains opt-in
        env["HV_GAMEPAD_PROFILE"] = d.string(forKey:"henge.gamepad.profile") == "ds4" ? "ds4" : "generic"
        if d.object(forKey: fastFlushKey) as? Bool == false { env["HV_FLUSH"] = "0" }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // GPU command trace: checks Documents/trace-on at most once per second while commands arrive.
        env["HV_PVG_TRACE_FILE"] = docs.appendingPathComponent("trace-on").path
        let url = docs.appendingPathComponent("henge-env.txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
                // {Documents} stands for this folder: its absolute path changes when Henge is reinstalled.
                env[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "{Documents}", with: docs.path)
            }
        }
        // An enabled diagnostic switch must actually instrument the session,
        // even if an old experiment file left diagnostic flags at zero.
        // CPU/memory/display/performance overrides retain their normal priority.
        if M4Performance.statisticsEnabled {
            env.merge(["HV_STATS":"10","HV_STATS_HASH":"0","HV_FASTMEM_STATS":"1",
                       "HV_GPU_TIMING":"1","HV_FRAME_STATS":"1","HV_BLK_STATS":"10",
                       "HV_PROF_IOS":"2","HV_PROF_IOS_HZ":"50","HV_PROF_IOS_SECS":"30",
                       "HV_PROF_IOS_DURATION":"0"],uniquingKeysWith:{ _, profile in profile })
            HengeLog.log("diagnostics","Session diagnostics owns instrumentation flags for this run; active for the full session,50Hz hot-code samples,10s engine/I/O reports. Generated counters and sampling add overhead. Performance/display overrides remain unchanged.")
        }
        for key in appliedKeys.subtracting(env.keys) {
            unsetenv(key)
            HengeLog.log("tuning", "\(key)=<removed override>")
        }
        appliedKeys = Set(env.keys)
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            setenv(k, v, 1)
            HengeLog.log("tuning", "\(k)=\(v)")
        }
    }
}

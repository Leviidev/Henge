import Foundation

/// Engine settings, without a rebuild. Defaults below, then the Performance settings,
/// then Documents/henge-env.txt (KEY=VALUE per line, # comments; {Documents} in a value is that folder) overrides them all.
/// Applied at launch and again before each Mac starts, so changes need no relaunch.
enum EngineTuning {
    static let refreshKey = "henge.perf.hz"
    static let superblocksKey = "henge.perf.superblocks"
    static let wfiSpinKey = "henge.perf.wfiSpin"
    static let fastFlushKey = "henge.perf.fastFlush"
    static let profileKey = "henge.perf.profile"
    static let syncWaitKey = "henge.perf.syncWait"
    static let vblankKey = "henge.perf.vblank"
    static let windowKey = "henge.perf.el0window"
    static let linux3DKey = "henge.linux.3d"
    static let linuxGPUAsyncKey = "henge.linux.gpuAsync"

    static let defaults: [String: String] = [
        // 60, not 120: every frame macOS draws is emulated and replayed, so 120 Hz
        // halves the CPU left for apps for animation few will notice.
        "HV_HZ": "60",         // the refresh rate macOS is told its display has
        "HV_WFI_SPIN": "0",    // microseconds an idle CPU watches for work before sleeping
        "HV_FLUSH": "2",       // disk flush: F_BARRIERFSYNC, ordered but without a full fsync
        "HV_STATS": "10",      // seconds between engine stats lines in the log; 0 = off
    ]

    static func apply() {
        var env = defaults
        let d = UserDefaults.standard
        if [30, 120].contains(d.integer(forKey: refreshKey)) { env["HV_HZ"] = String(d.integer(forKey: refreshKey)) }
        if d.bool(forKey: superblocksKey) { env["HV_SUPERBLOCKS"] = "1" } else { unsetenv("HV_SUPERBLOCKS") }
        if d.bool(forKey: wfiSpinKey) { env["HV_WFI_SPIN"] = "50" }
        // The Mac's sound card gets an input stream only while the microphone setting is on (Microphone.swift).
        if Microphone.isOn { env["HV_MIC"] = "1" } else { unsetenv("HV_MIC") }
        if d.object(forKey: fastFlushKey) as? Bool == false { env["HV_FLUSH"] = "0" }
        // The engine's sampling profiler (host/prof_ios.c): where the CPU threads spend their time, in the log every 30 s.
        if d.bool(forKey: profileKey) { env["HV_PROF_IOS"] = "2" } else { unsetenv("HV_PROF_IOS") }
        // A Mac CPU waiting for another's answer to a TLB flush sleeps instead of spinning, so the one it waits for gets the core
        // (core/machine.c, HV_SYNC_WAIT). On unless switched off: the phone has fewer fast cores than the Mac has CPUs.
        if d.object(forKey: syncWaitKey) as? Bool == false { unsetenv("HV_SYNC_WAIT") } else { env["HV_SYNC_WAIT"] = "1" }
        // The display's refresh event, sent while macOS asks for it (devices/pvg_lite.c, HV_PVG_VBLANK). Without it WindowServer
        // times its frames with a timer that it finds late every time and re-arms at once: tens of thousands of wakeups a second.
        if d.bool(forKey: vblankKey) { env["HV_PVG_VBLANK"] = "1" } else { unsetenv("HV_PVG_VBLANK") } // off unless switched on: see devices/pvg_lite.c
        // Prototype (upstream PR #157, untested on a device): the Mac's user memory mapped straight into Henge, 16 GB a CPU,
        // so app code reads and writes it without the software TLB (core/window.c). Off unless switched on: on the phone (2026-11-13) its page faults took 60% of the CPU time and the Mac ran 5-10x slower.
        if d.bool(forKey: windowKey) { env["HV_EL0_WINDOW"] = "34" } else { unsetenv("HV_EL0_WINDOW") }
        // A Linux machine's 3D (virgl on ANGLE, devices/vgpu_virgl.c), when the app carries the GPU libraries. On unless switched off.
        if d.object(forKey: linux3DKey) as? Bool == false { env["HV_LINUX_NO_3D"] = "1" } else { unsetenv("HV_LINUX_NO_3D") }
        // Experimental: Linux's 3D work queued without its CPU waiting for the GPU (devices/vgpu_virgl.c). Off unless switched on.
        if d.bool(forKey: linuxGPUAsyncKey) { env["HV_VIRGL_ASYNC"] = "1" } else { unsetenv("HV_VIRGL_ASYNC") }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // GPU command trace: on while Documents/trace-on exists (it is checked every frame, so it can be toggled live).
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
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            setenv(k, v, 1)
            HengeLog.log("tuning", "\(k)=\(v)")
        }
    }
}

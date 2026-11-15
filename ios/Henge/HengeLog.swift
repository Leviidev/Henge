// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin
import UIKit
import os

/// Everything Henge knows, in one chronological file.
///
/// The problem this solves: QEMU and Henge's own C code write diagnostics with
/// `fprintf(stderr, ...)`, and on iOS stderr goes nowhere a user can reach. So
/// before anything else runs, stdout and stderr are redirected into a file that an event-driven
/// reader thread drains, writing every line to three places at once:
///
///   * `Documents/henge.log`, retrievable over the Files app or the share sheet
///   * `os_log`, so Console.app shows it live with the device attached
///   * an in-memory ring buffer the app can display without leaving the device
///
/// Because QEMU's output and Henge's Swift logging both land in the same stream,
/// the ordering between "the JIT region was allocated" and "QEMU started
/// translating" is preserved, which is exactly the ordering that matters when
/// something goes wrong.
enum HengeLog {
    private static let osLog = Logger(subsystem: "com.henge.app", category: "henge")

    /// Exposed because a C signal handler closure cannot capture context.
    fileprivate static var rawLogFD: Int32 { logFD }
    private static var logFD: Int32 = -1
    fileprivate static var pipeReadFD: Int32 = -1

    /// Scratch space for the crash handler, taken before it is needed.
    /// Nothing inside a signal handler may allocate.
    fileprivate static let crashBuf =
        UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 16)

    /// Frame pointers for the crash backtrace, taken before they are needed.
    fileprivate static let crashFrames =
        UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
    private static var pipeWriteFD: Int32 = -1
    private static var nativeTail: NativeLogTail?
    /// HV_LOG_CONSOLE: a copy of the original stderr, so `devicectl device process launch --console` (and Xcode's
    /// console) can follow the log live. `colorprobe` (any text) mirrors only lines containing it; `all` mirrors everything.
    private static var consoleFD: Int32 = -1
    private static var consoleFilter: String?
    private static var started = false
    private static var powerObserver: NSObjectProtocol?
    private static let writeLock = NSLock()
    private static let startTime = Date()

    /// Recent lines, for the in-app viewer. Bounded so a long session cannot grow
    /// without limit.
    private static let ringLimit = 4000
    private static var ring: [String] = []
    private static let ringLock = NSLock()

    static var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("henge.log")
    }

    /// Include the terminated session after a relaunch, not just the new
    /// startup log. Profiler output is append-only and carries a PID per dump.
    static var diagnosticFileURLs: [URL] {
        let directory = logFileURL.deletingLastPathComponent()
        return ["henge.log", "henge-native.log", "henge-prev.log",
                "henge-native-prev.log", "hvprof-words.txt"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func recentLines(_ n: Int = 400) -> [String] {
        ringLock.lock(); defer { ringLock.unlock() }
        return Array(ring.suffix(n))
    }

    // MARK: - Startup

    static func start() {
        guard !started else { return }
        started = true

        // A write to a pipe whose read end has closed raises SIGPIPE, and the
        // default action for SIGPIPE is to terminate the process. Since stdout and
        // stderr are about to become that pipe, ignore it outright -- a logging
        // failure must never be able to kill the app it is trying to diagnose.
        signal(SIGPIPE, SIG_IGN)

        // Fresh file each launch. StikDebug relaunches us after attaching, so the
        // run that matters is always the most recent one; keeping the previous
        // run's noise would make the log harder to read, not easier.
        // ...but the previous run is kept as henge-prev.log, because when a game took Henge down with it, that run's log is
        // the crash report (CrashReport.swift).
        let url = logFileURL
        let prev = url.deletingLastPathComponent().appendingPathComponent("henge-prev.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
        logFD = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)

        redirectStdio()
        installCrashHandlers()
        logBanner()
        replayPreviousNativeLog()
        logPowerState("app-launch")
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil) { _ in logPowerState("power-state-changed") }
    }

    private static func logPowerState(_ reason: String) {
        let process = ProcessInfo.processInfo
        log("power", "\(reason): low-power=\(process.isLowPowerModeEnabled ? "on" : "off") thermal-category=\(process.thermalState.rawValue) (OS policy/category; not watts or temperature)")
    }

    /// Put the last run's native output into this run's log.
    ///
    /// When QEMU aborts, its reason lands in henge-native.log and the process is
    /// gone before anything mirrors it -- and that file was not in the share
    /// sheet either, so the one artefact explaining a crash was the one nobody
    /// could retrieve. Replaying it here puts it in henge.log, which is the file
    /// people already know how to send.
    private static func replayPreviousNativeLog() {
        guard let data = try? Data(contentsOf: previousNativeLogURL),
              !data.isEmpty,
              let text = String(data: data.suffix(8 * 1024), encoding: .utf8)
        else { return }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(40)
        guard !lines.isEmpty else { return }
        log("prev", "---- last \(lines.count) lines from the previous run "
                  + "(the one that may have crashed) ----")
        for line in lines { log("prev", String(line)) }
        log("prev", "---- end of the previous run ----")
    }

    /// QEMU's own stderr, this run and the one before it.
    static var nativeLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("henge-native.log")
    }
    static var previousNativeLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("henge-native-prev.log")
    }

    /// Force everything out to disk.
    static func flushNow() {
        if logFD >= 0 { fsync(logFD) }
    }

    /// Point stdout and stderr at a pipe we drain ourselves.
    ///
    /// Uses raw pipe(2) descriptors held in statics rather than Foundation's Pipe.
    /// Pipe owns its FileHandles and closes their descriptors when it deallocates,
    /// so a locally-scoped Pipe tears down the read end the moment this function
    /// returns -- after which every write to stderr hits a reader-less pipe. These
    /// descriptors belong to no object and are never closed.
    /// A file, not a pipe.
    ///
    /// A pipe loses everything in it when the process dies: QEMU writes an
    /// assertion message, aborts before the reader thread is scheduled, and the
    /// log shows a fatal signal with nothing before it. A file cannot lose
    /// anything -- stderr is unbuffered, so every byte is on disk as it is
    /// written, whatever happens next.
    ///
    /// The previous run's copy is kept rather than overwritten, because the run
    /// that crashed is exactly the one worth reading, and it is replayed into
    /// the next run's henge.log by replayPreviousNativeLog().
    private static func redirectStdio() {
        let dir = FileManager.default.urls(for: .documentDirectory,
                                           in: .userDomainMask)[0]
        let cURL = dir.appendingPathComponent("henge-native.log")
        let prevURL = dir.appendingPathComponent("henge-native-prev.log")
        try? FileManager.default.removeItem(at: prevURL)
        try? FileManager.default.moveItem(at: cURL, to: prevURL)

        pipeWriteFD = open(cURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        pipeReadFD = open(cURL.path, O_RDONLY)
        guard pipeWriteFD >= 0, pipeReadFD >= 0 else {
            log("boot", "WARNING: could not open henge-native.log (errno \(errno)); "
                      + "C-side stderr will not be captured")
            return
        }
        log("boot", "native stderr -> henge-native.log (mirrored here)")

        if let mode = ProcessInfo.processInfo.environment["HV_LOG_CONSOLE"], !mode.isEmpty {
            consoleFD = dup(STDERR_FILENO)
            consoleFilter = (mode == "all" || mode == "1") ? nil : mode
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        dup2(pipeWriteFD, STDOUT_FILENO)
        dup2(pipeWriteFD, STDERR_FILENO)

        nativeTail = NativeLogTail(fd: pipeReadFD) { emit($0, fromStream: true) }
        log("boot", "native log mirror: filesystem write notifications, utility queue, no polling timer")
    }

    /// Turn "the app vanished with no crash log" into a labelled last line.
    ///
    /// Deliberately does NOT touch SIGTRAP or SIGBUS: those belong to the JIT trap
    /// guard in henge-ios-jit.c, which needs to step over an unserviced brk rather
    /// than treat it as fatal. Stealing them here would break JIT detection.
    /// SIGPIPE is already set to SIG_IGN in start() and must stay that way.
    private static func installCrashHandlers() {
        let fatal: [Int32] = [SIGSEGV, SIGABRT, SIGILL, SIGFPE, SIGSYS]
        for sig in fatal {
            signal(sig) { received in
                // Async-signal-safe only: write(2) straight to the fds, no
                // allocation, no locks, no Swift runtime.
                let msg = "\n*** FATAL SIGNAL \(received) -- process is dying ***\n"
                msg.withCString { p in
                    let n = strlen(p)
                    if HengeLog.rawLogFD >= 0 { _ = write(HengeLog.rawLogFD, p, n) }
                }
                // Drain whatever C wrote but the reader thread never got to.
                //
                // QEMU's own abort messages -- assertion text, error_report --
                // go to stderr, which is a pipe read by a thread. When the
                // process aborts, that thread has usually not been scheduled
                // since the write, so the message dies in the pipe buffer and
                // the log shows the fatal signal with nothing before it. That
                // happened on the first virtio-sound boot and cost the whole
                // diagnosis: a correct command line, a device that exists, and
                // no reason given.
                //
                // read(2) and write(2) are async-signal-safe; the non-blocking
                // flag is what stops this hanging when the pipe is empty.
                if HengeLog.pipeReadFD >= 0 {
                    // Reading a file now, so this cannot block and cannot
                    // miss anything: whatever the tailer has not reached is
                    // still on disk at this descriptor's offset.
                    // A buffer allocated up front, because this one did not
                    // work: creating an array here allocates, and abort() can
                    // be raised while the allocator's lock is held -- so the
                    // drain deadlocked inside malloc and took the fsync with
                    // it. The marker was written and nothing after it, which
                    // looked exactly like "QEMU printed nothing".
                    while true {
                        let n = read(HengeLog.pipeReadFD, HengeLog.crashBuf, 8192)
                        if n <= 0 { break }
                        if HengeLog.rawLogFD >= 0 {
                            _ = write(HengeLog.rawLogFD, HengeLog.crashBuf, n)
                        }
                    }
                }
                // Where it died.
                //
                // Six months of "FATAL SIGNAL 11" with no frames is six months
                // of guessing which of QEMU, ANGLE, the audio ring or our own
                // Swift was at fault. backtrace_symbols_fd is documented
                // async-signal-safe and writes straight to a descriptor, which
                // is the only reason it can be used here -- and the frame
                // buffer is taken at startup because nothing in a signal
                // handler may allocate.
                if HengeLog.rawLogFD >= 0 {
                    let header = "\n--- backtrace ---\n"
                    header.withCString { p in
                        _ = write(HengeLog.rawLogFD, p, strlen(p))
                    }
                    let n = backtrace(HengeLog.crashFrames, 64)
                    backtrace_symbols_fd(HengeLog.crashFrames, n, HengeLog.rawLogFD)
                }
                if HengeLog.rawLogFD >= 0 { fsync(HengeLog.rawLogFD) }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
        NSSetUncaughtExceptionHandler { ex in
            HengeLog.log("crash", "uncaught exception: \(ex.name.rawValue) -- \(ex.reason ?? "")")
            HengeLog.log("crash", ex.callStackSymbols.prefix(20).joined(separator: " | "))
            HengeLog.flushNow()
        }
        log("boot", "crash handlers installed (SEGV/ABRT/ILL/FPE/SYS; "
                  + "TRAP+BUS left to the JIT guard; SIGPIPE ignored)")
    }

    // MARK: - Emitting

    /// - Parameter fromStream: true when the line came out of the captured pipe,
    ///   meaning the C side already sent it to os_log itself.
    private static func emit(_ line: String, fromStream: Bool) {
        ringLock.lock()
        ring.append(line)
        if ring.count > ringLimit { ring.removeFirst(ring.count - ringLimit) }
        ringLock.unlock()

        // The C side (henge-ios-jit.c, henge-display.c) writes to os_log itself as
        // well as stderr, because those are the lines most worth surviving a hard
        // crash. Mirroring them again here would double every one of them in
        // Console.app.
        if !fromStream || (!line.contains("[henge-jit]") && !line.contains("[henge-dpy]")) {
            osLog.log("\(line, privacy: .public)")
        }

        if consoleFD >= 0, consoleFilter == nil || line.contains(consoleFilter!),
           let console = (line + "\n").data(using: .utf8) {
            console.withUnsafeBytes { raw in _ = write(consoleFD, raw.baseAddress, raw.count) }
        }

        // Written synchronously with write(2) rather than queued. An async write
        // can still be pending when the process dies, which loses exactly the
        // lines that explain why it died -- and those are the whole point of this
        // file. write(2) to a file lands in the page cache and is cheap.
        guard logFD >= 0, let data = (line + "\n").data(using: .utf8) else { return }
        writeLock.lock()
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(logFD, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
        writeLock.unlock()
    }

    /// Log from Swift. Lands in the same stream as QEMU's own output.
    static func log(_ category: String, _ message: String) {
        let t = Date().timeIntervalSince(startTime) * 1000
        emit(String(format: "[%9.2fms][%@] %@", t, category, message), fromStream: false)
    }

    // MARK: - Context

    /// The hardware identifier, e.g. "iPhone18,1". Which JIT routes exist on
    /// this device is decided from it and the iOS version.
    static var deviceModel: String {
        var sysinfo = utsname(); uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func logBanner() {
        let d = UIDevice.current
        let model = deviceModel
        let mem = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)

        log("boot", "================ Henge starting ================")
        log("boot", "device      : \(model)")
        log("boot", "host chip   : \(HostScheduling.chip); cores \(HostScheduling.layout); source \(HostScheduling.layoutSource)")
        log("boot", "system      : \(d.systemName) \(d.systemVersion)")
        log("boot", "physical RAM: \(mem) MiB")
        log("boot", "processors  : \(ProcessInfo.processInfo.processorCount) "
                  + "(active \(ProcessInfo.processInfo.activeProcessorCount))")
        log("boot", "bundle      : \(Bundle.main.bundleIdentifier ?? "?")")
        // Which build this is, in the log itself.
        //
        // Without this a log cannot be told apart from one produced by an older
        // install, and a stale app on the phone reads exactly like a fix that
        // did not work -- which has now cost a debugging round trip. The commit
        // and date are stamped into Info.plist by package_ipa.sh.
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build   = info["CFBundleVersion"] as? String ?? "?"
        let commit  = info["HengeBuildCommit"] as? String ?? "unstamped"
        let built   = info["HengeBuildDate"] as? String ?? "?"
        log("boot", "build       : \(version) (\(build)) \(commit) built \(built)")
        if let upstream = info["HengeUpstreamCommit"] as? String {
            log("boot", "upstream main: \(upstream)")
        }
        log("boot", "performance revision: Duo-aware scheduling; inline EL1 TCR/PAR/PAN/TTBR/UAO; tagged multiwindow Fast Memory; checked RAM span reuse; deadline-aware secondary kicks; cursor damage/coalescing; pressure cache cleanup; full branch publication; grouped memory, superblocks and TLB preload experimental")
        log("boot", "Link protocol: 2, decoder-consumption credit window=3; local discovery and opt-in Keychain pairing; three-finger viewer controls; update both devices")
        log("boot", "cache lifecycle: JIT translations and kernel read lookups are RAM-only; no cross-launch executable cache")
        if let source = info["HengeCustomSourceCommit"] as? String {
            let prs = info["HengeCustomPullRequests"] as? [Int] ?? []
            log("boot", "custom source: \(source); PRs \(prs.map { String($0) }.joined(separator: ", "))")
        }
        log("boot", "pid         : \(getpid())")
        log("boot", "log file    : \(logFileURL.path)")
        // Every iOS 27 device except iPad8,11/8,12 enforces TXM, which is what makes
        // the debugger-assisted JIT path mandatory rather than optional.
        log("boot", "TXM expected: \(Self.expectsTXM(model: model) ? "YES" : "no")")
        log("boot", "===============================================")
    }

    static func expectsTXM(model: String) -> Bool {
        if #available(iOS 27.0, *) {
            return model != "iPad8,11" && model != "iPad8,12"
        }
        if #available(iOS 26.0, *) {
            // A14-era and newer: iPhone13,x is A14, so HW major >= 13 for phones.
            let digits = model.drop { !$0.isNumber }.prefix { $0.isNumber }
            if let major = Int(digits) {
                return model.hasPrefix("iPhone") ? major >= 13 : major >= 14
            }
        }
        return false
    }

    /// Snapshot of process memory, the figure jetsam kills on.
    static func logFootprint(_ tag: String) {
        henge_ios_jit_log_footprint(tag)
    }
}

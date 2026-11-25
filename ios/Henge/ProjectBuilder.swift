import CryptoKit
import Foundation

/// Builds a project prepared for the phone (tools/phone-kit) in Henge itself, without macOS: what changed is compiled,
/// the program is linked and packed as an unsigned IPA. `run` runs the kit's compiler or linker (henge_tl_tool_run).
/// Everything else comes ready-made in the kit. Pure Foundation, so the tests run it on a Mac.
final class ProjectBuilder {
    struct Unit: Codable {
        var src: String
        var obj: String
        var flags: Int
        /// Indexes into `files`: what it was compiled from when the kit was made. Empty: compile it.
        var deps: [Int]?
    }
    struct Plan: Codable {
        var name: String
        var flags: [[String]]
        var files: [String]
        var hashes: [String]
        var units: [Unit]
        var clang: String
        var ld: String
        var link: [String]
        var program: String
        var app: String
        var ipa: String
        var run: Run?
        // Of a project Claude described (ProjectMaker):
        var swift: Swift?
        /// Run first, one after another.
        var commands: [String]?
        /// What they made, to be the app's program.
        var made: String?
        /// Whether there is an app around the program (nil: yes).
        var bundle: Bool?
    }
    /// All Swift sources, compiled as one.
    struct Swift: Codable { var tool: String; var args: [String]; var obj: String; var deps: [String] }
    /// How the built program runs in Henge itself, without its window.
    struct Run: Codable {
        var entry: String
        /// Its home folder, and variables over the app's ("NAME=value").
        var home: String
        var env: [String]
        /// Files written before it starts.
        var files: [String: String]
        /// Where it takes commands, one JSON line each.
        var port: UInt16
        /// Files that must be there, and what to say when they are not.
        var needs: String
        var missing: String
    }
    private struct Seen: Codable { var size: Int; var time: Double; var hash: String }
    private struct Made: Codable { var deps: [String]; var hashes: [String]; var flags: String? }
    private struct State: Codable { var seen: [String: Seen] = [:]; var made: [String: Made] = [:]; var linked = "" }

    let root: URL
    typealias RunTool = (_ tool: String, _ args: [String], _ env: [String], _ cwd: String?) -> (code: Int32, output: String)
    let run: RunTool
    private let lock = NSLock()
    private var state = State()
    /// The shared toolchain, and how many compilers at once.
    var tools: URL?
    var lanes = 1
    /// A shell command in the project's folder.
    var shell: ((String) -> (code: Int32, output: String))?

    init(root: URL, run: @escaping RunTool) {
        self.root = root.resolvingSymlinksInPath()
        self.run = run
    }

    static func plan(in root: URL) throws -> Plan {
        try JSONDecoder().decode(Plan.self, from: Data(contentsOf: root.appendingPathComponent("henge-build.json")))
    }
    func full(_ path: String) -> String { path.hasPrefix("/") ? path : root.path + "/" + path }
    private func expand(_ arg: String) -> String { arg.replacingOccurrences(of: "$KIT", with: root.path) }
    /// Whether a folder is a project, described by Claude or made as a kit.
    static func isProject(_ root: URL) -> Bool {
        ["henge-build.json", ProjectMaker.file].contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    static func anyPlan(in root: URL, tools: URL?) throws -> Plan {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(ProjectMaker.file).path) {
            guard let tools else { throw ProjectMaker.Failure("no toolchain") }
            return try ProjectMaker.plan(root, tools: tools)
        }
        return try plan(in: root)
    }
    private var stateFile: URL { root.appendingPathComponent(".henge-build-state.json") }

    /// A file's hash; read again only when its size or date changed. Nil when it is not there.
    private func hash(_ path: String) -> String? {
        var st = stat()
        guard stat(full(path), &st) == 0 else { return nil }
        let time = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        if let s = state.seen[path], s.size == Int(st.st_size), s.time == time { return s.hash }
        guard let data = FileManager.default.contents(atPath: full(path)) else { return nil }
        let h = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        state.seen[path] = Seen(size: Int(st.st_size), time: time, hash: h)
        return h
    }

    /// The files a compiler's .d file names, those of the project only, relative to it.
    static func dependencies(_ text: String, root: String) -> [String] {
        var out: [String] = [], word = ""
        var it = text.replacingOccurrences(of: "\\\n", with: " ").makeIterator()
        func end() {
            if word.hasPrefix(root + "/") { out.append(String(word.dropFirst(root.count + 1))) }
            word = ""
        }
        while let c = it.next() {
            if c == "\\" { if let n = it.next() { word.append(n) } }
            else if c == " " || c == "\n" || c == "\t" { if word.hasSuffix(":") { word = "" } else { end() } }
            else { word.append(c) }
        }
        end()
        return out
    }

    /// The whole build; `progress` gets a line per step. Returns whether it worked and what to tell.
    func build(progress: (String) -> Void = { _ in }) -> (ok: Bool, text: String) {
        let began = Date()
        let plan: Plan
        do { plan = try Self.anyPlan(in: root, tools: tools) }
        catch let e as ProjectMaker.Failure { return (false, "BUILD FAILED: \(e.text)") }
        catch { return (false, "BUILD FAILED: henge-build.json cannot be read: \(error)") }
        if let d = try? Data(contentsOf: stateFile), let s = try? JSONDecoder().decode(State.self, from: d) { state = s }
        defer { if let d = try? JSONEncoder().encode(state) { try? d.write(to: stateFile) } }
        var log = "", compiled = 0, failed = 0
        for c in plan.commands ?? [] {
            progress(c)
            let r = shell?(c) ?? (code: 127, output: "no shell")
            if r.code != 0 { return (false, "BUILD FAILED: \(c): code \(r.code)\n" + Self.clip(r.output)) }
            log += Self.clip(r.output).suffix(1500)
        }
        var todo = [(Unit, String)]()
        let keys = plan.flags.map { $0.joined(separator: "\0").hashValueStable }
        for u in plan.units {
            let now: Bool
            if !FileManager.default.fileExists(atPath: full(u.obj)) { now = true }
            else if let m = state.made[u.obj] { now = m.flags.map { $0 != keys[u.flags] } ?? false || zip(m.deps, m.hashes).contains { hash($0) != $1 } }
            else if let d = u.deps, !d.isEmpty { now = d.contains { hash(plan.files[$0]) != plan.hashes[$0] } }
            else { now = true }
            if now { todo.append((u, keys[u.flags])) }
        }
        var next = 0
        func lane() {
            while true {
                lock.lock()
                guard failed < 5, next < todo.count else { lock.unlock(); return }
                let (u, key) = todo[next]
                next += 1
                progress("compiling \(u.src) (\(next) of \(todo.count))")
                lock.unlock()
                try? FileManager.default.createDirectory(atPath: (full(u.obj) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let d = full(u.obj) + ".d"
                let args = plan.flags[u.flags].map(expand) + ["-fintegrated-cc1", "-fno-color-diagnostics", "-MMD", "-MF", d, "-o", full(u.obj), "-c", full(u.src)]
                let r = run(full(plan.clang), args, [], nil)
                lock.lock()
                if !r.output.isEmpty { log += "\(u.src):\n" + r.output.replacingOccurrences(of: root.path + "/", with: "") + "\n" }
                if r.code != 0 {
                    failed += 1
                    log += "\(u.src): the compiler ended with \(r.code)\n"
                    state.made[u.obj] = nil
                    unlink(full(u.obj))
                } else {
                    compiled += 1
                    let deps = Self.dependencies((try? String(contentsOfFile: d, encoding: .utf8)) ?? "", root: root.path)
                    var seen = Set<String>()
                    let uniq = deps.filter { seen.insert($0).inserted }
                    state.made[u.obj] = Made(deps: uniq, hashes: uniq.map { hash($0) ?? "" }, flags: key)
                }
                unlink(d)
                lock.unlock()
            }
        }
        if lanes > 1 && todo.count > 1 { DispatchQueue.concurrentPerform(iterations: min(lanes, todo.count)) { _ in lane() } } else { lane() }
        if failed >= 5 { log += "Stopped after \(failed) files with errors.\n" }
        if failed == 0, let s = plan.swift {
            let key = s.args.joined(separator: "\0").hashValueStable
            let m = state.made[s.obj]
            if m == nil || m!.flags != key || m!.deps != s.deps || !FileManager.default.fileExists(atPath: full(s.obj)) || zip(s.deps, m!.hashes).contains(where: { hash($0) != $1 }) {
                progress("compiling \(s.deps.count) Swift file(s)")
                try? FileManager.default.createDirectory(atPath: (full(s.obj) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let r = run(s.tool, s.args.map(expand) + ["-o", full(s.obj)], [], nil)
                if !r.output.isEmpty { log += "Swift:\n" + r.output.replacingOccurrences(of: root.path + "/", with: "") + "\n" }
                if r.code != 0 { failed += 1; state.made[s.obj] = nil; log += "the Swift compiler ended with \(r.code)\n" }
                else { compiled += 1; state.made[s.obj] = Made(deps: s.deps, hashes: s.deps.map { hash($0) ?? "" }, flags: key) }
            }
        }
        func took() -> String { String(format: "%.1f s", Date().timeIntervalSince(began)) }
        if failed > 0 { return (false, "BUILD FAILED: \(failed) file(s) did not compile (\(took()))\n" + Self.clip(log)) }
        let program = full(plan.program), linkKey = plan.link.joined(separator: " ").hashValueStable
        if let made = plan.made {
            guard FileManager.default.fileExists(atPath: full(made)) else { return (false, "BUILD FAILED: the commands did not make \(made)\n" + Self.clip(log)) }
            try? FileManager.default.createDirectory(atPath: (program as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if full(made) != program {
                unlink(program)
                do { try FileManager.default.copyItem(atPath: full(made), toPath: program) } catch { return (false, "BUILD FAILED: \(error.localizedDescription)") }
            }
            chmod(program, 0o755)
        } else if plan.link.isEmpty {
            return (true, "BUILD OK in \(took()): the commands ran; no \"executable\" or \"sources\" to make an app of.\n" + Self.clip(log))
        } else if compiled > 0 || state.linked != linkKey || !FileManager.default.fileExists(atPath: program) {
            progress("linking")
            state.linked = ""
            try? FileManager.default.createDirectory(atPath: (program as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let r = run(full(plan.ld), plan.link.map(expand), [], nil)
            if !r.output.isEmpty { log += "link:\n" + r.output.replacingOccurrences(of: root.path + "/", with: "") + "\n" }
            if r.code != 0 { return (false, "BUILD FAILED: it did not link, code \(r.code) (\(took()))\n" + Self.clip(log)) }
            chmod(program, 0o755)
            state.linked = linkKey
        }
        if plan.bundle == false { return (true, "BUILD OK in \(took()): \(compiled) file(s) compiled, program at \(plan.program)\n" + Self.clip(log)) }
        progress("packing")
        do {
            if plan.bundle == true { try ProjectMaker.bundle(root, plan) }
            try StoredZip.pack(folder: full(plan.app), inside: "Payload/" + (plan.app as NSString).lastPathComponent, executable: program, to: full(plan.ipa))
        } catch let e as ProjectMaker.Failure { return (false, "BUILD FAILED: \(e.text)")
        } catch { return (false, "BUILD FAILED: the IPA could not be written: \(error.localizedDescription)") }
        return (true, "BUILD OK in \(took()): \(compiled) file(s) compiled, unsigned IPA at \(plan.ipa)\n" + Self.clip(log))
    }

    static func clip(_ s: String) -> String { s.count <= 12000 ? s : s.prefix(8000) + "\n…\n" + s.suffix(3500) }
}

private extension String {
    /// The same in every launch, unlike hashValue.
    var hashValueStable: String { SHA256.hash(data: Data(utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
}

/// An uncompressed zip with plain local headers, as signing apps on the phone want their IPAs.
enum StoredZip {
    private static let table: [[UInt32]] = {
        var t = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 8)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            t[0][i] = c
        }
        for i in 0..<256 { for k in 1..<8 { t[k][i] = (t[k - 1][i] >> 8) ^ t[0][Int(t[k - 1][i] & 255)] } }
        return t
    }()
    private static let flat: [UInt32] = table.flatMap { $0 }
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            flat.withUnsafeBufferPointer { t in
                var i = 0
                let n = p.count
                while i + 8 <= n {
                    let a = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt32.self)) ^ c
                    let b = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i + 4, as: UInt32.self))
                    let x = t[7 * 256 + Int(a & 255)] ^ t[6 * 256 + Int(a >> 8 & 255)] ^ t[5 * 256 + Int(a >> 16 & 255)] ^ t[4 * 256 + Int(a >> 24)]
                    let y = t[3 * 256 + Int(b & 255)] ^ t[2 * 256 + Int(b >> 8 & 255)] ^ t[256 + Int(b >> 16 & 255)] ^ t[Int(b >> 24)]
                    c = x ^ y
                    i += 8
                }
                while i < n { c = (c >> 8) ^ t[Int((c ^ UInt32(p[i])) & 255)]; i += 1 }
            }
        }
        return ~c
    }

    static func pack(folder: String, inside: String, executable: String, to out: String) throws {
        let fm = FileManager.default
        let part = out + ".part"
        guard fm.createFile(atPath: part, contents: nil), let f = FileHandle(forWritingAtPath: part) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? f.close() }
        var names = [String]()
        for case let n as String in fm.enumerator(atPath: folder) ?? FileManager.DirectoryEnumerator() { names.append(n) }
        names.sort()
        var central = Data(), at: UInt32 = 0, count: UInt16 = 0
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24)] }
        for n in [""] + names {
            var dir: ObjCBool = false
            let path = n.isEmpty ? folder : folder + "/" + n
            guard fm.fileExists(atPath: path, isDirectory: &dir), !n.hasSuffix(".DS_Store") else { continue }
            let name = Array((inside + (n.isEmpty ? "" : "/" + n) + (dir.boolValue ? "/" : "")).utf8)
            let data = dir.boolValue ? Data() : try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            let crc = data.isEmpty ? 0 : crc32(data), size = UInt32(data.count)
            let exec = !dir.boolValue && (path == executable || n.hasSuffix(".dylib") || (n as NSString).deletingLastPathComponent.hasSuffix(".framework") && !n.contains(".plist"))
            let common = le16(20) + le16(0x800) + le16(0) + le16(0) + le16(0x5A21) + le32(crc) + le32(size) + le32(size) + le16(UInt16(name.count)) + le16(0)
            try f.write(contentsOf: Data([0x50, 0x4B, 3, 4] + common + name))
            if !data.isEmpty { try f.write(contentsOf: data) }
            let mode: UInt32 = dir.boolValue ? 0o40755 : exec ? 0o100755 : 0o100644
            central.append(contentsOf: [0x50, 0x4B, 1, 2] + le16(0x314) + common)
            central.append(contentsOf: le16(0) + le16(0) + le16(0) + le32(mode << 16 | (dir.boolValue ? 0x10 : 0)) + le32(at) + name)
            at += UInt32(30 + name.count) + size
            count += 1
        }
        try f.write(contentsOf: central)
        try f.write(contentsOf: Data([0x50, 0x4B, 5, 6] + le16(0) + le16(0) + le16(count) + le16(count) + le32(UInt32(central.count)) + le32(at) + le16(0)))
        try f.close()
        if rename(part, out) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

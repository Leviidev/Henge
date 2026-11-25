import Foundation

/// Tools for a coding program in Henge's terminal (MCP over HTTP, this device only, with a secret made for each
/// launch): it may start no other program here, so building, searching and running the project are offered this way.
final class ToolServer {
    struct Tool {
        let name: String, about: String
        /// Name, type and meaning of each argument.
        let inputs: [(String, String, String)]
        let call: ([String: Any]) -> (ok: Bool, text: String)
    }
    let tools: [Tool]
    let secret = UUID().uuidString
    private(set) var port: UInt16 = 0
    private var listener: Int32 = -1

    init(tools: [Tool]) { self.tools = tools }

    func start() -> Bool {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var n = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, n) == 0 && listen(listener, 8) == 0 && getsockname(listener, $0, &n) == 0 }
        }
        guard ok else { return false }
        port = UInt16(bigEndian: a.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { if errno == EINTR || errno == ECONNABORTED { continue }; return }
                var on: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, 4)
                let t = Thread { self.serve(c); close(c) }
                t.stackSize = 1 << 20
                t.start()
            }
        }
        return true
    }

    /// The file that tells Claude Code about this server.
    func writeConfig(to url: URL) {
        let c: [String: Any] = ["mcpServers": ["henge": ["type": "http", "url": "http://127.0.0.1:\(port)/mcp", "headers": ["Authorization": "Bearer \(secret)"]]]]
        try? JSONSerialization.data(withJSONObject: c).write(to: url, options: .atomic)
    }

    private func serve(_ fd: Int32) {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        func more() -> Bool {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return false }
            buf += chunk[0..<n]
            return buf.count < 16 << 20
        }
        while true {
            var head: Range<Data.Index>?
            while true {
                head = Data(buf).range(of: Data("\r\n\r\n".utf8))
                if head != nil { break }
                if !more() { return }
            }
            let lines = String(decoding: buf[0..<head!.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var fields = [String: String]()
            for l in lines.dropFirst() {
                guard let i = l.firstIndex(of: ":") else { continue }
                fields[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            let end = head!.upperBound
            guard let length = Int(fields["content-length"] ?? "0"), length >= 0, length < 16 << 20 else { return }
            while buf.count < end + length { if !more() { return } }
            let body = Data(buf[end..<end + length])
            buf.removeFirst(end + length)
            var code = 200, out = Data()
            if fields["authorization"] != "Bearer \(secret)" { code = 403; out = Data("{}".utf8) }
            else if !lines[0].hasPrefix("POST ") { code = 405; out = Data("{}".utf8) }
            else if let m = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let r = answer(m) { out = r } else { code = 202 }
            } else { code = 400 }
            let h = "HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\n\r\n"
            let all = Data(h.utf8) + out
            let sent = all.withUnsafeBytes { p -> Bool in
                var at = 0
                while at < p.count {
                    let n = write(fd, p.baseAddress! + at, p.count - at)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return false }
                    at += n
                }
                return true
            }
            if !sent { return }
        }
    }

    func answer(_ m: [String: Any]) -> Data? {
        guard let id = m["id"], let method = m["method"] as? String else { return nil }
        let params = m["params"] as? [String: Any] ?? [:]
        var result: [String: Any] = [:]
        switch method {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] ?? "2025-03-26", "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "henge", "version": "1"]]
        case "tools/list":
            result = ["tools": tools.map { t -> [String: Any] in
                var props = [String: Any]()
                for (n, type, about) in t.inputs { props[n] = ["type": type, "description": about] }
                return ["name": t.name, "description": t.about, "inputSchema": ["type": "object", "properties": props]]
            }]
        case "tools/call":
            guard let t = tools.first(where: { $0.name == params["name"] as? String }) else {
                return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "no such tool"]])
            }
            let r = t.call(params["arguments"] as? [String: Any] ?? [:])
            result = ["content": [["type": "text", "text": r.text]], "isError": !r.ok]
        case "ping": break
        default:
            return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported"]])
        }
        return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }
}

/// The tools themselves, for the projects in one folder.
enum ProjectTools {
    static func projects(in folder: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("henge-build.json").path) }.sorted { $0.path < $1.path }
    }
    static func pick(_ a: [String: Any], in folder: URL) -> URL? {
        let all = projects(in: folder)
        if let n = a["project"] as? String { return all.first { $0.lastPathComponent == n } }
        return all.count == 1 ? all[0] : nil
    }
    static func missing(_ folder: URL) -> String {
        let names = projects(in: folder).map(\.lastPathComponent)
        return names.isEmpty ? "No project with a henge-build.json in \(folder.path)." : "Name the project: \(names.joined(separator: ", "))."
    }

    static func make(folder: URL, run: @escaping (String, [String]) -> (code: Int32, output: String),
                     program: @escaping ProgramRunner.Start, stop: @escaping () -> Void, log: @escaping (String) -> Void) -> [ToolServer.Tool] {
        let one = NSLock()
        let runner = ProgramRunner(start: program, stop: stop)
        return [
            .init(name: "build", about: "Compile what changed in the project, link it and pack the unsigned iPhone app (IPA). Returns the compiler's errors.",
                  inputs: [("project", "string", "The project folder's name; not needed when there is only one")]) { a in
                one.lock(); defer { one.unlock() }
                guard let p = pick(a, in: folder) else { return (false, missing(folder)) }
                if !runner.end() { return (false, "The program that runs does not end. Quit Henge and open it again.") }
                let r = ProjectBuilder(root: p, run: run).build { log("build: \($0)") }
                log(r.text.components(separatedBy: "\n")[0])
                return r
            },
            .init(name: "search", about: "Search file contents with a regular expression (grep). Returns path:line: text.",
                  inputs: [("pattern", "string", "Regular expression (ICU)"), ("path", "string", "File or folder to search; default the projects folder"),
                           ("extensions", "string", "Only files with these extensions, separated by commas, such as c,cpp,h"),
                           ("ignore_case", "boolean", "Ignore case"), ("limit", "integer", "Most lines to return (default 200)")]) { a in search(a, in: folder) },
            .init(name: "run_program", about: "Run the last build in Henge without its window, until stop_program or the next build. It then takes program_command. Returns the first lines it wrote; its whole output is in run/output.txt of the project.",
                  inputs: [("project", "string", "The project folder's name; not needed when there is only one")]) { a in
                one.lock(); defer { one.unlock() }
                guard let p = pick(a, in: folder) else { return (false, missing(folder)) }
                return runner.begin(p)
            },
            .init(name: "program_command", about: "Send the running program one command, a JSON object, and get its answer. The project's notes list its commands.",
                  inputs: [("command", "string", "The JSON object, such as {\"cmd\":\"ping\"}")]) { a in runner.command(a["command"] as? String ?? "") },
            .init(name: "stop_program", about: "Stop the running program. Returns the last lines it wrote.", inputs: []) { _ in
                one.lock(); defer { one.unlock() }
                let ok = runner.end()
                return (ok, (ok ? "Stopped.\n" : "It does not end. Quit Henge and open it again.\n") + runner.tail())
            },
            .init(name: "find_files", about: "List files whose path matches a regular expression.",
                  inputs: [("pattern", "string", "Regular expression"), ("path", "string", "Folder; default the projects folder")]) { a in
                guard let re = try? NSRegularExpression(pattern: a["pattern"] as? String ?? ".", options: .caseInsensitive) else { return (false, "That is not a valid pattern.") }
                var out = [String]()
                for p in walk(a["path"] as? String, folder) where out.count < 500 {
                    if re.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil { out.append(p) }
                }
                return (true, out.isEmpty ? "Nothing matches." : out.joined(separator: "\n"))
            },
        ]
    }

    private static func walk(_ path: String?, _ folder: URL) -> [String] {
        let base = path.map { $0.hasPrefix("/") ? $0 : folder.path + "/" + $0 } ?? folder.path
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base, isDirectory: &dir) else { return [] }
        if !dir.boolValue { return [base] }
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out = [String]()
        for case let u as URL in e {
            let skip = ["build", "toolchain", "sdk", ".git"].contains(u.lastPathComponent)
            if skip && path == nil || u.lastPathComponent == ".git" { e.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { out.append(u.path) }
        }
        return out.sorted()
    }

    static func search(_ a: [String: Any], in folder: URL) -> (ok: Bool, text: String) {
        var opts: NSRegularExpression.Options = []
        if a["ignore_case"] as? Bool == true { opts.insert(.caseInsensitive) }
        guard let pattern = a["pattern"] as? String, let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return (false, "That is not a valid pattern.") }
        let exts = Set((a["extensions"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .*")).lowercased() })
        let limit = a["limit"] as? Int ?? 200
        let literal = NSRegularExpression.escapedPattern(for: pattern) == pattern && opts.isEmpty ? Data(pattern.utf8) : nil
        var out = [String](), chars = 0
        files: for p in walk(a["path"] as? String, folder) {
            if !exts.isEmpty && !exts.contains((p as NSString).pathExtension.lowercased()) { continue }
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: p), options: .mappedIfSafe), d.count < 8 << 20, !d.prefix(4096).contains(0) else { continue }
            if let l = literal, d.range(of: l) == nil { continue }
            var n = 0
            for line in String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
                n += 1
                let s = String(line)
                guard re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else { continue }
                let t = "\(p):\(n): \(s.prefix(240))"
                out.append(t)
                chars += t.count
                if out.count >= limit || chars > 40000 { out.append("… more matches; narrow the search."); break files }
            }
        }
        return (true, out.isEmpty ? "Nothing matches." : out.joined(separator: "\n"))
    }
}

/// The built program running in Henge, without its window.
final class ProgramRunner {
    typealias Start = (_ path: String, _ argv0: String, _ entry: String, _ env: [String], _ output: @escaping (Data) -> Void) -> Int32
    private let start: Start, stop: () -> Void
    private let lock = NSLock()
    private var running = false, ended = "", port: UInt16 = 0
    private var lines = Data()
    private var file: FileHandle?

    init(start: @escaping Start, stop: @escaping () -> Void) { self.start = start; self.stop = stop }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    private var isRunning: Bool { locked { running } }
    func tail() -> String {
        locked { (ended.isEmpty ? "" : ended + "\n") + String(decoding: lines.suffix(4000), as: UTF8.self) }
    }

    func begin(_ root: URL) -> (ok: Bool, text: String) {
        if !end() { return (false, "The program that runs does not end. Quit Henge and open it again.") }
        let fm = FileManager.default
        guard let plan = try? ProjectBuilder.plan(in: root), let r = plan.run else { return (false, "henge-build.json does not say how to run it.") }
        func b(_ p: String) -> URL { root.appendingPathComponent(p) }
        guard fm.fileExists(atPath: b(plan.program).path) else { return (false, "Build it first.") }
        let home = b(r.home)
        try? fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let re = try? NSRegularExpression(pattern: r.needs)
        let there = (try? fm.subpathsOfDirectory(atPath: home.path)) ?? []
        if let re, !there.contains(where: { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) { return (false, r.missing) }
        for (n, text) in r.files {
            try? fm.createDirectory(at: b(n).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: b(n), atomically: true, encoding: .utf8)
        }
        // A copy runs, so the next build can write the original.
        let copy = home.appendingPathComponent("program")
        try? fm.removeItem(at: copy)
        do { try fm.copyItem(at: b(plan.program), to: copy) } catch { return (false, "The program could not be copied: \(error.localizedDescription)") }
        let out = home.appendingPathComponent("output.txt")
        fm.createFile(atPath: out.path, contents: nil)
        locked { running = true; ended = ""; lines = Data(); port = r.port; file = FileHandle(forWritingAtPath: out.path) }
        let env = ["HOME=\(home.path)"] + r.env
        Thread.detachNewThread { [self] in
            let code = start(copy.path, b(plan.program).path, r.entry, env) { [self] d in
                locked {
                    lines.append(d)
                    if lines.count > 1 << 20 { lines.removeFirst(lines.count - (1 << 19)) }
                    try? file?.write(contentsOf: d)
                }
            }
            locked { running = false; ended = "The program ended with \(code)."; try? file?.close(); file = nil }
        }
        for _ in 0..<300 {
            usleep(100_000)
            if !isRunning { return (false, tail()) }
            if let fd = connect() { close(fd); return (true, "Running; it takes commands.\n" + tail()) }
        }
        return (true, "Running, but it takes no commands yet.\n" + tail())
    }

    /// Ends what runs; whether nothing runs any more.
    func end() -> Bool {
        if !isRunning { return true }
        for _ in 0..<100 {
            stop()
            usleep(100_000)
            if !isRunning { return true }
        }
        return false
    }

    private func connect() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, 4)
        var t = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = locked { port }.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if rc == 0 { return fd }
        close(fd)
        return nil
    }

    func command(_ text: String) -> (ok: Bool, text: String) {
        guard isRunning else { return (false, "Nothing runs: use run_program.\n" + tail()) }
        guard let fd = connect() else { return (false, "The program does not answer.\n" + tail()) }
        defer { close(fd) }
        let line = Array((text.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        guard write(fd, line, line.count) == line.count else { return (false, "The program does not answer.") }
        var got = Data(), buf = [UInt8](repeating: 0, count: 65536)
        while !got.contains(10), got.count < 4 << 20 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
        }
        if got.isEmpty { return (false, "No answer within 20 seconds.\n" + tail()) }
        return (true, ProjectBuilder.clip(String(decoding: got, as: UTF8.self)))
    }
}

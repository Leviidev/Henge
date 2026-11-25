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
    /// With a GitHub token, GitHub's own server (its hosted MCP) as well.
    func writeConfig(to url: URL, github: String? = nil) {
        var all: [String: Any] = ["henge": ["type": "http", "url": "http://127.0.0.1:\(port)/mcp", "headers": ["Authorization": "Bearer \(secret)"]]]
        if let github { all["github"] = ["type": "http", "url": "https://api.githubcopilot.com/mcp/", "headers": ["Authorization": "Bearer \(github)"]] }
        guard let d = try? JSONSerialization.data(withJSONObject: ["mcpServers": all]) else { return }
        unlink(url.path)
        FileManager.default.createFile(atPath: url.path, contents: d, attributes: [.posixPermissions: 0o600])
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
        return all.filter { $0.lastPathComponent != "Toolchain" && ProjectBuilder.isProject($0) }.sorted { $0.path < $1.path }
    }
    static func pick(_ a: [String: Any], in folder: URL) -> URL? {
        let all = projects(in: folder)
        if let n = a["project"] as? String { return all.first { $0.lastPathComponent == n } }
        return all.count == 1 ? all[0] : nil
    }
    static func missing(_ folder: URL) -> String {
        let names = projects(in: folder).map(\.lastPathComponent)
        return names.isEmpty ? "No project in \(folder.path): one is a folder with a henge-project.json (project_help)." : "Name the project: \(names.joined(separator: ", "))."
    }

    static func make(folder: URL, home: URL, token: @escaping () -> String?, run: @escaping ProjectBuilder.RunTool,
                     program: @escaping ProgramRunner.Start, stop: @escaping () -> Void, stopTools: @escaping (String) -> Void, log: @escaping (String) -> Void) -> [ToolServer.Tool] {
        let one = NSLock()
        let tools = folder.appendingPathComponent("Toolchain")
        let runner = ProgramRunner(start: program, stop: stop, tools: tools)
        let shell = Shell(tools: tools, home: home, run: run, stop: stopTools)
        return [
            .init(name: "build", about: "Compile what changed in the project, link it and pack the unsigned iPhone app (IPA). Returns the compiler's errors.",
                  inputs: [("project", "string", "The project folder's name; not needed when there is only one")]) { a in
                one.lock(); defer { one.unlock() }
                guard let p = pick(a, in: folder) else { return (false, missing(folder)) }
                if !runner.end() { return (false, "The program that runs does not end. Quit Henge and open it again.") }
                let b = ProjectBuilder(root: p, run: run)
                b.tools = tools
                // A kit may hold a program that needs the memory a second compiler would take.
                b.lanes = FileManager.default.fileExists(atPath: p.appendingPathComponent("henge-build.json").path) ? 1 : 3
                b.shell = { shell.run($0, in: p, timeout: 3600) }
                let r = b.build { log("build: \($0)") }
                log(r.text.components(separatedBy: "\n")[0])
                return r
            },
            .init(name: "project_help", about: "How to make a project (an iPhone app or a program) here: the format of henge-project.json, what is in the toolchain, what works and what does not. Read it before starting or porting a project.", inputs: []) { _ in (true, help) },
            .init(name: "run_command", about: "Run a shell command line (a small POSIX-like shell: pipes, && || ;, redirection, if/for/while, $(...)) in a folder of the projects. Has clang, clang++, ld, ar, cmake, ninja, python3, the built-in cp mv rm mkdir ls cat head tail wc echo test, and any program built here (./build/x). No git, make, sed, awk, grep: use python3 and the other tools. Returns its output and exit code; the whole output is in .henge-output.txt.",
                  inputs: [("command", "string", "The command line"), ("folder", "string", "Folder, relative to the projects folder; it is made if not there"),
                           ("timeout_seconds", "integer", "Most time it may take (default 600)")]) { a in
                guard let c = a["command"] as? String, let d = inside(a["folder"] as? String ?? "", folder) else { return (false, "A command and a folder inside the projects folder are needed.") }
                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                log("run: \(c.prefix(120))")
                let r = shell.run(c, in: d, timeout: a["timeout_seconds"] as? Int ?? 600)
                try? r.output.write(to: d.appendingPathComponent(".henge-output.txt"), atomically: false, encoding: .utf8)
                return (r.code == 0, "exit code \(r.code)\n" + ProjectBuilder.clip(r.output))
            },
            .init(name: "download", about: "Download a file over https into the projects folder; a .zip, .tar.gz, .tar.xz or .tar.bz2 can be unpacked. For a GitHub repository use github_download.",
                  inputs: [("url", "string", "https address"), ("to", "string", "File, or folder when unpacking, relative to the projects folder"), ("unpack", "boolean", "Unpack it into the folder")]) { a in
                guard let u = a["url"] as? String, let to = inside(a["to"] as? String ?? "", folder), to.path != folder.path else { return (false, "An https url and a place inside the projects folder are needed.") }
                return Fetch.file(u, to: to, unpack: a["unpack"] as? Bool == true, shell: shell)
            },
            .init(name: "github_download", about: "Put a GitHub repository's files (with its submodules) into a folder of the projects, to read, search and build. Public ones need no sign-in.",
                  inputs: [("repo", "string", "owner/name"), ("ref", "string", "Branch, tag or commit; default its default branch"), ("folder", "string", "Where, relative to the projects folder; default its name")]) { a in
                guard let repo = a["repo"] as? String, GitHub.isRepo(repo) else { return (false, "repo must be owner/name.") }
                guard let to = inside(a["folder"] as? String ?? (repo as NSString).lastPathComponent, folder), to.path != folder.path else { return (false, "The folder must be inside the projects folder.") }
                log("github: \(repo)")
                return GitHub(token: token()).download(repo, ref: a["ref"] as? String, to: to, shell: shell)
            },
            .init(name: "github_save", about: "Commit files of a folder to a branch of a GitHub repository the user can write to (never forced; the branch is made when it is not there). Only files that differ are sent. Say exactly what will be sent and where before calling it. Not for game data, discs, keys or anything the user has not agreed to put online.",
                  inputs: [("folder", "string", "The folder that is the repository's top, relative to the projects folder"), ("repo", "string", "owner/name"), ("branch", "string", "Branch to commit to"),
                           ("paths", "string", "Files and folders to send, separated by commas, relative to the folder"), ("message", "string", "The commit's message")]) { a in
                guard let t = token() else { return (false, "GitHub is not connected: the user adds a token in Henge, Mac Apps > GitHub.") }
                guard let repo = a["repo"] as? String, GitHub.isRepo(repo), let branch = a["branch"] as? String, let d = inside(a["folder"] as? String ?? "", folder),
                      let m = a["message"] as? String, let p = a["paths"] as? String, !branch.isEmpty, !p.isEmpty else { return (false, "folder, repo, branch, paths and message are needed.") }
                log("github: saving to \(repo) \(branch)")
                return GitHub(token: t).save(d, repo: repo, branch: branch, paths: p.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, message: m)
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

    /// A place in the projects folder, never outside it.
    static func inside(_ path: String, _ folder: URL) -> URL? {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        var rel = path
        for b in [folder.path, base.path] where rel == b || rel.hasPrefix(b + "/") { rel = String(rel.dropFirst(b.count)) }
        if rel.hasPrefix("/") && !path.hasPrefix(base.path) && !path.hasPrefix(folder.path) { return nil }
        let u = rel.isEmpty ? base : base.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        return u.path == base.path || u.path.hasPrefix(base.path + "/") ? u : nil
    }

    private static func walk(_ path: String?, _ folder: URL) -> [String] {
        let base = path.map { $0.hasPrefix("/") ? $0 : folder.path + "/" + $0 } ?? folder.path
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base, isDirectory: &dir) else { return [] }
        if !dir.boolValue { return [base] }
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out = [String]()
        for case let u as URL in e {
            let skip = ["build", "toolchain", "Toolchain", "sdk", ".git"].contains(u.lastPathComponent)
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

    private let tools: URL?

    init(start: @escaping Start, stop: @escaping () -> Void, tools: URL? = nil) { self.start = start; self.stop = stop; self.tools = tools }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    private var isRunning: Bool { locked { running } }
    func tail() -> String {
        locked { (ended.isEmpty ? "" : ended + "\n") + String(decoding: lines.suffix(4000), as: UTF8.self) }
    }

    func begin(_ root: URL) -> (ok: Bool, text: String) {
        if !end() { return (false, "The program that runs does not end. Quit Henge and open it again.") }
        let fm = FileManager.default
        guard let plan = try? ProjectBuilder.anyPlan(in: root, tools: tools), let r = plan.run else { return (false, "The project does not say how to run it (\"run\", see project_help).") }
        func b(_ p: String) -> URL { root.appendingPathComponent(p) }
        guard fm.fileExists(atPath: b(plan.program).path) else { return (false, "Build it first.") }
        let home = b(r.home)
        try? fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let re = try? NSRegularExpression(pattern: r.needs)
        let there = (try? fm.subpathsOfDirectory(atPath: home.path)) ?? []
        if let re, !r.needs.isEmpty, !there.contains(where: { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) { return (false, r.missing) }
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
        for i in 0..<300 {
            usleep(100_000)
            if !isRunning { return (r.port == 0, tail()) }
            if r.port == 0 { if i > 20 { return (true, "Running (it takes no commands).\n" + tail()) }; continue }
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

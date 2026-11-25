import CryptoKit
import Foundation

/// A shell for the terminal's tools: the toolchain's sh, in this process.
final class Shell {
    let tools: URL, home: URL
    private let tool: ProjectBuilder.RunTool, stop: (String) -> Void
    init(tools: URL, home: URL, run: @escaping ProjectBuilder.RunTool, stop: @escaping (String) -> Void) { self.tools = tools; self.home = home; tool = run; self.stop = stop }

    func run(_ command: String, in folder: URL, timeout: Int) -> (code: Int32, output: String) { start(["sh", "-c", command], in: folder, timeout: timeout) }
    func python(_ script: String, _ args: [String], in folder: URL, timeout: Int = 900) -> (code: Int32, output: String) { start(["python3", "-I", "-c", script] + args, in: folder, timeout: timeout) }

    private func start(_ argv: [String], in folder: URL, timeout: Int) -> (code: Int32, output: String) {
        guard FileManager.default.fileExists(atPath: tools.appendingPathComponent("bin/sh").path) else {
            return (127, "There is no toolchain: Files > Henge > Projects needs the Toolchain folder.")
        }
        ProjectMaker.prepare(tools)
        let cwd = folder.resolvingSymlinksInPath().path
        let done = NSLock()
        var ended = false, late = false
        let watch = Thread { [stop] in
            let until = Date().addingTimeInterval(Double(max(timeout, 1)))
            while true {
                usleep(200_000)
                done.lock()
                let e = ended
                if !e && Date() > until { late = true }
                let l = late
                done.unlock()
                if e { return }
                if l { stop(cwd) }
            }
        }
        watch.start()
        let r = tool(tools.appendingPathComponent("bin/" + argv[0]).path, Array(argv.dropFirst()), ProjectMaker.environment(tools: tools, home: home.path) + ["PWD=" + cwd], cwd)
        done.lock()
        ended = true
        let l = late
        done.unlock()
        return l ? (r.code == 0 ? 124 : r.code, r.output + "\nStopped: it took longer than \(timeout) seconds.") : r
    }
}

enum Fetch {
    /// One https request, waited for. Redirects keep to https and lose the sign-in when they leave its host (URLSession does).
    static func send(_ r: URLRequest) -> (code: Int, data: Data, error: String) {
        let wait = DispatchSemaphore(value: 0)
        var out = (0, Data(), "no answer")
        let t = URLSession.shared.dataTask(with: r) { d, resp, e in
            out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data(), e?.localizedDescription ?? "")
            wait.signal()
        }
        t.resume()
        wait.wait()
        return out
    }
    static func save(_ r: URLRequest, to: URL) -> String? {
        let wait = DispatchSemaphore(value: 0)
        var why: String? = "no answer"
        let t = URLSession.shared.downloadTask(with: r) { f, resp, e in
            defer { wait.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let f, code == 200 else { why = e?.localizedDescription ?? "the server answered \(code)"; return }
            do {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: to)
                try FileManager.default.moveItem(at: f, to: to)
                why = nil
            } catch { why = error.localizedDescription }
        }
        t.resume()
        wait.wait()
        return why
    }

    static let unpackScript = """
    import sys, os, tarfile, zipfile
    src, dst, strip = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
    os.makedirs(dst, exist_ok=True)
    root = os.path.realpath(dst)
    def place(name):
        parts = [p for p in name.replace('\\\\\\\\', '/').split('/') if p not in ('', '.')]
        if strip: parts = parts[1:]
        if not parts or '..' in parts: return None
        p = os.path.join(root, *parts)
        return p if os.path.realpath(p).startswith(root + '/') else None
    n = 0
    if zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as z:
            for i in z.infolist():
                p = place(i.filename)
                if not p: continue
                if i.is_dir(): os.makedirs(p, exist_ok=True); continue
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with z.open(i) as f, open(p, 'wb') as o:
                    while b := f.read(1 << 20): o.write(b)
                if i.external_attr >> 16 & 0o111: os.chmod(p, 0o755)
                n += 1
    else:
        links = []
        with tarfile.open(src) as t:
            for i in t:
                p = place(i.name)
                if not p: continue
                if i.isdir(): os.makedirs(p, exist_ok=True); continue
                os.makedirs(os.path.dirname(p), exist_ok=True)
                if i.issym(): links.append((p, i.linkname)); continue
                f = t.extractfile(i)
                if f is None: continue
                with open(p, 'wb') as o:
                    while b := f.read(1 << 20): o.write(b)
                if i.mode & 0o111: os.chmod(p, 0o755)
                n += 1
        for p, to in links:
            full = os.path.realpath(os.path.join(os.path.dirname(p), to))
            if full.startswith(root + '/') and not os.path.lexists(p): os.symlink(to, p)
    print(n, 'files')
    """
    static func unpack(_ file: URL, into: URL, strip: Bool, shell: Shell) -> (ok: Bool, text: String) {
        let r = shell.python(unpackScript, [file.path, into.path, strip ? "1" : "0"], in: into.deletingLastPathComponent())
        return (r.code == 0, r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func file(_ address: String, to: URL, unpack: Bool, shell: Shell) -> (ok: Bool, text: String) {
        guard let u = URL(string: address), u.scheme == "https" else { return (false, "Only https addresses.") }
        let dest = unpack ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) : to
        if let why = save(URLRequest(url: u), to: dest) { return (false, "Not downloaded: \(why)") }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        guard unpack else { return (true, "\(size) bytes at \(to.path)") }
        defer { try? FileManager.default.removeItem(at: dest) }
        let r = Self.unpack(dest, into: to, strip: false, shell: shell)
        return (r.ok, r.ok ? "\(size) bytes, \(r.text) in \(to.path)" : "It could not be unpacked: \(r.text)")
    }
}

/// GitHub, with the user's own token (Mac Apps > GitHub) or, for public repositories, without one.
struct GitHub {
    var token: String?
    /// The tests answer here themselves.
    static var api = "https://api.github.com"
    static func isRepo(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil && !s.contains("..") }

    func request(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: Self.api + path)!, timeoutInterval: 120)
        r.httpMethod = method
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("Henge", forHTTPHeaderField: "User-Agent")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }
    struct Failed: Error { let text: String; let code: Int }
    func call(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) throws -> [String: Any] {
        let r = Fetch.send(request(path, method, body))
        let o = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any] ?? [:]
        if r.code < 200 || r.code > 299 { throw Failed(text: "GitHub answered \(r.code): \(o["message"] as? String ?? r.error)", code: r.code) }
        return o
    }
    private func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? s }

    func download(_ repo: String, ref: String?, to: URL, shell: Shell, depth: Int = 0) -> (ok: Bool, text: String) {
        if depth == 0, let e = try? FileManager.default.contentsOfDirectory(atPath: to.path), !e.isEmpty { return (false, "\(to.lastPathComponent) is there already and not empty.") }
        do {
            let branch = try ref ?? (call("/repos/\(repo)")["default_branch"] as? String ?? "HEAD")
            let sha = try call("/repos/\(repo)/commits/\(esc(branch))")["sha"] as? String ?? branch
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tgz")
            defer { try? FileManager.default.removeItem(at: file) }
            if let why = Fetch.save(request("/repos/\(repo)/tarball/\(sha)"), to: file) { return (false, "\(repo): \(why)") }
            let r = Fetch.unpack(file, into: to, strip: true, shell: shell)
            if !r.ok { return (false, "\(repo): it could not be unpacked: \(r.text)") }
            var text = "\(repo) at \(branch) (\(sha.prefix(10))): \(r.text) in \(to.path)\n"
            guard depth < 4, let mods = try? String(contentsOf: to.appendingPathComponent(".gitmodules"), encoding: .utf8) else { return (true, text) }
            var path = ""
            for line in mods.components(separatedBy: "\n") {
                let kv = line.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count >= 2 else { continue }
                if kv[0] == "path" { path = kv[1] }
                guard kv[0] == "url", !path.isEmpty, let sub = Self.submodule(kv[1], of: repo), let place = ProjectTools.inside(path, to) else {
                    if kv[0] == "url" { text += "submodule \(path) is not on GitHub: \(kv[1])\n" }
                    continue
                }
                do {
                    let o = try call("/repos/\(repo)/contents/\(esc(path))?ref=\(sha)")
                    let m = download(sub, ref: o["sha"] as? String, to: place, shell: shell, depth: depth + 1)
                    text += "submodule " + m.text + (m.ok ? "" : "\n")
                } catch let e as Failed { text += "submodule \(path): \(e.text)\n" }
            }
            return (true, text)
        } catch let e as Failed { return (false, "\(repo): \(e.text)") } catch { return (false, "\(error)") }
    }
    static func submodule(_ url: String, of repo: String) -> String? {
        var u = url
        if u.hasPrefix("../") {
            var base = ("github.com/" + repo).components(separatedBy: "/")
            while u.hasPrefix("../") { u.removeFirst(3); if !base.isEmpty { base.removeLast() } }
            u = base.joined(separator: "/") + "/" + u
        }
        for p in ["https://", "http://", "git://", "ssh://", "git@"] where u.hasPrefix(p) { u.removeFirst(p.count) }
        u = u.replacingOccurrences(of: "git@", with: "").replacingOccurrences(of: "github.com:", with: "github.com/")
        guard u.hasPrefix("github.com/") else { return nil }
        u.removeFirst(11)
        if u.hasSuffix("/") { u.removeLast() }
        if u.hasSuffix(".git") { u.removeLast(4) }
        return isRepo(u) ? u : nil
    }

    func save(_ folder: URL, repo: String, branch: String, paths: [String], message: String) -> (ok: Bool, text: String) {
        let fm = FileManager.default
        var files = [String]()
        for p in paths {
            guard let u = ProjectTools.inside(p, folder) else { return (false, "\(p) is not inside the folder.") }
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &dir) else { return (false, "\(p) is not there.") }
            if !dir.boolValue { files.append(String(u.path.dropFirst(folder.path.count + 1))); continue }
            guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let f as URL in e {
                let n = f.lastPathComponent
                if [".git", "build", "Toolchain", "toolchain", "node_modules"].contains(n) || n.hasPrefix(".henge") || n == ".DS_Store" { e.skipDescendants(); continue }
                if ["o", "ipa", "bin", "cue", "iso", "chd"].contains(f.pathExtension.lowercased()) { continue }
                if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(String(f.resolvingSymlinksInPath().path.dropFirst(folder.path.count + 1))) }
            }
        }
        if files.count > 2000 { return (false, "\(files.count) files are too many for one commit: name fewer paths.") }
        do {
            var base: String, fresh = false
            do { base = (try call("/repos/\(repo)/git/ref/heads/\(esc(branch))")["object"] as? [String: Any])?["sha"] as? String ?? "" }
            catch let e as Failed where e.code == 404 {
                let d = try call("/repos/\(repo)")["default_branch"] as? String ?? "main"
                base = (try call("/repos/\(repo)/git/ref/heads/\(esc(d))")["object"] as? [String: Any])?["sha"] as? String ?? ""
                fresh = true
            }
            let tree = (try call("/repos/\(repo)/git/commits/\(base)")["tree"] as? [String: Any])?["sha"] as? String ?? ""
            let list = try call("/repos/\(repo)/git/trees/\(tree)?recursive=1")["tree"] as? [[String: Any]] ?? []
            var there = [String: (String, String)]()
            for e in list { if let p = e["path"] as? String, let s = e["sha"] as? String { there[p] = (s, e["mode"] as? String ?? "100644") } }
            var entries = [[String: Any]](), names = [String]()
            for f in Set(files).sorted() {
                let d = try Data(contentsOf: folder.appendingPathComponent(f))
                if d.count > 40 << 20 { return (false, "\(f) is too big to send (\(d.count >> 20) MB).") }
                var h = Insecure.SHA1()
                h.update(data: Data("blob \(d.count)\0".utf8))
                h.update(data: d)
                let sha = h.finalize().map { String(format: "%02x", $0) }.joined()
                if there[f]?.0 == sha { continue }
                let made = try call("/repos/\(repo)/git/blobs", "POST", ["content": d.base64EncodedString(), "encoding": "base64"])
                entries.append(["path": f, "mode": there[f]?.1 ?? "100644", "type": "blob", "sha": made["sha"] ?? sha])
                names.append(f)
            }
            if entries.isEmpty { return (true, "Nothing differs from \(branch); no commit made.") }
            let t = try call("/repos/\(repo)/git/trees", "POST", ["base_tree": tree, "tree": entries])["sha"] as? String ?? ""
            let c = try call("/repos/\(repo)/git/commits", "POST", ["message": message, "tree": t, "parents": [base]])["sha"] as? String ?? ""
            if fresh { _ = try call("/repos/\(repo)/git/refs", "POST", ["ref": "refs/heads/" + branch, "sha": c]) }
            else { _ = try call("/repos/\(repo)/git/refs/heads/\(esc(branch))", "PATCH", ["sha": c, "force": false]) }
            return (true, "Committed \(c.prefix(10)) to \(branch) of \(repo): \(names.count) file(s)\n" + names.prefix(60).joined(separator: "\n"))
        } catch let e as Failed { return (false, e.text) } catch { return (false, error.localizedDescription) }
    }
}

extension ProjectTools {
    static let help = """
    PROJECTS. Each is a folder of the projects folder with a henge-project.json. `build` turns it into an unsigned iPhone app, <name>.ipa, \
    which the user signs and installs with their signing app. Incremental: only what changed is compiled.

    henge-project.json (paths are relative to the project; only "name" and either "sources" or "commands" are needed):
    {
      "name": "MyApp", "bundle_id": "com.example.myapp", "version": "1.0", "min_ios": "17.0",
      "sources": ["src/**/*.c", "src/*.cpp", "ios/*.swift"],      C, C++, Objective-C(++), assembly, Swift
      "exclude": ["src/test/**"],
      "include": ["include"], "defines": ["FOO=1"],
      "flags": ["-O2"], "c_flags": ["-std=c11"], "cxx_flags": ["-std=c++20"], "swift_flags": [], "bridging_header": "ios/Bridge.h",
      "frameworks": ["UIKit", "Metal"], "libraries": ["z", "deps/libfoo.a"], "link": [extra ld arguments], "dylibs": ["x.dylib"],
      "resources": ["assets", "data.bin:game/data.bin"],          copied into the app (source:destination)
      "icon": "icon.png", "info": {extra Info.plist keys},
      "kind": "tool",                                             a program to run here (./build/<name>), no app
      "commands": ["cmake -S . -B build/cm", "ninja -C build/cm"], "executable": "build/cm/game",   other build systems: run first; what they made becomes the app's program
      "run": {"entry": "_main", "home": "run", "env": ["A=1"], "files": {}, "port": 4777}     how run_program runs it here without a window; port: where it takes one JSON line per connection (0: none)
    }
    Swift with SwiftUI: an @main App struct. Macros (@Observable, @Model, #Preview) work. A C or C++ main() for a game normally comes from SDL (build SDL's sources with it) \
    or a small UIKit UIApplicationMain shell.

    THE TOOLCHAIN ($HENGE_TOOLS): clang/clang++ and ld for arm64 iOS, the Swift compiler (through `build`), the iPhone SDK, cmake + ninja (set up for iOS by \
    $CMAKE_TOOLCHAIN_FILE), ar, libtool, python3 with its standard library. Everything runs inside Henge on the phone: programs built for iOS run here directly \
    (code generators, converters, tests) with run_command. Their memory is limited to about 1 GB in all, and a program that crashes closes Henge: check inputs, build with asserts.

    NOT HERE: git, make, autoconf/configure scripts, sed/awk/grep (write it in python3), Xcode projects, storyboards, asset catalogs (load PNGs instead), CocoaPods, \
    pip packages with C parts, fork(). Python's subprocess works (multiprocessing pools become threads). A Makefile: read it and write henge-project.json or a build.ninja instead.

    PORTING A DECOMP. 1 github_download it. 2 Read its README, build files and asset steps; say what the user must supply (their own copy of the game; never look for one online). \
    3 Find what it needs from its platform (graphics, sound, input, files, 32-bit assumptions) and whether someone's PC port exists to start from. 4 Build the portable part as a "tool" first, \
    get it to run here headless and check it, then add the iPhone shell. 5 Keep notes in the project's CLAUDE.md. Copyrighted assets stay on the phone, outside github_save.
    """
}

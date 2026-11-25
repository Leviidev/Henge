// The tools Henge's terminal offers (ios/Henge/ProjectBuilder.swift, ToolServer.swift) on the Mac, in one process with
// the terminal's program, under iOS's rules: test_project PROJECTS CONFIG OUT PROGRAM [ARGS...]. Without PROGRAM's
// exit it serves until killed. With CONFIG "build" it builds PROJECTS' only project twice and says what happened.
import Foundation

let a = CommandLine.arguments
guard a.count >= 5, test_map(1400) == 0 else { exit(2) }
let folder = URL(fileURLWithPath: a[1])
FileManager.default.createFile(atPath: a[3], contents: nil)
let out = FileHandle(forWritingAtPath: a[3])!

final class Collected { var data = Data(); let lock = NSLock() }
func runTool(_ tool: String, _ args: [String], _ env: [String], _ cwd: String?) -> (code: Int32, output: String) {
        var e: [UnsafePointer<CChar>?] = env.map { UnsafePointer(strdup($0)) } + [nil]
    let c = Collected()
    var argv: [UnsafePointer<CChar>?] = ([tool] + args).map { UnsafePointer(strdup($0)) } + [nil]
    let rc = henge_tl_tool_run(tool, Int32(args.count + 1), &argv, &e, cwd, { ctx, p, n in
        let c = Unmanaged<Collected>.fromOpaque(ctx!).takeUnretainedValue()
        c.lock.lock(); c.data.append(UnsafeRawPointer(p!).assumingMemoryBound(to: UInt8.self), count: n); c.lock.unlock()
    }, Unmanaged.passUnretained(c).toOpaque())
    for p in argv + e where p != nil { free(UnsafeMutableRawPointer(mutating: p)) }
    return (rc, String(decoding: c.data, as: UTF8.self))
}
func runProgram(_ path: String, _ argv0: String, _ entry: String, _ env: [String], _ output: @escaping (Data) -> Void) -> Int32 {
    var e: [UnsafePointer<CChar>?] = env.map { UnsafePointer(strdup($0)) } + [nil]
    let box = Unmanaged.passRetained(output as AnyObject)
    return henge_tl_program_run(path, strdup(argv0), entry, &e, { ctx, p, n in
        (Unmanaged<AnyObject>.fromOpaque(ctx!).takeUnretainedValue() as! (Data) -> Void)(Data(bytes: p!, count: n))
    }, box.toOpaque())
}
func tools(_ log: @escaping (String) -> Void) -> [ToolServer.Tool] {
    ProjectTools.make(folder: folder, home: FileManager.default.temporaryDirectory, token: { ProcessInfo.processInfo.environment["TEST_TOKEN"] }, run: runTool, program: runProgram, stop: { henge_tl_program_stop() }, stopTools: { henge_tl_tool_stop($0) }, log: log)
}
if let a = ProcessInfo.processInfo.environment["TEST_API"] { GitHub.api = a }
let server = ToolServer(tools: tools { FileHandle.standardError.write(Data("tools: \($0)\n".utf8)) })
guard server.start() else { exit(2) }
if a[2] != "build" { server.writeConfig(to: URL(fileURLWithPath: a[2])) }
var err = [CChar](repeating: 0, count: 512)
var args: [UnsafePointer<CChar>?] = a[5...].map { UnsafePointer(strdup($0)) } + [nil]
var env: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("TERM=xterm-256color")), nil]
let rc = henge_tl_term_start(a[4], &args, &env, nil, 80, 40, { p, n in out.write(Data(bytes: p!, count: n)) }, { _ in }, { code in
    FileHandle.standardError.write(Data("program ended with \(code)\n".utf8))
    if a[2] != "build" { exit(code) }
}, &err, err.count)
if rc != 0 { print(String(cString: err)); exit(1) }
let folders = [folder.appendingPathComponent("Toolchain/bin").path]
var names: [UnsafePointer<CChar>?] = folders.map { UnsafePointer(strdup($0)) } + [nil]
henge_tl_tool_setup(&names, 3)
if a[2] == "build" {
    // Calls from a file, one JSON object per line: {"tool": name, ...its arguments}.
    if let calls = ProcessInfo.processInfo.environment["CALLS"] {
        let all = tools { FileHandle.standardError.write(Data("  \($0)\n".utf8)) }
        for l in ((try? String(contentsOfFile: calls, encoding: .utf8)) ?? "").split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let t = all.first(where: { $0.name == o["tool"] as? String }) else { continue }
            let t0 = Date(), r = t.call(o)
            FileHandle.standardError.write(Data("== \(t.name) \(r.ok) \(String(format: "%.1f", Date().timeIntervalSince(t0))) s\n\(r.text)\n".utf8))
        }
        exit(0)
    }
    for _ in 0..<2 {
        let r = tools { FileHandle.standardError.write(Data("  \($0)\n".utf8)) }[0].call([:])
        FileHandle.standardError.write(Data("\(r.ok) \(r.text)\n".utf8))
    }
    exit(0)
}
while true { sleep(100) }

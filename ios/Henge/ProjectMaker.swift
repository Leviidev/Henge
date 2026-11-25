import Foundation

/// A project described by a henge-project.json, which a coding program in the terminal writes itself: turned into a
/// ProjectBuilder plan at each build. Its parts come from Projects/Toolchain (tools/phone-kit/make_toolchain.sh).
/// Pure Foundation, so the tests run it on a Mac.
enum ProjectMaker {
    static let file = "henge-project.json"
    struct Failure: Error { let text: String; init(_ t: String) { text = t } }

    /// What a command started from a tool gets over the app's environment.
    static func environment(tools: URL, home: String) -> [String] {
        let t = tools.path, cert = t + "/python/cert.pem"
        return ["PATH=\(t)/bin", "HENGE_TOOLS=\(t)", "PYTHONHOME=\(t)/python", "SDKROOT=\(t)/sdk/iPhoneOS.sdk", "IPHONEOS_DEPLOYMENT_TARGET=17.0",
                "CMAKE_TOOLCHAIN_FILE=\(t)/henge.cmake", "CMAKE_GENERATOR=Ninja", "CC=clang", "CXX=clang++", "SSL_CERT_FILE=\(cert)",
                "HOME=\(home)", "SHELL=\(t)/bin/sh", "BUN_OPTIONS=", "PYTHONUNBUFFERED=1"]
    }
    /// The name other programs look for, and leave to run by it, must be marked as programs: unpacking in Files forgets that.
    static func prepare(_ tools: URL) {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: tools.appendingPathComponent("bin").path)) ?? [] { chmod(tools.appendingPathComponent("bin/" + n).path, 0o755) }
    }

    /// The files a pattern names: ** for any folders, * within a name.
    static func glob(_ pattern: String, in root: URL) -> [String] {
        func exists(_ p: String) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path, isDirectory: &d) && !d.boolValue }
        if !pattern.contains("*") { return exists(pattern) ? [pattern] : [] }
        var re = "^", it = Array(pattern)[...]
        while let c = it.first {
            it = it.dropFirst()
            if c == "*", it.first == "*" {
                it = it.dropFirst()
                if it.first == "/" { it = it.dropFirst(); re += "(.*/)?" } else { re += ".*" }
            } else if c == "*" { re += "[^/]*" } else { re += NSRegularExpression.escapedPattern(for: String(c)) }
        }
        guard let r = try? NSRegularExpression(pattern: re + "$") else { return [] }
        let fixed = pattern.components(separatedBy: "*")[0]
        let base = fixed.contains("/") ? String(fixed[..<fixed.lastIndex(of: "/")!]) : ""
        guard let e = FileManager.default.enumerator(atPath: root.appendingPathComponent(base).path) else { return [] }
        var out = [String]()
        while let n = e.nextObject() as? String {
            let p = base.isEmpty ? n : base + "/" + n
            if (n as NSString).lastPathComponent.hasPrefix(".") || (base.isEmpty && n == "build") { e.skipDescendants(); continue }
            if r.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil && exists(p) { out.append(p) }
        }
        return out.sorted()
    }

    static func load(_ root: URL) throws -> [String: Any] {
        guard let d = try? Data(contentsOf: root.appendingPathComponent(file)) else { throw Failure("\(file) cannot be read.") }
        do {
            guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw Failure("\(file) is not a JSON object.") }
            return o
        } catch let e as Failure { throw e } catch { throw Failure("\(file) is not valid JSON: \((error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error)") }
    }

    private static let keys: Set<String> = ["name", "bundle_id", "version", "min_ios", "sources", "exclude", "include", "defines", "flags", "c_flags", "cxx_flags",
                                            "swift_flags", "bridging_header", "frameworks", "libraries", "link", "commands", "executable", "resources", "icon",
                                            "info", "run", "kind", "dylibs"]

    /// The build plan. `tools`: the toolchain's folder.
    static func plan(_ root: URL, tools: URL) throws -> ProjectBuilder.Plan {
        let o = try load(root)
        func strings(_ k: String) throws -> [String] {
            guard let v = o[k] else { return [] }
            guard let a = v as? [String] else { throw Failure("\"\(k)\" must be a list of strings.") }
            return a
        }
        for k in o.keys where !keys.contains(k) { throw Failure("\(file): unknown key \"\(k)\". Known: \(keys.sorted().joined(separator: ", ")).") }
        guard FileManager.default.fileExists(atPath: tools.appendingPathComponent("bin/clang").path) else {
            throw Failure("There is no toolchain: Files > Henge > Projects needs the Toolchain folder.")
        }
        guard let name = o["name"] as? String, !name.isEmpty, !name.contains("/") else { throw Failure("\(file) needs a \"name\".") }
        let t = tools.path, sdk = t + "/sdk/iPhoneOS.sdk", min = o["min_ios"] as? String ?? "17.0"
        let target = "arm64-apple-ios\(min)"
        let isTool = o["kind"] as? String == "tool"
        let res = (try? FileManager.default.contentsOfDirectory(atPath: t + "/lib/clang"))?.sorted().last ?? ""
        var sources = [String](), gone = Set<String>()
        for p in try strings("exclude") { gone.formUnion(glob(p, in: root)) }
        for p in try strings("sources") {
            let g = glob(p, in: root)
            if g.isEmpty { throw Failure("\"sources\": \(p) matches no file.") }
            for f in g where !gone.contains(f) && !sources.contains(f) { sources.append(f) }
        }
        var common = ["-target", target, "-isysroot", sdk, "-resource-dir", t + "/lib/clang/" + res]
        common += try strings("include").map { "-I" + ($0.hasPrefix("/") ? $0 : root.path + "/" + $0) }
        common += try strings("defines").map { "-D" + $0 }
        let all = try strings("flags")
        common += all.contains { $0.hasPrefix("-O") } ? all : ["-O2"] + all
        let c = try strings("c_flags"), cxx = try strings("cxx_flags")
        let flags = [common + c, ["--driver-mode=g++"] + common + cxx, common + ["-fobjc-arc"] + c, ["--driver-mode=g++"] + common + ["-fobjc-arc"] + cxx]
        var units = [ProjectBuilder.Unit](), swift = [String](), objects = [String]()
        for s in sources {
            let kind: Int
            switch (s as NSString).pathExtension.lowercased() {
            case "c", "s": kind = 0
            case "cpp", "cc", "cxx", "c++": kind = 1
            case "m": kind = 2
            case "mm": kind = 3
            case "swift": swift.append(s); continue
            default: continue
            }
            let obj = "build/obj/" + s.replacingOccurrences(of: "../", with: "up/") + ".o"
            units.append(.init(src: s, obj: obj, flags: kind, deps: nil))
            objects.append("$KIT/" + obj)
        }
        var made: ProjectBuilder.Swift?
        if !swift.isEmpty {
            let module = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "_" }.joined()
            var a = ["-frontend", "-c"] + swift.map { "$KIT/" + $0 } + ["-module-name", module, "-target", target, "-sdk", sdk, "-swift-version", "5",
                     "-resource-dir", t + "/lib/swift", "-enable-objc-interop", "-no-color-diagnostics", "-in-process-plugin-server-path",
                     t + "/lib/swift/host/libSwiftInProcPluginServer.dylib", "-plugin-path", t + "/lib/swift/host/plugins",
                     "-module-cache-path", t + "/module-cache", "-Onone"]
            // A lone main.swift runs from its top; anything else has an @main.
            if !swift.contains(where: { ($0 as NSString).lastPathComponent == "main.swift" }) { a.append("-parse-as-library") }
            var deps = swift
            if let b = o["bridging_header"] as? String { a += ["-import-objc-header", "$KIT/" + b]; deps.append(b) }
            a += try strings("include").flatMap { ["-Xcc", "-I" + ($0.hasPrefix("/") ? $0 : root.path + "/" + $0)] }
            a += try strings("swift_flags")
            made = .init(tool: t + "/bin/swift-frontend", args: a, obj: "build/obj/\(module).swift.o", deps: deps)
            objects.append("$KIT/build/obj/\(module).swift.o")
        }
        let commands = try strings("commands")
        if objects.isEmpty && commands.isEmpty { throw Failure("\(file) needs \"sources\" or \"commands\".") }
        let app = "build/\(name).app", program = isTool ? "build/\(name)" : app + "/" + name
        var link = [String]()
        if !objects.isEmpty {
            link = ["-syslibroot", sdk, "-arch", "arm64", "-platform_version", "ios", min, "27.0", "-e", "_main", "-dead_strip", "-ObjC", "-adhoc_codesign",
                    "-L" + sdk + "/usr/lib/swift", "-L" + t + "/lib/swift/iphoneos", "-rpath", "/usr/lib/swift", "-rpath", "@executable_path/Frameworks",
                    "-o", "$KIT/" + program] + objects
            link += try strings("link").map { !$0.hasPrefix("-") && !$0.hasPrefix("/") && FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) ? "$KIT/" + $0 : $0 }
            link += try strings("libraries").map { $0.hasSuffix(".a") || $0.hasSuffix(".dylib") || $0.hasSuffix(".tbd") ? ($0.hasPrefix("/") ? $0 : "$KIT/" + $0) : "-l" + $0 }
            link += try strings("frameworks").flatMap { ["-framework", $0] }
            if !swift.isEmpty { link += ["-framework", "Foundation"] }
            link += ["-lc++", "-lobjc", "-lSystem", t + "/lib/clang/" + res + "/lib/darwin/libclang_rt.ios.a"]
        }
        var run: ProjectBuilder.Run?
        if let r = o["run"] as? [String: Any] {
            run = .init(entry: r["entry"] as? String ?? "_main", home: r["home"] as? String ?? "run", env: r["env"] as? [String] ?? [], files: r["files"] as? [String: String] ?? [:],
                        port: UInt16(clamping: r["port"] as? Int ?? 0), needs: r["needs"] as? String ?? "", missing: r["missing"] as? String ?? "A file it needs is missing.")
        }
        return .init(name: name, flags: flags, files: [], hashes: [], units: units, clang: t + "/bin/clang", ld: t + "/bin/ld", link: link,
                     program: program, app: app, ipa: "\(name).ipa", run: run, swift: made, commands: commands, made: o["executable"] as? String, bundle: !isTool)
    }

    /// Everything of the app but its program, in its folder.
    static func bundle(_ root: URL, _ plan: ProjectBuilder.Plan) throws {
        let o = try load(root), fm = FileManager.default, app = root.appendingPathComponent(plan.app)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        for r in o["resources"] as? [String] ?? [] {
            let p = r.components(separatedBy: ":")
            let from = root.appendingPathComponent(p[0]), to = app.appendingPathComponent(p.count > 1 ? p[1] : (p[0] as NSString).lastPathComponent)
            guard fm.fileExists(atPath: from.path) else { throw Failure("\"resources\": \(p[0]) is not there.") }
            try? fm.removeItem(at: to)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
        }
        for d in o["dylibs"] as? [String] ?? [] {
            let to = app.appendingPathComponent("Frameworks/" + (d as NSString).lastPathComponent)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: root.appendingPathComponent(d), to: to)
        }
        let id = o["bundle_id"] as? String ?? "com.example." + plan.name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let version = o["version"] as? String ?? "1.0"
        var info: [String: Any] = ["CFBundleExecutable": plan.name, "CFBundleIdentifier": id, "CFBundleName": plan.name, "CFBundleDisplayName": plan.name,
                                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": version, "CFBundleInfoDictionaryVersion": "6.0",
                                   "MinimumOSVersion": o["min_ios"] as? String ?? "17.0", "CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [1, 2],
                                   "LSRequiresIPhoneOS": true, "UILaunchScreen": [String: Any](), "UIRequiredDeviceCapabilities": ["arm64"],
                                   "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
                                   "UIFileSharingEnabled": true, "LSSupportsOpeningDocumentsInPlace": true]
        if let icon = o["icon"] as? String {
            for n in ["AppIcon60x60@2x.png", "AppIcon60x60@3x.png"] {
                try? fm.removeItem(at: app.appendingPathComponent(n))
                try fm.copyItem(at: root.appendingPathComponent(icon), to: app.appendingPathComponent(n))
            }
            info["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]
        }
        for (k, v) in o["info"] as? [String: Any] ?? [:] { info[k] = v }
        guard PropertyListSerialization.propertyList(info, isValidFor: .binary) else { throw Failure("\"info\" holds something that cannot be in an Info.plist (null).") }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: app.appendingPathComponent("PkgInfo"))
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// visionOS's Developer Disk Image, which Built-in StikJIT needs on an Apple Vision Pro and can't download.
///
/// StikJIT downloads iOS images, and in compatibility mode it takes the headset for an iPad on iOS 27. The iOS
/// image has no entry for the headset's board, so Apple won't sign it for one. The visionOS image ships with Xcode
/// (`/Library/Developer/DeveloperDiskImages/xrOS_DDI`); the user imports its folder once, and the helper keeps it
/// in its cache, where it survives restarts.
///
/// The cache holds the image's `Restore` folder as Xcode has it (idevice's cryptex loader follows the paths in
/// `BuildManifest.plist`), plus copies under the names StikJIT checks before it decides not to download
/// (`Image.dmg`, `.trustcache`, `.cryptex_info`, `.root_hash`). Compiled into Henge and its JIT helper.
enum VisionDDI {
    /// Running on an Apple Vision Pro, as an iPad app.
    static var isVision: Bool {
        if #available(iOS 26.1, *) { return ProcessInfo.processInfo.isiOSAppOnVision }
        return false
    }

    /// The cryptex payloads, by manifest key, and the name StikJIT gives each in its cache.
    static let payloads: [(key: String, stikJITName: String)] = [
        ("Cryptex1,GenericDmg", "Image.dmg"),
        ("Cryptex1,GenericTrustCache", "Image.dmg.trustcache"),
        ("Cryptex1,CryptexInfoPlist", "Image.dmg.cryptex_info"),
        ("Cryptex1,GenericVolume", "Image.dmg.root_hash"),
    ]

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Manifest {
        /// The visionOS build the image is for, such as 27A9275.
        let build: String
        /// Each payload's path relative to the Restore folder, in `payloads` order.
        let paths: [String]
    }

    /// Reads a BuildManifest.plist and checks that it is visionOS's disk image, with a cryptex.
    static func manifest(_ data: Data) throws -> Manifest {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identities = plist["BuildIdentities"] as? [[String: Any]] else {
            throw Failure("That folder's BuildManifest.plist couldn't be read.")
        }
        let cryptex = identities.first { identity in
            (identity["Manifest"] as? [String: Any])?["Cryptex1,GenericDmg"] != nil
        }
        guard let cryptex, let entries = cryptex["Manifest"] as? [String: Any] else {
            throw Failure("That disk image has no cryptex. Use the one from Xcode 26.4 or later.")
        }
        let deviceClass = (cryptex["Info"] as? [String: Any])?["DeviceClass"] as? String ?? ""
        guard deviceClass.hasPrefix("xros") else {
            throw Failure("That is not visionOS's disk image. Use the xrOS_DDI folder.")
        }
        var paths: [String] = []
        for payload in payloads {
            guard let path = ((entries[payload.key] as? [String: Any])?["Info"] as? [String: Any])?["Path"] as? String,
                  !path.hasPrefix("/"), !path.contains("..") else {
                throw Failure("That disk image's manifest is missing \(payload.key).")
            }
            paths.append(path)
        }
        return Manifest(build: plist["ProductBuildVersion"] as? String ?? "unknown build", paths: paths)
    }

    /// The image's files from a folder the user picked: Xcode's `xrOS_DDI` folder or the `Restore` folder inside it.
    /// Keyed by path relative to the Restore folder, BuildManifest.plist included.
    static func files(in folder: URL) throws -> (build: String, files: [String: Data]) {
        let manager = FileManager.default
        let restore = [folder, folder.appendingPathComponent("Restore")].first {
            manager.fileExists(atPath: $0.appendingPathComponent("BuildManifest.plist").path)
        }
        guard let restore else {
            throw Failure("That folder has no BuildManifest.plist. Choose the xrOS_DDI folder from Xcode.")
        }
        let manifestData = try Data(contentsOf: restore.appendingPathComponent("BuildManifest.plist"))
        let manifest = try manifest(manifestData)
        var files = ["BuildManifest.plist": manifestData]
        for path in manifest.paths {
            do {
                files[path] = try Data(contentsOf: restore.appendingPathComponent(path))
            } catch {
                throw Failure("That disk image is missing \(path).")
            }
        }
        return (manifest.build, files)
    }

    /// Writes an imported image into StikJIT's cache folder (the folder of `manifestPath`), replacing what is there.
    static func install(_ files: [String: Data], into directory: URL) throws {
        guard let manifestData = files["BuildManifest.plist"] else { throw Failure("The disk image's manifest is missing.") }
        let manifest = try manifest(manifestData)
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in files {
            guard !path.hasPrefix("/"), !path.contains("..") else { continue }
            let url = directory.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        for (path, payload) in zip(manifest.paths, payloads) {
            guard let data = files[path] else { throw Failure("The disk image is missing \(path).") }
            try data.write(to: directory.appendingPathComponent(payload.stikJITName), options: .atomic)
        }
    }

    /// Whether `directory` holds an imported visionOS image (not, say, an iOS one StikJIT downloaded).
    static func isInstalled(in directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("BuildManifest.plist")),
              let manifest = try? manifest(data) else { return false }
        let manager = FileManager.default
        return (manifest.paths + payloads.map(\.stikJITName)).allSatisfy {
            manager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}

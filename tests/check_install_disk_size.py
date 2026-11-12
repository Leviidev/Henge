#!/usr/bin/env python3
"""Run the installer's real disk preparation and recovery code on macOS.

Only UIKit, the restore engine, and app services are stubbed. Extracting the
production methods lets this check exercise file creation without downloading
an IPSW, enabling JIT, or running a macOS restore.
"""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def block(source, declaration):
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private ", "", 1)


installer = (ROOT / "ios/Henge/Installer.swift").read_text()
machines = (ROOT / "ios/Henge/Machines.swift").read_text()
constants = "\n".join(re.findall(r"    static let (?:supportedDiskGiB|defaultDiskGiB) = .*", installer))
source = """
import Foundation
enum Device {
    static let isPad = false
    static let suggestedRAMGB = 4
    static let retinaScreen = (width: 1920, height: 1080)
    static let fittingScreen = (width: 1920, height: 1080)
}
enum HengeLog { static func log(_ category: String, _ text: String) {} }
func message(_ text: String) -> NSError { NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
func henge_make_aux(_ path: String) -> Int32 {
    FileManager.default.createFile(atPath: path, contents: Data()) ? 0 : -1
}
"""
source += block(machines, "struct VirtualMac:")
source += "\n" + block(machines, "private struct MachineFile:")
source += """
final class Machines {
    static var root = URL(fileURLWithPath: CommandLine.arguments[1])
    static let installedMarker = "installed"
    var all: [VirtualMac] = []
    var listUnreadable = false
    static func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    static func excludeFromBackup(_ url: URL) {}
    func removeOldTemporaryDownloads() {}
    func save() {}
"""
source += block(machines, "    private func removeLeftovers()") + "\n}\n"
source += "final class Installer {\n" + constants + "\n"
source += block(installer, "    private func prepare(") + "\n}\n"
source += """
let fm = FileManager.default
let rom = Machines.root.appendingPathComponent("source-rom")
try Data([1, 2, 3]).write(to: rom)
let installer = Installer()
precondition(Installer.defaultDiskGiB == 128)
var made: [VirtualMac] = []
for size in Installer.supportedDiskGiB {
    let mac = try installer.prepare(name: "Test \\(size)", ramMB: 4096, rom: rom, diskGiB: size)
    let capacity = Int64(size) << 30
    precondition(mac.diskBytes == capacity)
    let attrs = try fm.attributesOfItem(atPath: mac.disk.path)
    precondition((attrs[.size] as! NSNumber).int64Value == capacity)
    let resources = try mac.disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
    precondition((resources.totalFileAllocatedSize ?? Int.max) < 1 << 20, "disk must remain sparse")
    precondition(try Data(contentsOf: mac.rom) == Data([1, 2, 3]))
    let file = try FileHandle(forUpdating: mac.disk)
    try file.seek(toOffset: UInt64(capacity - 4))
    try file.write(contentsOf: Data([4, 3, 2, 1]))
    try file.seek(toOffset: UInt64(capacity - 4))
    precondition(try file.read(upToCount: 4) == Data([4, 3, 2, 1]))
    try file.close()
    try "Test OS".write(to: mac.directory.appendingPathComponent(Machines.installedMarker), atomically: true, encoding: .utf8)
    made.append(mac)
}
let before = try fm.contentsOfDirectory(atPath: Machines.root.path)
for invalid in [-1, 0, 32, 65, 1024, Int.max] {
    do {
        _ = try installer.prepare(name: "Invalid", ramMB: 4096, rom: rom, diskGiB: invalid)
        fatalError("invalid capacity accepted")
    } catch {}
}
precondition(try fm.contentsOfDirectory(atPath: Machines.root.path) == before, "invalid sizes must not create files")
let recovered = Machines()
recovered.removeLeftovers()
precondition(recovered.all.count == made.count)
for mac in made {
    let restored = recovered.all.first { $0.id == mac.id }!
    precondition(restored.diskBytes == mac.diskBytes, "recovery must preserve capacity")
    precondition(restored.ecid == mac.ecid)
}
recovered.removeLeftovers()
precondition(recovered.all.count == made.count, "recovery must be idempotent")
print("PASS: 64/128/256/512 GiB sparse disks, end-of-disk I/O, invalid sizes, and interrupted-install recovery")
"""
# Swift assertion autoclosures cannot throw.
source = source.replace("precondition(try ", "precondition(try! ")
with tempfile.TemporaryDirectory(prefix="henge-disk-test-") as folder:
    folder = pathlib.Path(folder)
    swift = folder / "main.swift"
    swift.write_text(source)
    binary = folder / "check"
    subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", str(swift), "-o", str(binary)], check=True)
    data = folder / "machines"
    data.mkdir()
    subprocess.run([str(binary), str(data)], check=True)

import Foundation

// Redirect only this fixture's Documents lookup; never alter HOME or app data.
let fixtureDocuments = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
final class FileManager {
    static let `default` = FileManager()
    func urls(for directory: Foundation.FileManager.SearchPathDirectory,
              in domain: Foundation.FileManager.SearchPathDomainMask) -> [URL] { [fixtureDocuments] }
}
enum HengeLog { static func log(_ category: String, _ message: String) {} }
enum M4Performance { static var statisticsEnabled = false }
@main struct EngineTuningChecks {
    static func value(_ key: String) -> String? { getenv(key).map { String(cString:$0) } }
    static func main() throws {
        try Foundation.FileManager.default.createDirectory(at: fixtureDocuments, withIntermediateDirectories: true)
        defer { try? Foundation.FileManager.default.removeItem(at: fixtureDocuments) }
        let savedBackend = UserDefaults.standard.object(forKey:EngineTuning.graphicsBackendKey)
        UserDefaults.standard.removeObject(forKey:EngineTuning.graphicsBackendKey)
        let savedFastmem = UserDefaults.standard.object(forKey:EngineTuning.fastmemKey)
        UserDefaults.standard.removeObject(forKey:EngineTuning.fastmemKey)
        let savedGroups = UserDefaults.standard.object(forKey: "henge.perf.groupedMemory")
        let savedSpin = UserDefaults.standard.object(forKey: "henge.perf.wfiSpin")
        let savedDiagnostics = UserDefaults.standard.object(forKey: "henge.perf.cacheDiagnostics")
        let migrationKey="henge.perf.retiredExperiments.v1"
        let oldMigration=UserDefaults.standard.object(forKey:migrationKey)
        UserDefaults.standard.removeObject(forKey:migrationKey)
        UserDefaults.standard.set(true,forKey:"henge.perf.cacheDiagnostics")
        UserDefaults.standard.set(true,forKey:"henge.perf.wfiSpin")
        UserDefaults.standard.set(true,forKey:"henge.perf.groupedMemory")
        defer {
            if let savedBackend { UserDefaults.standard.set(savedBackend,forKey:EngineTuning.graphicsBackendKey) } else { UserDefaults.standard.removeObject(forKey:EngineTuning.graphicsBackendKey) }
            if let savedFastmem { UserDefaults.standard.set(savedFastmem,forKey:EngineTuning.fastmemKey) } else { UserDefaults.standard.removeObject(forKey:EngineTuning.fastmemKey) }
            if let oldMigration { UserDefaults.standard.set(oldMigration,forKey:migrationKey) } else { UserDefaults.standard.removeObject(forKey:migrationKey) }
            for (key, value) in [("henge.perf.groupedMemory", savedGroups), ("henge.perf.wfiSpin", savedSpin), ("henge.perf.cacheDiagnostics", savedDiagnostics)] {
                if let value { UserDefaults.standard.set(value, forKey:key) }
                else { UserDefaults.standard.removeObject(forKey:key) }
            }
        }
        let url = fixtureDocuments.appendingPathComponent("henge-env.txt")
        setenv("HV_FIXTURE_FOREIGN", "kept", 1)
        try "HV_FIXTURE_OVERRIDE=1\nHV_WFI_SPIN=50\nHV_GROUPS=1\n".write(to:url,atomically:true,encoding:.utf8)
        EngineTuning.apply()
        precondition(value("HV_STATS") == "0" && value("HV_FASTMEM_STATS") == "0")
        precondition(value("HV_FASTMEM")=="1")
        precondition(value("HV_METAL4_OFF")=="0")
        UserDefaults.standard.set("compatibility",forKey:EngineTuning.graphicsBackendKey)
        EngineTuning.apply();precondition(value("HV_METAL4_OFF")=="1")
        try "HV_METAL4_OFF=0\n".write(to:url,atomically:true,encoding:.utf8)
        EngineTuning.apply();precondition(value("HV_METAL4_OFF")=="0", "Explicit environment override remains authoritative")
        UserDefaults.standard.removeObject(forKey:EngineTuning.graphicsBackendKey)
        try "HV_FIXTURE_OVERRIDE=1\nHV_WFI_SPIN=50\nHV_GROUPS=1\n".write(to:url,atomically:true,encoding:.utf8)
        UserDefaults.standard.set(false,forKey:EngineTuning.fastmemKey)
        EngineTuning.apply()
        precondition(value("HV_FASTMEM")=="0", "Explicit cache-off choice must survive migration")
        let previous=UserDefaults.standard.dictionary(forKey:migrationKey)!
        precondition(previous["henge.perf.groupedMemory"] as? Bool == true)
        precondition(UserDefaults.standard.object(forKey:"henge.perf.groupedMemory")==nil)
        precondition(value("HV_FIXTURE_OVERRIDE") == "1" && value("HV_WFI_SPIN") == "50" && value("HV_GROUPS") == "1")
        precondition(value("HV_DEADLINE_KICKS") == "1" && value("HV_TIMER_DIRECT") == "1")
        try "".write(to:url,atomically:true,encoding:.utf8)
        UserDefaults.standard.set(false,forKey:"henge.perf.groupedMemory")
        UserDefaults.standard.set(false,forKey:"henge.perf.wfiSpin")
        EngineTuning.apply()
        precondition(value("HV_FIXTURE_OVERRIDE") == nil)
        precondition(value("HV_FIXTURE_FOREIGN") == "kept")
        precondition(value("HV_WFI_SPIN") == "0" && value("HV_GROUPS") == "2")
        M4Performance.statisticsEnabled=true
        try "HV_STATS=0\nHV_PROF_IOS=0\nHV_FASTMEM=0\n".write(to:url,atomically:true,encoding:.utf8)
        EngineTuning.apply()
        precondition(value("HV_STATS")=="10" && value("HV_PROF_IOS")=="2" && value("HV_FASTMEM_STATS")=="1")
        precondition(value("HV_FASTMEM")=="0", "Diagnostics do not change the chosen cache path")
        precondition(value("HV_PROF_IOS_HZ")=="50" && value("HV_BLK_STATS")=="10")
        M4Performance.statisticsEnabled=false
        try "".write(to:url,atomically:true,encoding:.utf8)
        EngineTuning.apply()
        precondition(value("HV_STATS")=="0" && value("HV_PROF_IOS")==nil && value("HV_BLK_STATS")==nil)
        UserDefaults.standard.removeObject(forKey:"henge.perf.groupedMemory")
        UserDefaults.standard.removeObject(forKey:"henge.perf.wfiSpin")
        print("PASS engine tuning: actual defaults, explicit overrides, removed overrides, foreign environment and grouped-path activation")
    }
}

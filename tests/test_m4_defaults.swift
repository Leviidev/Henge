import Foundation
var fixtureM4: Int32 = 1
func hv_host_is_m4_16gb() -> Int32 { fixtureM4 }
enum HengeLog { static func log(_ a: String, _ b: String) {} }
struct VirtualMac {
    var retina: Bool? = false, fitScreen: Bool? = true, desktopLayout: Bool? = false
    var screenWidth: Int? = 1920, screenHeight: Int? = 1080
}
enum Device {
    static let retinaScreen = (width: 2752, height: 2064)
    static let displayViewport = CGSize(width:1181,height:756.5)
    static func desktopRetina(in viewport:CGSize)->GuestScreenSize {
        GuestScreenSize.desktopRetina(in:viewport,panel:CGSize(width:1376,height:1032))
    }
}
@main struct Check {
    static func main() {
        let d = UserDefaults.standard
        let keys = [M4Performance.statisticsKey,EngineTuning.fastmemKey,EngineTuning.refreshKey,"henge.perf.codeCacheMB"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { d.set(value, forKey:key) } else { d.removeObject(forKey:key) } } }
        d.removeObject(forKey:M4Performance.statisticsKey)
        let suite=UserDefaults(suiteName:"DiagnosticBuildFixture")!
        suite.removePersistentDomain(forName:"DiagnosticBuildFixture")
        M4Performance.prepareDiagnosticBuild(defaults:suite,enabled:true,build:"test")
        precondition(suite.bool(forKey:M4Performance.statisticsKey))
        suite.set(false,forKey:M4Performance.statisticsKey)
        M4Performance.prepareDiagnosticBuild(defaults:suite,enabled:true,build:"test")
        precondition(!suite.bool(forKey:M4Performance.statisticsKey),"Explicit stop after first launch is preserved")
        suite.removePersistentDomain(forName:"DiagnosticBuildFixture")
        fixtureM4=0;precondition(!M4Performance.statisticsEnabled)
        fixtureM4=1;precondition(!M4Performance.statisticsEnabled)
        d.set(true,forKey:M4Performance.statisticsKey)
        precondition(M4Performance.statisticsEnabled, "Explicit diagnostic opt-in must survive")
        for key in keys { d.set(true,forKey:key) }
        d.set(120,forKey:EngineTuning.refreshKey);d.set(1536,forKey:"henge.perf.codeCacheMB")
        fixtureM4=0;M4Performance.applyAutomaticDefaults()
        precondition(d.bool(forKey:EngineTuning.fastmemKey))
        fixtureM4=1;M4Performance.applyAutomaticDefaults()
        precondition(d.bool(forKey:EngineTuning.fastmemKey))
        for key in keys where key != EngineTuning.fastmemKey && key != EngineTuning.refreshKey && key != "henge.perf.codeCacheMB" {
            precondition(!d.bool(forKey:key))
        }
        precondition(d.integer(forKey:EngineTuning.refreshKey)==120)
        precondition(d.integer(forKey:"henge.perf.codeCacheMB")==1536)
        precondition(M4Performance.maximumGuestCPUs==8 && !M4Performance.statisticsEnabled)
        fixtureM4=0;precondition(M4Performance.maximumGuestCPUs==6)
        var mac = VirtualMac()
        M4Performance.applyRetinaDisplay(to: &mac)
        precondition(mac.retina == false && mac.screenWidth == 1920)
        fixtureM4=1;M4Performance.applyRetinaDisplay(to: &mac)
        precondition(mac.retina == true && mac.fitScreen == false)
        precondition(mac.desktopLayout == true && mac.screenWidth == 2560 && mac.screenHeight == 1920)
        print("M4 defaults: explicit selection, non-M4 exclusion, Retina-independent refresh/JIT preservation passed")
    }
}
